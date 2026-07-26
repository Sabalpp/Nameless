"""Mission brief handling — port of main.rs MissionBrief / cmd_brief / route build.

Builds VoyageRoute from origin → waypoints → destination, scales haversine
distances to the declared brief distance, derives per-leg OceanConditions from
the environmental profile + primary stressor, then runs a tiered simulation.
"""

import json;
import from math { atan2, cos, degrees, fabs, pi, radians, sin }
import from pathlib { Path }

import from engine.types {
    GeoPoint,
    HullGeometry,
    MaterialGrade,
    MissionBrief,
    OceanConditions,
    PropulsionSpec,
    RouteSegment,
    SealQuality,
    SimOutcome,
    VesselConfig,
    VoyageRoute,
    WeldQuality,
    ZoneSpec,
    parse_hull_zone
}
import from engine.materials { parse_material, parse_weld, parse_seal }
import from engine.config { uniform }
import from engine.route { haversine_nm, total_distance_nm }
import from engine.voyage { run_voyage }
import from engine.envelope { build_output }
import from engine.optimizer { default_sweep, run_per_zone_optimizer }
import from engine.outcome { failure_mode_label, failure_diagnosis, survived }

# ---------------------------------------------------------------------------
# Default sim hull / propulsion (main.rs defaults — not Rust Default impls)
# ---------------------------------------------------------------------------

def default_sim_hull() -> HullGeometry {
    return HullGeometry(
        loa_m=7.315,
        beam_m=2.5,
        depth_m=0.85,
        draft_m=0.40,
        block_coeff=0.44,
        waterplane_coeff=0.76
    );
}

def default_sim_propulsion() -> PropulsionSpec {
    return PropulsionSpec(
        max_power_kw=300.0,
        fuel_capacity_kg=2000.0,
        sfc_g_per_kwh=220.0,
        propulsive_efficiency=0.72,
        hull_drag_coeff=0.007
    );
}

def validate_propulsion(propulsion: PropulsionSpec) -> str | None {
    if propulsion.max_power_kw <= 0.0 {
        return "propulsion.max_power_kw must be positive";
    }
    if propulsion.fuel_capacity_kg <= 0.0 {
        return "propulsion.fuel_capacity_kg must be positive";
    }
    if propulsion.sfc_g_per_kwh <= 0.0 {
        return "propulsion.sfc_g_per_kwh must be positive";
    }
    if (
        propulsion.propulsive_efficiency <= 0.0
        or propulsion.propulsive_efficiency > 1.0
    ) {
        return "propulsion.propulsive_efficiency must be within (0, 1]";
    }
    if propulsion.hull_drag_coeff <= 0.0 {
        return "propulsion.hull_drag_coeff must be positive";
    }
    return None;
}

# ---------------------------------------------------------------------------
# Geo helpers
# ---------------------------------------------------------------------------

"Initial (forward) bearing from from_pt to to_pt [degrees true, 0 = north]."
def initial_bearing_deg(from_pt: GeoPoint, to_pt: GeoPoint) -> float {
    lat1 = radians(from_pt.lat_deg);
    lat2 = radians(to_pt.lat_deg);
    dlon = radians(to_pt.lon_deg - from_pt.lon_deg);
    y = sin(dlon) * cos(lat2);
    x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dlon);
    return (degrees(atan2(y, x)) + 360.0) % 360.0;
}

def:priv _clamp(value: float, lo: float, hi: float) -> float {
    if value < lo { return lo; }
    if value > hi { return hi; }
    return value;
}

# ---------------------------------------------------------------------------
# Environmental profile → OceanConditions
# ---------------------------------------------------------------------------

def slam_prob_from_str(s: str) -> float {
    match s {
        case "none": return 0.02;
        case "low": return 0.12;
        case "moderate": return 0.32;
        case "high": return 0.55;
        case "extreme": return 0.80;
    }
    return 0.25;
}

