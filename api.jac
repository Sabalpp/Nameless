"""SeaForge REST API — Jac port of ui/server.js.

All Express routes become walker:pub endpoints with @restspec paths.
spawnSync/temp-files/child_process are replaced by in-process engine calls
and Campaign graph state (engine.graph).
"""

import json;
import re;
import from datetime { datetime, timezone }
import from http { HTTPMethod }
import from os { environ }
import from pathlib { Path }

import from engine.types {
    GeoPoint,
    HullGeometry,
    MaterialConfig,
    MaterialModel,
    OceanConditions,
    PropulsionSpec,
    RouteSegment,
    SearchSpace,
    VesselConfig,
    VoyageRoute,
    ZoneSpec,
    parse_hull_zone
}
import from engine.materials { parse_weld, parse_seal, resolve_material_model }
import from engine.config { uniform }
import from engine.voyage { run_voyage }
import from engine.envelope { build_output }
import from engine.optimizer {
    default_sweep,
    optimizer_as_ai_output,
    run_optimizer
}
import from engine.brief {
    default_sim_hull,
    default_sim_propulsion,
    run_brief,
    validate_propulsion
}
import from engine.hull { default_hull_geometry }
import from engine.propulsion { default_propulsion_spec }
import from engine.ocean { default_ocean_conditions }
import from engine.graph {
    MAX_ITERATIONS,
    active_gemini_status,
    campaign_manifest,
    clear_active_gemini_run,
    complete_campaign,
    create_campaign,
    gemini_api_key_present,
    get_simulation,
    list_simulation_entries,
    parse_simulation_id,
    set_active_gemini_run,
    stop_active_gemini_run,
    store_iteration
}
import from agent { run_campaign }

# Project paths (relative to cwd when `jac start` is launched from repo root)
glob ROOT_DIR: str = str(Path(".").resolve());
glob RESULT_FILE: str = str(Path("result.json").resolve());
glob MISSION_BRIEFS_DIR: str = str(Path("mission-briefs").resolve());
glob EXAMPLES_DIR: str = str(Path("examples").resolve());

# ---------------------------------------------------------------------------
# JSON / dict helpers
# ---------------------------------------------------------------------------

def:priv _as_dict(value: any) -> dict[str, any] | None {
    if isinstance(value, dict) {
        return value as dict[str, any];
    }
    return None;
}

def:priv _f(d: dict[str, any], key: str, fallback: float) -> float {
    if key not in d or d[key] is None {
        return fallback;
    }
    return float(str(d[key]));
}

def:priv _opt_f(d: dict[str, any], key: str) -> float | None {
    if key not in d or d[key] is None {
        return None;
    }
    return float(str(d[key]));
}

def:priv _opt_i(d: dict[str, any], key: str) -> int | None {
    if key not in d or d[key] is None {
        return None;
    }
    return int(str(d[key]));
}

def:priv _opt_s(d: dict[str, any], key: str) -> str | None {
    if key not in d or d[key] is None {
        return None;
    }
    return str(d[key]);
}

def:priv _s(d: dict[str, any], key: str, fallback: str) -> str {
    if key not in d or d[key] is None {
        return fallback;
    }
    return str(d[key]);
}

def:priv _geo(d: dict[str, any] | None, lat0: float = 0.0, lon0: float = 0.0) -> GeoPoint {
    if d is None {
        return GeoPoint(lat_deg=lat0, lon_deg=lon0);
    }
    return GeoPoint(lat_deg=_f(d, "lat_deg", lat0), lon_deg=_f(d, "lon_deg", lon0));
}

def:priv _hull_from_dict(d: dict[str, any] | None, base: HullGeometry) -> HullGeometry {
    if d is None {
        return base;
    }
    return HullGeometry(
        loa_m=_f(d, "loa_m", base.loa_m),
        beam_m=_f(d, "beam_m", base.beam_m),
        depth_m=_f(d, "depth_m", base.depth_m),
        draft_m=_f(d, "draft_m", base.draft_m),
        block_coeff=_f(d, "block_coeff", base.block_coeff),
        waterplane_coeff=_f(d, "waterplane_coeff", base.waterplane_coeff)
    );
}

