"""Failure / completion helpers — port of src/sim/outcome.rs methods.

Types live in engine/types.jac. This module provides free-function ports of
FailureMode::{label, diagnosis}, FailureDiagnosis::completion_pct, and
SimOutcome::{survived, completion_pct}.
"""

import from engine.types {
    FailureDiagnosis,
    FailureMode,
    FailureModeKind,
    SimOutcome,
    hull_zone_label
}

"Human-readable failure label — FailureMode::label()."
def failure_mode_label(mode: FailureMode) -> str {
    match mode.kind {
        case FailureModeKind.CAPSIZE: return "Capsize";
        case FailureModeKind.FATIGUE_FAILURE: return "Fatigue Failure";
        case FailureModeKind.BRITTLE_FRACTURE: return "Brittle Fracture";
        case FailureModeKind.FUEL_EXHAUSTION: return "Fuel Exhaustion";
        case FailureModeKind.SEAL_BREACH_FLOODING: return "Seal Breach / Flooding";
        case FailureModeKind.COLD_TEMPERATURE_BRITTLENESS:
            return "Cold-Temperature Embrittlement";
    }
}

def:priv _zone_name(mode: FailureMode) -> str {
    if mode.zone is not None {
        return hull_zone_label(mode.zone);
    }
    return "Unknown";
}

"""Human-readable explanation — FailureMode::diagnosis().

Returns [why, suggested_fix] matching the Rust (String, String) tuple.
"""
def failure_diagnosis(mode: FailureMode) -> list[str] {
    match mode.kind {
        case FailureModeKind.CAPSIZE:
            why = (
                f"Metacentric height GM = {mode.gm_m:.3f} m fell below safety minimum "
                + f"{mode.gm_required_m:.3f} m. Likely cause: fuel burned off, raising CG; "
                + "or heavy beam seas."
            );
            fix = (
                "Increase beam or reduce depth. Add ballast capacity, or widen waterplane area "
                + "to raise BM. Avoid beam-sea headings in high sea states."
            );
            return [why, fix];
        case FailureModeKind.FATIGUE_FAILURE:
            zone_name = _zone_name(mode);
            why = (
                f"Miner's cumulative damage reached {mode.damage_accumulated:.2f} at "
                + f"{zone_name} — weld toe cracking likely. "
                + "S-N curve exhausted by repeated wave loading."
            );
            fix = (
                "Upgrade weld class (Premium reduces SCF from 2.65 → 1.50) or increase plate "
                + "thickness. Higher-grade steel improves yield but not fatigue class without "
                + "weld improvement."
            );
            return [why, fix];
        case FailureModeKind.BRITTLE_FRACTURE:
            zone_name = _zone_name(mode);
            why = (
                f"Applied K = {mode.k_applied_mpa_sqrtm:.1f} MPa·√m exceeded material toughness "
                + f"K_IC = {mode.k_ic_mpa_sqrtm:.1f} MPa·√m at {zone_name}. "
                + "Crack grew to critical size."
            );
            fix = (
                "Use a tougher material grade (DH36/EH36 vs AH36), reduce initial weld defect "
                + "size (Premium weld), or add crack-arrest strakes adjacent to high-stress zones."
            );
            return [why, fix];
        case FailureModeKind.FUEL_EXHAUSTION:
            why = (
                f"Fuel exhausted with {mode.distance_remaining_nm:.0f} nm remaining. "
                + "Wave resistance or headwinds exceeded design fuel budget."
            );
            fix = (
                "Increase fuel capacity, reduce hull drag coefficient, or reroute to avoid "
                + "the heaviest sea states. Reducing payload mass also improves range."
            );
            return [why, fix];
        case FailureModeKind.SEAL_BREACH_FLOODING:
            zone_name = _zone_name(mode);
            why = (
                f"Seal breach at {zone_name} after {mode.elapsed_h:.1f} h — progressive flooding "
                + "compromised watertight integrity."
            );
            fix = (
                "Upgrade to Marine-grade EPDM seals. Add redundant bilge pump capacity and "
                + "automated flooding detection to allow controlled response."
            );
            return [why, fix];
        case FailureModeKind.COLD_TEMPERATURE_BRITTLENESS:
            zone_name = _zone_name(mode);
            why = (
                f"Water temperature {mode.water_temp_c:.1f}°C is below material minimum service "
                + f"temperature {mode.min_rated_temp_c:.1f}°C at {zone_name}. "
                + "Material may undergo ductile-brittle transition."
            );
            fix = (
                "Switch to a cold-rated grade: MildSteelE (rated to −40°C), DH36, or EH36. "
                + "Alternatively reroute to avoid sub-zero water temperatures."
            );
            return [why, fix];
    }
}

"""Structured failure detail for the envelope `failure.detail` object.

Mirrors the match arms in main.rs::build_output.
"""
def failure_detail(mode: FailureMode) -> dict[str, any] {
    match mode.kind {
        case FailureModeKind.FATIGUE_FAILURE:
            return {
                "failed_zone": _zone_name(mode),
                "failed_metric": "fatigue",
                "failed_value": "100%",
                "raw_fatigue_consumed": mode.damage_accumulated
            };
        case FailureModeKind.BRITTLE_FRACTURE:
            mm = mode.crack_half_length_m * 1000.0;
            return {
                "failed_zone": _zone_name(mode),
                "failed_metric": "crack",
                "failed_value": f"{mm:.1f} mm"
            };
        case FailureModeKind.SEAL_BREACH_FLOODING:
            return {
                "failed_zone": _zone_name(mode),
                "failed_metric": "seal",
                "failed_value": "failed"
            };
        case FailureModeKind.COLD_TEMPERATURE_BRITTLENESS:
            return {
                "failed_zone": _zone_name(mode),
                "failed_metric": "temperature",
                "failed_value": f"{mode.water_temp_c:.1f}°C"
            };
        case FailureModeKind.CAPSIZE:
            return {
                "failed_zone": "Vessel",
                "failed_metric": "stability",
                "failed_value": f"GM {mode.gm_m:.2f} m"
            };
        case FailureModeKind.FUEL_EXHAUSTION:
            return {
                "failed_zone": "Propulsion",
                "failed_metric": "fuel",
                "failed_value": "0%"
            };
    }
}

"Percent of route completed — shared by FailureDiagnosis and SimOutcome."
def completion_pct(distance_completed_nm: float, total_distance_nm: float) -> float {
    if total_distance_nm > 0.0 {
        return distance_completed_nm / total_distance_nm * 100.0;
    }
    return 0.0;
}

"FailureDiagnosis::completion_pct()."
def failure_completion_pct(d: FailureDiagnosis) -> float {
    return completion_pct(d.distance_completed_nm, d.total_distance_nm);
}

"SimOutcome::completion_pct()."
def outcome_completion_pct(outcome: SimOutcome) -> float {
    return completion_pct(outcome.distance_completed_nm, outcome.total_distance_nm);
}

"SimOutcome::survived() — True when no failure was recorded."
def survived(outcome: SimOutcome) -> bool {
    return outcome.failure is None;
}