def:priv _range_avg(r: dict[str, object], fallback: float = 0.0) -> float {
    if "avg" in r {
        return r["avg"] as float;
    }
    return fallback;
}

def:priv _range_max(r: dict[str, object], fallback: float) -> float {
    if "max" in r and r["max"] is not None {
        return r["max"] as float;
    }
    return fallback;
}

def:priv _range_min(r: dict[str, object], fallback: float) -> float {
    if "min" in r and r["min"] is not None {
        return r["min"] as float;
    }
    return fallback;
}

"""Derive per-leg OceanConditions from the brief's environmental profile,
calibrated to the primary stressor and the leg's position along the route.
"""
def conditions_for_leg(
    profile: dict[str, object],
    stressor: str,
    leg_idx: int,
    total_legs: int
) -> OceanConditions {
    if total_legs > 1 {
        t = (leg_idx as float) / ((total_legs - 1) as float);
    } else {
        t = 0.5;
    }
    # Bell curve peaking at route midpoint
    mid_peak = 1.0 - (2.0 * t - 1.0) ** 2;

    wave_h_raw = profile.get("wave_height_m", {});
    wave_p_raw = profile.get("wave_period_s", {});
    water_t_raw = profile.get("water_temp_c", {});
    wave_h = wave_h_raw as dict[str, object];
    wave_p = wave_p_raw as dict[str, object];
    water_t = water_t_raw as dict[str, object];

    base_hs = _range_avg(wave_h, 2.0);
    max_hs = _range_max(wave_h, base_hs * 1.8);
    base_tp = _range_avg(wave_p, 8.0);
    max_tp = _range_max(wave_p, base_tp * 1.4);
    base_temp = _range_avg(water_t, 15.0);
    min_temp = _range_min(water_t, base_temp - 3.0);
    max_temp = _range_max(water_t, base_temp + 2.0);

    salinity = 35.0;
    if "salinity_ppt" in profile {
        salinity = profile["salinity_ppt"] as float;
    }
    ph = 8.10;
    if "ph" in profile and profile["ph"] is not None {
        ph = profile["ph"] as float;
    }

    slam_key = "moderate";
    if "slamming_probability" in profile {
        slam_key = profile["slamming_probability"] as str;
    }
    base_slam = slam_prob_from_str(slam_key);

    if stressor == "sustained_structural_fatigue" {
        hs = base_hs + (max_hs - base_hs) * (0.22 + 0.78 * mid_peak);
        tp = base_tp + (max_tp - base_tp) * (0.18 + 0.72 * mid_peak);
        return OceanConditions(
            hs_m=hs,
            tp_s=max(tp, 6.0),
            jonswap_gamma=3.6,
            encounter_angle_deg=4.0 + 10.0 * mid_peak,
            water_temp_c=base_temp - (base_temp - min_temp) * (0.30 + 0.70 * t),
            salinity_ppt=salinity,
            ph=ph,
            wind_speed_ms=14.0 + 14.0 * mid_peak,
            slam_probability=min(base_slam * (0.78 + 0.45 * mid_peak), 0.99)
        );
    } elif stressor == "capsize_stability" {
        if t < 0.70 {
            horn_factor = t / 0.70;
        } else {
            horn_factor = 1.0 - (t - 0.70) / 0.30 * 0.25;
        }
        horn_factor = _clamp(horn_factor, 0.0, 1.0);

        hs = base_hs + (max_hs - base_hs) * (horn_factor ** 2);
        tp = base_tp + (max_tp - base_tp) * horn_factor;
        return OceanConditions(
            hs_m=hs,
            tp_s=max(tp, 8.0),
            jonswap_gamma=1.4 - 0.25 * horn_factor,
            encounter_angle_deg=15.0 + 65.0 * horn_factor,
            water_temp_c=base_temp + (min_temp - base_temp) * t,
            salinity_ppt=salinity,
            ph=ph,
            wind_speed_ms=12.0 + 20.0 * horn_factor,
            slam_probability=min(
                base_slam * (0.35 + 1.05 * (horn_factor ** 2)),
                0.98
            )
        );
    } elif stressor == "corrosion_crack_cascade" {
        slight_var = 0.12 * fabs(2.0 * t - 1.0);
        return OceanConditions(
            hs_m=base_hs * (1.0 + slight_var),
            tp_s=base_tp,
            jonswap_gamma=4.8,
            encounter_angle_deg=25.0,
            water_temp_c=max_temp - (max_temp - base_temp) * t * 0.25,
            salinity_ppt=salinity,
            ph=ph,
            wind_speed_ms=7.5,
            slam_probability=base_slam
        );
    } elif stressor == "ice_accretion_cold_embrittlement" {
        cold_factor = 1.0 - (2.0 * t - 1.0) ** 2;
        temp = base_temp + (min_temp - base_temp) * cold_factor;
        hs = base_hs * (1.0 + 0.60 * cold_factor);
        return OceanConditions(
            hs_m=hs,
            tp_s=base_tp,
            jonswap_gamma=2.8,
            encounter_angle_deg=18.0,
            water_temp_c=temp,
            salinity_ppt=salinity,
            ph=ph,
            wind_speed_ms=13.0 + 11.0 * cold_factor,
            slam_probability=min(base_slam * (1.0 + 0.60 * cold_factor), 0.95)
        );
    } elif stressor == "fuel_exhaustion" {
        return OceanConditions(
            hs_m=base_hs,
            tp_s=base_tp,
            jonswap_gamma=2.2,
            encounter_angle_deg=38.0,
            water_temp_c=max_temp - (max_temp - min_temp) * t * 0.6,
            salinity_ppt=salinity,
            ph=ph,
            wind_speed_ms=8.5,
            slam_probability=base_slam
        );
    } else {
        hs = base_hs + (max_hs - base_hs) * mid_peak * 0.55;
        period_max = _range_max(wave_p, base_tp * 1.5);
        tp = base_tp + (period_max - base_tp) * mid_peak * 0.45;
        return OceanConditions(
            hs_m=hs,
            tp_s=max(tp, 5.0),
            jonswap_gamma=5.8,
            encounter_angle_deg=22.0 + 35.0 * sin(t * pi),
            water_temp_c=max_temp - (max_temp - base_temp) * t * 0.25,
            salinity_ppt=salinity,
            ph=ph,
            wind_speed_ms=9.0 + 7.0 * mid_peak,
            slam_probability=min(base_slam * (0.65 + 0.70 * mid_peak), 0.90)
        );
    }
}