def:priv _prop_from_dict(d: dict[str, any] | None, base: PropulsionSpec) -> PropulsionSpec {
    if d is None {
        return base;
    }
    return PropulsionSpec(
        max_power_kw=_f(d, "max_power_kw", base.max_power_kw),
        fuel_capacity_kg=_f(d, "fuel_capacity_kg", base.fuel_capacity_kg),
        sfc_g_per_kwh=_f(d, "sfc_g_per_kwh", base.sfc_g_per_kwh),
        propulsive_efficiency=_f(d, "propulsive_efficiency", base.propulsive_efficiency),
        hull_drag_coeff=_f(d, "hull_drag_coeff", base.hull_drag_coeff)
    );
}

def:priv _ocean_from_dict(d: dict[str, any] | None, base: OceanConditions) -> OceanConditions {
    if d is None {
        return base;
    }
    return OceanConditions(
        hs_m=_f(d, "hs_m", base.hs_m),
        tp_s=_f(d, "tp_s", base.tp_s),
        jonswap_gamma=_f(d, "jonswap_gamma", base.jonswap_gamma),
        encounter_angle_deg=_f(d, "encounter_angle_deg", base.encounter_angle_deg),
        water_temp_c=_f(d, "water_temp_c", base.water_temp_c),
        salinity_ppt=_f(d, "salinity_ppt", base.salinity_ppt),
        ph=_f(d, "ph", base.ph),
        wind_speed_ms=_f(d, "wind_speed_ms", base.wind_speed_ms),
        slam_probability=_f(d, "slam_probability", base.slam_probability)
    );
}

def:priv _material_from_json(value: any) -> MaterialModel {
    if isinstance(value, str) {
        return resolve_material_model(value);
    }
    d = _as_dict(value);
    if d is not None {
        cfg = MaterialConfig(
            grade=_opt_s(d, "grade"),
            label=_opt_s(d, "label"),
            strength_index=_opt_f(d, "strength_index"),
            cost=_opt_f(d, "cost"),
            cost_unit=_opt_s(d, "cost_unit"),
            heat_threshold_c=_opt_f(d, "heat_threshold_c"),
            cold_threshold_c=_opt_f(d, "cold_threshold_c"),
            dust_coeff=_opt_f(d, "dust_coeff"),
            humidity_coeff=_opt_f(d, "humidity_coeff"),
            salinity_coeff=_opt_f(d, "salinity_coeff"),
            uv_coeff=_opt_f(d, "uv_coeff"),
            density_kg_m3=_opt_f(d, "density_kg_m3"),
            yield_mpa=_opt_f(d, "yield_mpa"),
            uts_mpa=_opt_f(d, "uts_mpa"),
            e_gpa=_opt_f(d, "e_gpa"),
            k_ic_mpa_sqrtm=_opt_f(d, "k_ic_mpa_sqrtm"),
            min_temp_c=_opt_f(d, "min_temp_c"),
            sn_slope=_opt_f(d, "sn_slope"),
            sn_ref_stress_mpa=_opt_f(d, "sn_ref_stress_mpa"),
            sn_ref_cycles=_opt_i(d, "sn_ref_cycles"),
            cost_per_kg_usd=_opt_f(d, "cost_per_kg_usd"),
            base_corrosion_rate_mm_yr=_opt_f(d, "base_corrosion_rate_mm_yr")
        );
        return resolve_material_model(cfg);
    }
    raise ValueError("material must be a string grade or MaterialConfig object");
}

