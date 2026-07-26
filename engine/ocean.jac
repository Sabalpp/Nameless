"""Ocean condition helpers — port of src/environment/ocean.rs."""

import from math { cos, fabs, pi, radians, sqrt }

import from engine.types { OceanConditions }

"Zero-crossing period Tz [s] derived from JONSWAP spectral shape."
def zero_crossing_period_s(conditions: OceanConditions) -> float {
    gamma_correction = 1.0 - 0.132 * sqrt(max(conditions.jonswap_gamma - 1.0, 0.0));
    clamped = max(0.68, min(0.78, gamma_correction));
    return conditions.tp_s * clamped;
}

"Encounter angle factor — reduces effective wave loading for non-head seas."
def encounter_factor(conditions: OceanConditions) -> float {
    angle_rad = radians(conditions.encounter_angle_deg);
    factor = fabs(cos(angle_rad)) * 0.65 + 0.35;
    return max(0.35, min(1.0, factor));
}

"Wave steepness — proxy for breaking / slamming severity."
def steepness(conditions: OceanConditions) -> float {
    lambda_p = 9.81 * (conditions.tp_s ** 2) / (2.0 * pi);
    if lambda_p > 0.0 {
        return conditions.hs_m / lambda_p;
    }
    return 0.0;
}

"Default open-ocean sea state (Rust Default for OceanConditions)."
def default_ocean_conditions() -> OceanConditions {
    return OceanConditions(
        hs_m=2.5,
        tp_s=9.0,
        jonswap_gamma=3.3,
        encounter_angle_deg=0.0,
        water_temp_c=15.0,
        salinity_ppt=35.0,
        ph=8.1,
        wind_speed_ms=10.0,
        slam_probability=0.15
    );
}