# ---------------------------------------------------------------------------
# Brief parsing
# ---------------------------------------------------------------------------

obj NamedPoint {
    has point: GeoPoint,
        name: str;
}

def:priv _geo_from_dict(data: dict[str, object], fallback_name: str) -> NamedPoint {
    lat = data.get("lat_deg", 0.0) as float;
    lon = data.get("lon_deg", 0.0) as float;
    name = fallback_name;
    if "name" in data and data["name"] is not None {
        name = data["name"] as str;
    }
    return NamedPoint(point=GeoPoint(lat_deg=lat, lon_deg=lon), name=name);
}

def:priv _parse_zone_spec(raw: dict[str, object]) -> ZoneSpec {
    zone_raw = raw.get("zone", raw.get("zone_key", "Keel"));
    zone_key = zone_raw as str;
    zone = parse_hull_zone(zone_key);
    if zone is None {
        raise ValueError(f"unknown hull zone '{zone_key}'");
    }

    mat_raw = raw.get("material", "MildSteelA");
    material: MaterialGrade = MaterialGrade.MILD_STEEL_A;
    if isinstance(mat_raw, dict) {
        mat_dict = mat_raw as dict[str, object];
        grade_key = mat_dict.get("grade", "MildSteelA") as str;
        parsed = parse_material(grade_key);
        if parsed is not None {
            material = parsed;
        }
    } else {
        parsed = parse_material(mat_raw as str);
        if parsed is not None {
            material = parsed;
        }
    }

    weld_parsed = parse_weld(raw.get("weld_quality", "Economy") as str);
    weld: WeldQuality = WeldQuality.ECONOMY;
    if weld_parsed is not None {
        weld = weld_parsed;
    }
    seal_parsed = parse_seal(raw.get("seal_quality", "Economy") as str);
    seal: SealQuality = SealQuality.ECONOMY;
    if seal_parsed is not None {
        seal = seal_parsed;
    }

    return ZoneSpec(
        zone=zone,
        material=material,
        thickness_m=raw.get("thickness_m", 0.004) as float,
        weld_quality=weld,
        seal_quality=seal
    );
}

