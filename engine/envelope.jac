"""UI JSON envelope — port of main.rs::build_output (schema_version 1.0).

build_output(config, route, outcome, optimizer=None) -> dict matching the exact
contract consumed by the SeaForge UI / parity harness:
  schema_version, status, voyage, result, configuration, failure, zones, ticks, optimizer
"""

import from engine.types {
    FailureDiagnosis,
    HullZone,
    MaterialConfig,
    MaterialGrade,
    MaterialModel,
    OptimizerResult,
    SealQuality,
    SegmentSnapshot,
    SimOutcome,
    SurvivorEntry,
    VesselConfig,
    VoyageRoute,
    WeldQuality,
    ZoneSpec,
    ZoneSummary,
    hull_zone_label
}
import from engine.cost { cost_breakdown_for_config }
import from engine.config { shell_mass_kg }
import from engine.materials { material_spec, label }
import from engine.route { total_distance_nm }
import from engine.outcome {
    failure_mode_label,
    failure_diagnosis,
    failure_detail,
    failure_completion_pct,
    outcome_completion_pct,
    survived
}

# ---------------------------------------------------------------------------
# Serialization helpers (match Rust serde / Debug formatting)
# ---------------------------------------------------------------------------

"Rust Debug / serde key for HullZone (Keel, BilgeStrake, …)."
def:priv hull_zone_key(zone: HullZone) -> str {
    match zone {
        case HullZone.KEEL: return "Keel";
        case HullZone.BILGE_STRAKE: return "BilgeStrake";
        case HullZone.BOTTOM_PLATING: return "BottomPlating";
        case HullZone.SIDE_PLATING: return "SidePlating";
        case HullZone.BOW_FLARE: return "BowFlare";
        case HullZone.STERN_PLATE: return "SternPlate";
        case HullZone.TRANSOM_FRAME: return "TransomFrame";
        case HullZone.WEATHER_DECK: return "WeatherDeck";
        case HullZone.BULKHEAD_FRAME: return "BulkheadFrame";
    }
}

def:priv weld_quality_key(weld: WeldQuality) -> str {
    match weld {
        case WeldQuality.PREMIUM: return "Premium";
        case WeldQuality.STANDARD: return "Standard";
        case WeldQuality.ECONOMY: return "Economy";
    }
}

def:priv seal_quality_key(seal: SealQuality) -> str {
    match seal {
        case SealQuality.MARINE: return "Marine";
        case SealQuality.COMMERCIAL: return "Commercial";
        case SealQuality.ECONOMY: return "Economy";
    }
}

"""Serialize MaterialModel the way serde does (untagged):
grade/string → \"Ah36\"; MaterialConfig → object with present fields.
"""
def:priv material_json(model: MaterialModel) -> str | dict[str, any] {
    if isinstance(model, MaterialConfig) {
        out: dict[str, any] = {};
        if model.grade is not None { out["grade"] = model.grade; }
        if model.label is not None { out["label"] = model.label; }
        if model.strength_index is not None { out["strength_index"] = model.strength_index; }
        if model.cost is not None { out["cost"] = model.cost; }
        if model.cost_unit is not None { out["cost_unit"] = model.cost_unit; }
        if model.heat_threshold_c is not None { out["heat_threshold_c"] = model.heat_threshold_c; }
        if model.cold_threshold_c is not None { out["cold_threshold_c"] = model.cold_threshold_c; }
        if model.dust_coeff is not None { out["dust_coeff"] = model.dust_coeff; }
        if model.humidity_coeff is not None { out["humidity_coeff"] = model.humidity_coeff; }
        if model.salinity_coeff is not None { out["salinity_coeff"] = model.salinity_coeff; }
        if model.uv_coeff is not None { out["uv_coeff"] = model.uv_coeff; }
        if model.density_kg_m3 is not None { out["density_kg_m3"] = model.density_kg_m3; }
        if model.yield_mpa is not None { out["yield_mpa"] = model.yield_mpa; }
        if model.uts_mpa is not None { out["uts_mpa"] = model.uts_mpa; }
        if model.e_gpa is not None { out["e_gpa"] = model.e_gpa; }
        if model.k_ic_mpa_sqrtm is not None { out["k_ic_mpa_sqrtm"] = model.k_ic_mpa_sqrtm; }
        if model.min_temp_c is not None { out["min_temp_c"] = model.min_temp_c; }
        if model.sn_slope is not None { out["sn_slope"] = model.sn_slope; }
        if model.sn_ref_stress_mpa is not None {
            out["sn_ref_stress_mpa"] = model.sn_ref_stress_mpa;
        }
        if model.sn_ref_cycles is not None { out["sn_ref_cycles"] = model.sn_ref_cycles; }
        if model.cost_per_kg_usd is not None { out["cost_per_kg_usd"] = model.cost_per_kg_usd; }
        if model.base_corrosion_rate_mm_yr is not None {
            out["base_corrosion_rate_mm_yr"] = model.base_corrosion_rate_mm_yr;
        }
        return out;
    }
    if isinstance(model, MaterialGrade) {
        match model {
            case MaterialGrade.MILD_STEEL_A: return "MildSteelA";
            case MaterialGrade.MILD_STEEL_E: return "MildSteelE";
            case MaterialGrade.AH36: return "Ah36";
            case MaterialGrade.DH36: return "Dh36";
            case MaterialGrade.EH36: return "Eh36";
            case MaterialGrade.EH40: return "Eh40";
            case MaterialGrade.ALUMINUM_5083: return "Aluminum5083";
            case MaterialGrade.GRP_E_GLASS: return "GrpEGlass";
            case MaterialGrade.CFRP_EPOXY: return "CfrpEpoxy";
        }
    }
    # Already a string key
    return model;
}