def:priv _zone_from_dict(d: dict[str, any]) -> ZoneSpec {
    zone_key = _s(d, "zone", "");
    zone = parse_hull_zone(zone_key);
    if zone is None {
        raise ValueError(f"unknown hull zone '{zone_key}'");
    }
    weld = parse_weld(_s(d, "weld_quality", "Standard"));
    if weld is None {
        raise ValueError(f"unknown weld_quality '{d.get('weld_quality')}'");
    }
    seal = parse_seal(_s(d, "seal_quality", "Commercial"));
    if seal is None {
        raise ValueError(f"unknown seal_quality '{d.get('seal_quality')}'");
    }
    return ZoneSpec(
        zone=zone,
        material=_material_from_json(d.get("material")),
        thickness_m=_f(d, "thickness_m", 0.005),
        weld_quality=weld,
        seal_quality=seal
    );
}

"""Parse a full vessel_config.json dict into VesselConfig."""
def parse_vessel_config(data: dict[str, any]) -> VesselConfig {
    hull = _hull_from_dict(_as_dict(data.get("hull")), default_sim_hull());
    prop = _prop_from_dict(_as_dict(data.get("propulsion")), default_sim_propulsion());
    zones_raw = data.get("zones", []);
    if not isinstance(zones_raw, list) or len(zones_raw) == 0 {
        raise ValueError("vessel config requires a non-empty zones list");
    }
    zones: list[ZoneSpec] = [];
    for z_any in zones_raw {
        z = _as_dict(z_any);
        if z is None {
            raise ValueError("invalid zone entry");
        }
        zones.append(_zone_from_dict(z));
    }
    return VesselConfig(hull=hull, zones=zones, propulsion=prop);
}

"""Parse a voyage_route.json dict (uses from/to keys) into VoyageRoute."""
def parse_voyage_route(data: dict[str, any]) -> VoyageRoute {
    origin = _geo(_as_dict(data.get("origin")));
    destination = _geo(_as_dict(data.get("destination")));
    segments_raw = data.get("segments", []);
    if not isinstance(segments_raw, list) or len(segments_raw) == 0 {
        raise ValueError("voyage route requires a non-empty segments list");
    }
    segments: list[RouteSegment] = [];
    base_ocean = default_ocean_conditions();
    for seg_any in segments_raw {
        seg = _as_dict(seg_any);
        if seg is None {
            continue;
        }
        from_pt = _geo(_as_dict(seg.get("from")), origin.lat_deg, origin.lon_deg);
        to_pt = _geo(_as_dict(seg.get("to")), destination.lat_deg, destination.lon_deg);
        conditions = _ocean_from_dict(_as_dict(seg.get("conditions")), base_ocean);
        segments.append(RouteSegment(
            from_pt=from_pt,
            to_pt=to_pt,
            distance_nm=_f(seg, "distance_nm", 0.0),
            heading_deg=_f(seg, "heading_deg", 0.0),
            conditions=conditions,
            label=_s(seg, "label", ""),
            duration_scale=_f(seg, "duration_scale", 1.0)
        ));
    }
    if len(segments) == 0 {
        raise ValueError("voyage route produced no segments");
    }
    return VoyageRoute(origin=origin, destination=destination, segments=segments);
}

def parse_search_space(data: dict[str, any]) -> SearchSpace {
    hull = _hull_from_dict(_as_dict(data.get("hull")), default_hull_geometry());
    prop = _prop_from_dict(_as_dict(data.get("propulsion")), default_propulsion_spec());
    materials = data.get("materials", []);
    welds = data.get("weld_qualities", []);
    seals = data.get("seal_qualities", []);
    thicknesses = data.get("thicknesses_m", []);
    if not isinstance(materials, list) or len(materials) == 0 {
        raise ValueError("search_space.materials must be a non-empty list");
    }
    if not isinstance(welds, list) or len(welds) == 0 {
        raise ValueError("search_space.weld_qualities must be a non-empty list");
    }
    if not isinstance(seals, list) or len(seals) == 0 {
        raise ValueError("search_space.seal_qualities must be a non-empty list");
    }
    if not isinstance(thicknesses, list) or len(thicknesses) == 0 {
        raise ValueError("search_space.thicknesses_m must be a non-empty list");
    }
    mat_out: list[str] = [];
    for m in materials {
        mat_out.append(str(m));
    }
    weld_out: list[str] = [];
    for w in welds {
        weld_out.append(str(w));
    }
    seal_out: list[str] = [];
    for s in seals {
        seal_out.append(str(s));
    }
    thick_out: list[float] = [];
    for t in thicknesses {
        thick_out.append(float(str(t)));
    }
    return SearchSpace(
        hull=hull,
        propulsion=prop,
        materials=mat_out,
        weld_qualities=weld_out,
        seal_qualities=seal_out,
        thicknesses_m=thick_out
    );
}