def:priv _apply_propulsion_params(raw: object | None) -> PropulsionSpec {
    base = default_sim_propulsion();
    if raw is None {
        return base;
    }
    if isinstance(raw, PropulsionSpec) {
        return raw;
    }
    if not isinstance(raw, dict) {
        return base;
    }
    d = raw as dict[str, object];
    if "max_power_kw" in d and d["max_power_kw"] is not None {
        base.max_power_kw = d["max_power_kw"] as float;
    }
    if "fuel_capacity_kg" in d and d["fuel_capacity_kg"] is not None {
        base.fuel_capacity_kg = d["fuel_capacity_kg"] as float;
    }
    if "sfc_g_per_kwh" in d and d["sfc_g_per_kwh"] is not None {
        base.sfc_g_per_kwh = d["sfc_g_per_kwh"] as float;
    }
    if "propulsive_efficiency" in d and d["propulsive_efficiency"] is not None {
        base.propulsive_efficiency = d["propulsive_efficiency"] as float;
    }
    if "hull_drag_coeff" in d and d["hull_drag_coeff"] is not None {
        base.hull_drag_coeff = d["hull_drag_coeff"] as float;
    }
    return base;
}

"Coerce a MissionBrief or raw JSON dict into MissionBrief."
def parse_mission_brief(data: MissionBrief | dict[str, object]) -> MissionBrief {
    if isinstance(data, MissionBrief) {
        return data;
    }
    d = data;

    zones_out: list[ZoneSpec] | None = None;
    if "zones" in d and d["zones"] is not None {
        zones_out = [];
        zones_raw = d["zones"] as list;
        for z in zones_raw {
            if isinstance(z, ZoneSpec) {
                zones_out.append(z);
            } elif isinstance(z, dict) {
                zones_out.append(_parse_zone_spec(z as dict[str, object]));
            }
        }
    }

    env: dict[str, object] = {};
    if "environmental_profile" in d and d["environmental_profile"] is not None {
        env = d["environmental_profile"] as dict[str, object];
    }

    origin = d.get("origin", {}) as dict[str, object];
    destination = d.get("destination", {}) as dict[str, object];
    waypoints = d.get("waypoints", []) as list;

    prop: PropulsionSpec | None = None;
    if "propulsion" in d and d["propulsion"] is not None {
        prop = _apply_propulsion_params(d["propulsion"]);
    }

    return MissionBrief(
        id=d.get("id", "") as str,
        name=d.get("name", "") as str,
        origin=origin,
        destination=destination,
        waypoints=waypoints,
        distance_nm=d.get("distance_nm", 0.0) as float,
        expected_duration_days=d.get("expected_duration_days", 0.0) as float,
        primary_stressor=d.get("primary_stressor", "") as str,
        environmental_profile=env,
        zones=zones_out,
        propulsion=prop
    );
}

# ---------------------------------------------------------------------------
# Route construction
# ---------------------------------------------------------------------------