def:priv zone_summary_json(z: ZoneSummary) -> dict[str, any] {
    return {
        "zone": hull_zone_label(z.zone),
        "fatigue_consumed": z.fatigue_consumed,
        "corrosion_depth_mm": z.corrosion_depth_mm,
        "crack_half_length_mm": z.crack_half_length_mm,
        "peak_stress_mpa": z.peak_stress_mpa
    };
}

def:priv zone_spec_json(z: ZoneSpec) -> dict[str, any] {
    spec = material_spec(z.material);
    return {
        "zone": hull_zone_label(z.zone),
        "zone_key": hull_zone_key(z.zone),
        "material": material_json(z.material),
        "material_label": spec.label,
        "thickness_m": z.thickness_m,
        "thickness_mm": z.thickness_m * 1000.0,
        "weld_quality": weld_quality_key(z.weld_quality),
        "weld_label": label(z.weld_quality),
        "seal_quality": seal_quality_key(z.seal_quality),
        "seal_label": label(z.seal_quality)
    };
}

def:priv survivor_json(survivor: SurvivorEntry) -> dict[str, any] {
    return {
        "material": survivor.material,
        "thickness_mm": survivor.thickness_mm,
        "weld_quality": survivor.weld_quality,
        "seal_quality": survivor.seal_quality,
        "cost_usd": survivor.cost_usd,
        "fuel_remaining_kg": survivor.fuel_remaining_kg,
        "final_gm_m": survivor.final_gm_m,
        "worst_zone_fatigue": survivor.worst_zone_fatigue
    };
}

def:priv failure_json(d: FailureDiagnosis) -> dict[str, any] {
    diag = failure_diagnosis(d.mode);
    return {
        "mode": failure_mode_label(d.mode),
        "distance_completed_nm": d.distance_completed_nm,
        "completion_pct": failure_completion_pct(d),
        "segment_index": d.segment_index,
        "segment_label": d.segment_label,
        "elapsed_h": d.elapsed_h,
        "why": diag[0],
        "suggested_fix": diag[1],
        "detail": failure_detail(d.mode)
    };
}

def:priv tick_json(t: SegmentSnapshot) -> dict[str, any] {
    zones: list[dict[str, any]] = [];
    for z in t.zones {
        zones.append(zone_summary_json(z));
    }
    return {
        "segment_index": t.segment_index,
        "segment_label": t.segment_label,
        "distance_completed_nm": t.distance_completed_nm,
        "elapsed_h": t.elapsed_h,
        "speed_kts": t.speed_kts,
        "fuel_remaining_kg": t.fuel_remaining_kg,
        "gm_m": t.gm_m,
        "zones": zones,
        "failure": t.failure
    };
}

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