"""Port of SimulationParams::into_config_and_route (simulate-params path)."""
def params_to_config_and_route(params: dict[str, any]) -> tuple[VesselConfig, VoyageRoute] {
    hull = _hull_from_dict(_as_dict(params.get("hull")), default_sim_hull());
    propulsion = _prop_from_dict(_as_dict(params.get("propulsion")), default_sim_propulsion());
    err = validate_propulsion(propulsion);
    if err is not None {
        raise ValueError(err);
    }

    zones_raw = params.get("zones");
    config: VesselConfig;
    if isinstance(zones_raw, list) and len(zones_raw) > 0 {
        zones: list[ZoneSpec] = [];
        for z_any in zones_raw {
            z_dict = _as_dict(z_any);
            if z_dict is None {
                raise ValueError("invalid zone entry");
            }
            zones.append(_zone_from_dict(z_dict));
        }
        for zone_spec in zones {
            if zone_spec.thickness_m <= 0.0 {
                raise ValueError("zone thickness_m must be positive");
            }
        }
        config = VesselConfig(hull=hull, zones=zones, propulsion=propulsion);
    } else {
        construction = _as_dict(params.get("construction"));
        if construction is None {
            construction = {};
        }
        material = _material_from_json(construction.get("material", "MildSteelA"));
        thickness_m = _f(construction, "thickness_m", 0.004);
        if thickness_m <= 0.0 {
            raise ValueError("construction.thickness_m must be positive");
        }
        weld = parse_weld(_s(construction, "weld_quality", "Economy"));
        seal = parse_seal(_s(construction, "seal_quality", "Economy"));
        if weld is None or seal is None {
            raise ValueError("invalid construction weld_quality or seal_quality");
        }
        config = uniform(hull, material, thickness_m, weld, seal, propulsion);
    }

    route_p = _as_dict(params.get("route"));
    if route_p is None {
        route_p = {};
    }
    origin = _geo(_as_dict(route_p.get("origin")), 35.0, -74.5);
    destination = _geo(_as_dict(route_p.get("destination")), 32.3, -64.78);
    distance_nm = _f(route_p, "distance_nm", 580.0);
    if distance_nm <= 0.0 {
        raise ValueError("route.distance_nm must be positive");
    }
    heading_deg = _f(route_p, "heading_deg", 110.0);
    label = _s(route_p, "label", "Cape Hatteras -> Bermuda (open Atlantic)");

    # Default open-atlantic conditions (main.rs::default_open_atlantic_conditions)
    atlantic = OceanConditions(
        hs_m=3.2,
        tp_s=10.0,
        jonswap_gamma=3.5,
        encounter_angle_deg=15.0,
        water_temp_c=22.0,
        salinity_ppt=36.0,
        ph=8.1,
        wind_speed_ms=14.0,
        slam_probability=0.42
    );
    conditions = _ocean_from_dict(_as_dict(params.get("conditions")), atlantic);

    route = VoyageRoute(
        origin=origin,
        destination=destination,
        segments=[RouteSegment(
            from_pt=origin,
            to_pt=destination,
            distance_nm=distance_nm,
            heading_deg=heading_deg,
            conditions=conditions,
            label=label,
            duration_scale=1.0
        )]
    );
    return (config, route);
}

# ---------------------------------------------------------------------------
# Mission briefs on disk
# ---------------------------------------------------------------------------