"Build VoyageRoute: origin → waypoints → destination with stressor conditions."
def build_route_from_brief(brief: MissionBrief) -> VoyageRoute {
    points: list[GeoPoint] = [];
    names: list[str] = [];

    origin_named = _geo_from_dict(brief.origin as dict[str, object], "Origin");
    points.append(origin_named.point);
    names.append(origin_named.name);

    for wp in brief.waypoints {
        if isinstance(wp, dict) {
            named = _geo_from_dict(wp as dict[str, object], "Waypoint");
            points.append(named.point);
            names.append(named.name);
        }
    }

    dest_named = _geo_from_dict(brief.destination as dict[str, object], "Destination");
    points.append(dest_named.point);
    names.append(dest_named.name);

    total_legs = len(points) - 1;
    if total_legs < 1 {
        raise ValueError("mission brief needs at least origin and destination");
    }

    segments: list[RouteSegment] = [];
    profile: dict[str, object] = {};
    if brief.environmental_profile is not None {
        profile = brief.environmental_profile as dict[str, object];
    }
    stressor = brief.primary_stressor;

    i = 0;
    while i < total_legs {
        from_pt = points[i];
        to_pt = points[i + 1];
        dist = haversine_nm(from_pt, to_pt);
        heading = initial_bearing_deg(from_pt, to_pt);
        conditions = conditions_for_leg(profile, stressor, i, total_legs);
        segments.append(RouteSegment(
            from_pt=from_pt,
            to_pt=to_pt,
            distance_nm=dist,
            heading_deg=heading,
            conditions=conditions,
            label=f"{names[i]} → {names[i + 1]}",
            duration_scale=1.0
        ));
        i += 1;
    }

    # Scale haversine distances to match the declared total when off by >5%.
    haversine_total = 0.0;
    for seg in segments {
        haversine_total += seg.distance_nm;
    }
    if (
        haversine_total > 0.0
        and fabs(haversine_total - brief.distance_nm) / haversine_total > 0.05
    ) {
        scale = brief.distance_nm / haversine_total;
        for seg in segments {
            seg.distance_nm = seg.distance_nm * scale;
        }
    }

    if (
        brief.primary_stressor == "corrosion_crack_cascade"
        and brief.expected_duration_days > 0.0
    ) {
        target_duration_h = brief.expected_duration_days * 24.0;
        nominal_duration_h = brief.distance_nm / 24.0;
        duration_scale = _clamp(
            target_duration_h / max(nominal_duration_h, 1.0),
            1.0,
            8.0
        );
        for seg in segments {
            seg.duration_scale = duration_scale;
        }
    }

    return VoyageRoute(
        origin=points[0],
        destination=points[len(points) - 1],
        segments=segments
    );
}

# ---------------------------------------------------------------------------
# Tier configs + run
# ---------------------------------------------------------------------------

def:priv _tier_uniform_config(
    hull: HullGeometry,
    propulsion: PropulsionSpec,
    tier: str
) -> VesselConfig {
    if tier == "lowest" {
        return uniform(
            hull,
            MaterialGrade.MILD_STEEL_A,
            0.004,
            WeldQuality.ECONOMY,
            SealQuality.ECONOMY,
            propulsion
        );
    } elif tier == "premium" {
        return uniform(
            hull,
            MaterialGrade.EH36,
            0.008,
            WeldQuality.PREMIUM,
            SealQuality.MARINE,
            propulsion
        );
    } else {
        return uniform(
            hull,
            MaterialGrade.AH36,
            0.006,
            WeldQuality.STANDARD,
            SealQuality.MARINE,
            propulsion
        );
    }
}