"""Build the schema_version 1.0 simulation envelope dict.

Matches main.rs::build_output exactly for UI / parity consumption.
"""
def build_output(
    config: VesselConfig,
    route: VoyageRoute,
    outcome: SimOutcome,
    optimizer: OptimizerResult | None = None
) -> dict[str, any] {
    # ---- failure ----
    failure_out: dict[str, any] | None = None;
    if outcome.failure is not None {
        failure_out = failure_json(outcome.failure);
    }

    # ---- zones ----
    zone_out: list[dict[str, any]] = [];
    for z in outcome.zone_summaries {
        zone_out.append(zone_summary_json(z));
    }

    # ---- route segments ----
    route_segments_out: list[dict[str, any]] = [];
    for segment in route.segments {
        c = segment.conditions;
        route_segments_out.append({
            "from": {
                "lat_deg": segment.from_pt.lat_deg,
                "lon_deg": segment.from_pt.lon_deg
            },
            "to": {
                "lat_deg": segment.to_pt.lat_deg,
                "lon_deg": segment.to_pt.lon_deg
            },
            "distance_nm": segment.distance_nm,
            "heading_deg": segment.heading_deg,
            "label": segment.label,
            "conditions": {
                "hs_m": c.hs_m,
                "tp_s": c.tp_s,
                "jonswap_gamma": c.jonswap_gamma,
                "encounter_angle_deg": c.encounter_angle_deg,
                "water_temp_c": c.water_temp_c,
                "salinity_ppt": c.salinity_ppt,
                "ph": c.ph,
                "wind_speed_ms": c.wind_speed_ms,
                "slam_probability": c.slam_probability
            }
        });
    }

    # ---- ticks ----
    ticks_out: list[dict[str, any]] = [];
    for t in outcome.ticks {
        ticks_out.append(tick_json(t));
    }

    # ---- configuration (primary zone + all zones) ----
    configuration_out: dict[str, any] | None = None;
    if len(config.zones) > 0 {
        zone = config.zones[0];
        mspec = material_spec(zone.material);
        zones_cfg: list[dict[str, any]] = [];
        for z in config.zones {
            zones_cfg.append(zone_spec_json(z));
        }
        configuration_out = {
            "material": material_json(zone.material),
            "material_label": mspec.label,
            "thickness_m": zone.thickness_m,
            "thickness_mm": zone.thickness_m * 1000.0,
            "weld_quality": weld_quality_key(zone.weld_quality),
            "weld_label": label(zone.weld_quality),
            "seal_quality": seal_quality_key(zone.seal_quality),
            "seal_label": label(zone.seal_quality),
            "shell_mass_kg": shell_mass_kg(config),
            "propulsion": {
                "max_power_kw": config.propulsion.max_power_kw,
                "fuel_capacity_kg": config.propulsion.fuel_capacity_kg,
                "sfc_g_per_kwh": config.propulsion.sfc_g_per_kwh,
                "propulsive_efficiency": config.propulsion.propulsive_efficiency,
                "hull_drag_coeff": config.propulsion.hull_drag_coeff
            },
            "zones": zones_cfg
        };
    }

    breakdown = cost_breakdown_for_config(config);

    # ---- optimizer ----
    optimizer_out: dict[str, any] | None = None;
    if optimizer is not None {
        if optimizer.cheapest_survivor is not None {
            optimizer_out = {
                "configs_tested": optimizer.configs_tested,
                "survivors_found": optimizer.survivors_found,
                "cheapest_survivor": survivor_json(optimizer.cheapest_survivor)
            };
        } else {
            optimizer_out = {
                "configs_tested": optimizer.configs_tested,
                "survivors_found": optimizer.survivors_found,
                "cheapest_survivor": None
            };
        }
    }

    status = "survived" if survived(outcome) else "failed";

    return {
        "schema_version": "1.0",
        "status": status,
        "voyage": {
            "total_distance_nm": total_distance_nm(route),
            "segments": len(route.segments),
            "origin": {
                "lat_deg": route.origin.lat_deg,
                "lon_deg": route.origin.lon_deg
            },
            "destination": {
                "lat_deg": route.destination.lat_deg,
                "lon_deg": route.destination.lon_deg
            },
            "route_segments": route_segments_out
        },
        "result": {
            "distance_completed_nm": outcome.distance_completed_nm,
            "distance_completed_pct": outcome_completion_pct(outcome),
            "time_elapsed_h": outcome.time_elapsed_h,
            "fuel_remaining_kg": outcome.fuel_remaining_kg,
            "final_gm_m": outcome.final_gm_m,
            "total_config_cost_usd": outcome.total_config_cost_usd,
            "cost_breakdown": {
                "material_usd": breakdown.material_usd,
                "weld_usd": breakdown.weld_usd,
                "seal_usd": breakdown.seal_usd,
                "fuel_capacity_usd": breakdown.fuel_capacity_usd
            }
        },
        "configuration": configuration_out,
        "failure": failure_out,
        "zones": zone_out,
        "ticks": ticks_out,
        "optimizer": optimizer_out
    };
}