def mission_brief_by_id(mission_id: str) -> dict[str, any] | None {
    if not mission_id or not re.match(r"^[A-Za-z0-9_-]+$", mission_id) {
        return None;
    }
    briefs_dir = Path(MISSION_BRIEFS_DIR);
    if not briefs_dir.exists() {
        return None;
    }
    for file in briefs_dir.iterdir() {
        if file.suffix != ".json" {
            continue;
        }
        try {
            data = json.loads(file.read_text(encoding="utf-8"));
        } except Exception {
            continue;
        }
        parsed = _as_dict(data);
        if parsed is not None and parsed.get("id") == mission_id {
            return parsed;
        }
    }
    return None;
}

def:priv _safe_read_json(path: str) -> dict[str, any] | None {
    p = Path(path);
    if not p.exists() {
        return None;
    }
    try {
        data = json.loads(p.read_text(encoding="utf-8"));
        return _as_dict(data);
    } except Exception {
        return None;
    }
}

def:priv _run_stamp() -> str {
    return (
        datetime.now(timezone.utc)
        .isoformat()
        .replace(":", "-")
        .replace(".", "-")
        .replace("+00:00", "Z")
    );
}

# ---------------------------------------------------------------------------
# Gemini campaign orchestration (in-process; LLM loop lives in agent.jac)
# ---------------------------------------------------------------------------

"""Run a Gemini-guided campaign in-process via agent.run_campaign.

Active-run state lives in engine.graph (replaces child_process). Iterations from
the agent manifest are also persisted under the Campaign node for GET /api/simulations.
"""
def execute_gemini_run(
    mission_id: str,
    tier: str,
    max_iterations: int,
    run_id: str
) -> dict {
    stop_active_gemini_run();

    brief = mission_brief_by_id(mission_id);
    if brief is None {
        raise ValueError(
            f"POST /api/gemini/run requires a valid selected mission_id; got {mission_id}"
        );
    }

    model_name = environ.get("BYLLM_MODEL") or "gemini/gemini-2.5-flash";
    campaign = create_campaign(
        mission_id=mission_id,
        tier=tier,
        model=model_name,
        max_iterations=max_iterations,
        run_id=run_id
    );
    set_active_gemini_run(
        run_id=run_id,
        mission_id=mission_id,
        started_at=campaign.started_at,
        max_iterations=max_iterations,
        campaign_jid=jid(campaign)
    );

    try {
        manifest = run_campaign(
            document_in=dict(brief),
            tier=tier,
            max_iterations=max_iterations,
            run_id=run_id,
            mode="brief"
        );

        # Mirror agent iterations onto the Campaign graph for list/get endpoints.
        iters = manifest.get("iterations", []) if isinstance(manifest, dict) else [];
        if isinstance(iters, list) {
            for entry_any in iters {
                if not isinstance(entry_any, dict) {
                    continue;
                }
                entry = entry_any as dict[str, any];
                idx = int(str(entry.get("iteration", 0)));
                # Agent may only store file paths; prefer inlined result/assessment.
                result_val = entry.get("result");
                assessment_val = entry.get("assessment");
                result_dict = (
                    result_val as dict[str, any]
                    if isinstance(result_val, dict)
                    else None
                );
                assessment_dict = (
                    assessment_val as dict[str, any]
                    if isinstance(assessment_val, dict)
                    else {
                        "assessment": str(entry.get("strategy", "")),
                        "changes": []
                    }
                );
                params_val = entry.get("params");
                params_dict = (
                    params_val as dict[str, any]
                    if isinstance(params_val, dict)
                    else {"tier": tier, "mission_id": mission_id}
                );
                if result_dict is not None {
                    store_iteration(
                        campaign,
                        idx,
                        str(entry.get("status", "unknown")),
                        params_dict,
                        result_dict,
                        assessment_dict
                    );
                }
            }
        }

        if campaign.stopped {
            complete_campaign(campaign, "stopped");
        } else {
            complete_campaign(campaign, "completed");
        }
        # Prefer agent manifest (matches Express stdout) when present.
        if isinstance(manifest, dict) {
            return manifest;
        }
        return campaign_manifest(campaign);
    } except Exception as exc {
        complete_campaign(campaign, "error");
        raise exc;
    } finally {
        clear_active_gemini_run();
    }
}