def:priv print_summary(outcome: SimOutcome) {
    if survived(outcome) {
        print(
            f"  ✓ SURVIVED  {outcome.distance_completed_nm:.0f}/"
            + f"{outcome.total_distance_nm:.0f} nm  "
            + f"({outcome.time_elapsed_h:.1f}h)  "
            + f"fuel left {outcome.fuel_remaining_kg:.0f} kg  "
            + f"cost ${outcome.total_config_cost_usd:.0f}"
        );
    } elif outcome.failure is not None {
        d = outcome.failure;
        diag = failure_diagnosis(d.mode);
        seg_n = d.segment_index + 1;
        print(
            f"  ✗ FAILED — {failure_mode_label(d.mode)} at segment "
            + f"{seg_n} ({d.distance_completed_nm:.0f} nm, "
            + f"{d.elapsed_h:.1f}h)"
        );
        print(f"    Why: {diag[0]}");
        print(f"    Fix: {diag[1]}");
    }
    print();
}

"""Run a mission brief at the given tier; returns the schema 1.0 envelope dict.

tier: \"lowest\" | \"baseline\" | \"premium\" | \"cheapest\"
When brief.zones is set, runs that custom config (tier ignored).
"""
def run_brief(
    brief_in: MissionBrief | dict[str, object],
    tier: str = "baseline"
) -> dict[str, object] {
    brief = parse_mission_brief(brief_in);
    route = build_route_from_brief(brief);

    hull = default_sim_hull();
    propulsion: PropulsionSpec = default_sim_propulsion();
    if brief.propulsion is not None {
        propulsion = brief.propulsion;
    }
    err = validate_propulsion(propulsion);
    if err is not None {
        raise ValueError(f"mission brief propulsion invalid: {err}");
    }

    if brief.zones is not None {
        if len(brief.zones) == 0 {
            raise ValueError("mission brief zones cannot be empty");
        }
        for z in brief.zones {
            if z.thickness_m <= 0.0 {
                raise ValueError("mission brief zone thicknesses must be positive");
            }
        }

        print(f"Mission brief: {brief.name} [{brief.id}]  tier: custom");
        print(
            f"Route: {len(route.segments)} legs  ·  "
            + f"{total_distance_nm(route):.0f} nm  ·  "
            + f"stressor: {brief.primary_stressor}"
        );

        config = VesselConfig(
            hull=hull,
            zones=brief.zones,
            propulsion=propulsion
        );
        outcome = run_voyage(config, route);
        envelope = build_output(config, route, outcome, None);
        print_summary(outcome);
        return envelope;
    }

    if tier == "cheapest" {
        print(f"Mission brief: {brief.name} [{brief.id}]  tier: cheapest");
        print(
            f"Route: {len(route.segments)} legs  ·  "
            + f"{total_distance_nm(route):.0f} nm  ·  "
            + f"stressor: {brief.primary_stressor}"
        );

        space = default_sweep(hull, propulsion);
        per_zone = run_per_zone_optimizer(space, route);
        config = per_zone.config;
        opt = per_zone.optimizer;
        outcome = run_voyage(config, route);
        envelope = build_output(config, route, outcome, opt);
        print_summary(outcome);
        if opt.cheapest_survivor is not None {
            print("Cheapest survivor: per-zone material configuration");
        } else {
            print(
                "No surviving per-zone configuration found; "
                + "returned best-progress run."
            );
        }
        return envelope;
    }

    config = _tier_uniform_config(hull, propulsion, tier);
    print(f"Mission brief: {brief.name} [{brief.id}]  tier: {tier}");
    print(
        f"Route: {len(route.segments)} legs  ·  "
        + f"{total_distance_nm(route):.0f} nm  ·  "
        + f"stressor: {brief.primary_stressor}"
    );

    outcome = run_voyage(config, route);
    envelope = build_output(config, route, outcome, None);
    print_summary(outcome);
    return envelope;
}

"CLI-style brief command: load JSON, run, write envelope to out_path."
def cmd_brief(brief_path: str, out_path: str, tier: str = "baseline") {
    text = Path(brief_path).read_text(encoding="utf-8");
    data = json.loads(text) as dict[str, object];
    envelope = run_brief(data, tier);
    Path(out_path).write_text(
        json.dumps(envelope, indent=2) + "\n",
        encoding="utf-8"
    );
    print(f"Output → {out_path}");
}