# ---------------------------------------------------------------------------
# Endpoints — mirror every Express route in ui/server.js
# ---------------------------------------------------------------------------

# GET /api/health
@restspec(method=HTTPMethod.GET, path="/api/health")
walker:pub api_health {
    can run with Root entry {
        # Jac engine is always in-process; surface example assets as readiness.
        examples_ok = (
            Path(EXAMPLES_DIR, "vessel_config.json").exists()
            and Path(EXAMPLES_DIR, "voyage_route.json").exists()
        );
        report {
            "status": "ok" if examples_ok else "error",
            "engine": "jac",
            "exists": examples_ok,
            "binary": "in-process"
        };
    }
}

# GET /api/result
@restspec(method=HTTPMethod.GET, path="/api/result")
walker:pub api_result {
    can run with Root entry {
        parsed = _safe_read_json(RESULT_FILE);
        if parsed is None {
            report {
                "error": "result.json not found. Run a simulation first (POST /api/simulate)."
            };
            disengage;
        }
        report parsed;
    }
}

# GET /api/simulations
@restspec(method=HTTPMethod.GET, path="/api/simulations")
walker:pub api_simulations {
    can run with Root entry {
        report {"simulations": list_simulation_entries()};
    }
}

# GET /api/gemini/status
@restspec(method=HTTPMethod.GET, path="/api/gemini/status")
walker:pub api_gemini_status {
    can run with Root entry {
        report active_gemini_status();
    }
}

# POST /api/gemini/stop
@restspec(method=HTTPMethod.POST, path="/api/gemini/stop")
walker:pub api_gemini_stop {
    can run with Root entry {
        status = active_gemini_status();
        stopped = stop_active_gemini_run();
        report {
            "stopped": stopped,
            "run_id": status.get("run_id")
        };
    }
}

# GET /api/simulation?id=<run-id/iteration-XX>
@restspec(method=HTTPMethod.GET, path="/api/simulation")
walker:pub api_simulation {
    has id: str = "";

    can run with Root entry {
        if not re.match(r"^[A-Za-z0-9_.:/-]+/iteration-\d+$", self.id) {
            # Keep the Express error text for the common case.
            if parse_simulation_id(self.id) is None {
                report {
                    "error": "GET /api/simulation requires id=<run-id/iteration-XX>"
                };
                disengage;
            }
        }
        loaded = get_simulation(self.id);
        if loaded is None {
            report {"error": "simulation result not found"};
            disengage;
        }
        if loaded.get("pending") {
            report {"error": "simulation is still running analysis"};
            disengage;
        }
        report loaded;
    }
}

# POST /api/gemini/run
@restspec(method=HTTPMethod.POST, path="/api/gemini/run")
walker:pub api_gemini_run {
    has mission_id: str | None = None;
    has brief: dict[str, any] | None = None;
    has tier: str = "lowest";
    has max_iterations: int = MAX_ITERATIONS;
    has run_id: str | None = None;

    can run with Root entry {
        try {
            mission_key_in: str = "";
            if self.mission_id is not None {
                mission_key_in = str(self.mission_id);
            } elif self.brief is not None and self.brief.get("id") is not None {
                mission_key_in = str(self.brief.get("id"));
            }
            brief = mission_brief_by_id(mission_key_in);
            if not gemini_api_key_present() {
                # byLLM may still work via provider defaults, but mirror Express guard.
                if not environ.get("BYLLM_API_KEY") {
                    report {
                        "error": "GEMINI_API_KEY is not set on the API server process"
                    };
                    disengage;
                }
            }
            if brief is None {
                got = mission_key_in if mission_key_in else "none";
                report {
                    "error": (
                        "POST /api/gemini/run requires a valid selected mission_id; got "
                        + got
                    )
                };
                disengage;
            }

            mission_key = re.sub(r"[^A-Za-z0-9_-]", "_", str(brief["id"]));
            stamp = _run_stamp();
            run_id = self.run_id if self.run_id else f"{mission_key}_{stamp}";
            max_iter = int(self.max_iterations) if self.max_iterations else MAX_ITERATIONS;

            manifest = execute_gemini_run(
                mission_id=str(brief["id"]),
                tier=self.tier if self.tier else "lowest",
                max_iterations=max_iter,
                run_id=run_id
            );
            report manifest;
        } except Exception as e {
            report {"error": str(e)};
        }
    }
}

# POST /api/demo
@restspec(method=HTTPMethod.POST, path="/api/demo")
walker:pub api_demo {
    can run with Root entry {
        try {
            hull = default_hull_geometry();
            prop = default_propulsion_spec();
            # Demo route: Norfolk → Brest style open-ocean single segment via defaults
            empty_params: dict[str, any] = {};
            (_, route) = params_to_config_and_route(empty_params);
            # Use hull/prop defaults matching SearchSpace::default_sweep
            space = default_sweep(hull, prop);
            # Rebuild route with demo hull's companion — params_to_config uses sim hull;
            # for demo output we only need the optimizer envelope (cmd_demo).
            opt = run_optimizer(space, route);
            report optimizer_as_ai_output(opt);
        } except Exception as e {
            report {"error": str(e)};
        }
    }
}

# POST /api/simulate  — { params } OR { config, route }
@restspec(method=HTTPMethod.POST, path="/api/simulate")
walker:pub api_simulate {
    has params: dict[str, any] | None = None;
    has config: dict[str, any] | None = None;
    has route: dict[str, any] | None = None;

    can run with Root entry {
        try {
            # Express: params ?? (!config ? body : null) — body fields already mapped to has
            use_params = self.params;
            if use_params is None and self.config is None {
                # Treat top-level body-as-params when client posts simulation_params shape
                # (hull/propulsion/construction keys). Walker's has fields only expose the
                # three named keys; nested params must be sent as { "params": {...} }.
                use_params = None;
            }

            if use_params is not None {
                (config, route) = params_to_config_and_route(use_params);
            } else {
                if self.config is None or self.route is None {
                    report {
                        "error": "POST /api/simulate requires either { params } or { config, route }"
                    };
                    disengage;
                }
                config = parse_vessel_config(self.config);
                route = parse_voyage_route(self.route);
            }

            outcome = run_voyage(config, route);
            envelope = build_output(config, route, outcome, None);

            # Persist last result for GET /api/result compatibility
            try {
                Path(RESULT_FILE).write_text(
                    json.dumps(envelope, indent=2) + "\n", encoding="utf-8"
                );
            } except Exception {
                _ = None;
            }

            report envelope;
        } except Exception as e {
            report {"error": str(e)};
        }
    }
}

# POST /api/brief — { brief, tier?, zones? }
@restspec(method=HTTPMethod.POST, path="/api/brief")
walker:pub api_brief {
    has brief: dict[str, any] | None = None;
    has tier: str = "cheapest";
    has zones: list[dict[str, any]] | None = None;

    can run with Root entry {
        try {
            if self.brief is None {
                report {
                    "error": "POST /api/brief requires { brief, tier?, zones? }"
                };
                disengage;
            }
            brief_payload = dict(self.brief);
            if self.zones is not None {
                brief_payload["zones"] = self.zones;
            }
            envelope = run_brief(brief_payload, self.tier if self.tier else "cheapest");
            report envelope;
        } except Exception as e {
            report {"error": str(e)};
        }
    }
}

# POST /api/optimize — { search_space, route }
@restspec(method=HTTPMethod.POST, path="/api/optimize")
walker:pub api_optimize {
    has search_space: dict[str, any] | None = None;
    has route: dict[str, any] | None = None;

    can run with Root entry {
        try {
            if self.search_space is None or self.route is None {
                report {
                    "error": "POST /api/optimize requires { search_space, route }"
                };
                disengage;
            }
            space = parse_search_space(self.search_space);
            route = parse_voyage_route(self.route);
            opt = run_optimizer(space, route);
            report optimizer_as_ai_output(opt);
        } except Exception as e {
            report {"error": str(e)};
        }
    }
}
