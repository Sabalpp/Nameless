"""Calm-water, wave, and wind resistance — ported from src/physics/resistance.rs."""

import from math { pi, fabs }

import from engine.types { VesselConfig, OceanConditions }
import from engine.hull { draft_at_mass, wetted_area_m2 }
import from engine.ocean { encounter_factor }
import from engine.propulsion { fuel_rate_kg_h }

glob RHO_SEAWATER: float = 1025.0;
glob G: float = 9.81;

"""Calm-water resistance [N] using total resistance coefficient on wetted area.

hull_drag_coeff here is Ct (total resistance coefficient, typically 0.012–0.025
for small high-speed hulls), applied to wetted surface area — not Cd on frontal area.
"""
def:priv calm_water_resistance_n(config: VesselConfig, mass_kg: float, speed_ms: float) -> float {
    draft = draft_at_mass(config.hull, mass_kg);
    wetted = wetted_area_m2(config.hull, draft);
    return 0.5 * RHO_SEAWATER * config.propulsion.hull_drag_coeff * wetted * (speed_ms ** 2);
}

"""Added wave resistance [N] — Boese formulation simplified for head seas.
Scales with Hs² / λ_p × beam × L (energy radiated by ship in waves).
"""
def:priv wave_added_resistance_n(config: VesselConfig, conditions: OceanConditions) -> float {
    lambda_p = G * (conditions.tp_s ** 2) / (2.0 * pi);
    r_aw = (
        RHO_SEAWATER * G * (conditions.hs_m ** 2)
        * (config.hull.beam_m ** 2)
        / (16.0 * max(lambda_p, 0.5))
    );
    return r_aw * encounter_factor(conditions);
}

"""Wind resistance [N] on above-waterline area."""
def:priv wind_resistance_n(config: VesselConfig, wind_speed_ms: float) -> float {
    rho_air: float = 1.225;
    cd_above_water: float = 0.75;
    above_water_area = config.hull.beam_m * (config.hull.depth_m - config.hull.draft_m);
    return 0.5 * rho_air * cd_above_water * above_water_area * (wind_speed_ms ** 2);
}

"""Total resistance [N] at a given speed, mass, and sea state."""
def total_resistance_n(
    config: VesselConfig,
    mass_kg: float,
    speed_ms: float,
    conditions: OceanConditions
) -> float {
    return (
        calm_water_resistance_n(config, mass_kg, speed_ms)
        + wave_added_resistance_n(config, conditions)
        + wind_resistance_n(config, conditions.wind_speed_ms)
    );
}

"""Equilibrium speed [m/s] at maximum continuous power.

Solves R_total(v) = T_available iteratively. Exactly 12 Newton steps (matching Rust).
"""
def equilibrium_speed_ms(
    config: VesselConfig,
    mass_kg: float,
    conditions: OceanConditions
) -> float {
    p_shaft = config.propulsion.max_power_kw * 1000.0 * config.propulsion.propulsive_efficiency;

    # Initial guess: calm-water cube-root relation
    draft = draft_at_mass(config.hull, mass_kg);
    wetted = wetted_area_m2(config.hull, draft);
    k = 0.5 * RHO_SEAWATER * config.propulsion.hull_drag_coeff * wetted;
    v = (p_shaft / max(k, 1.0)) ** (1.0 / 3.0);

    for _i in range(12) {
        r = total_resistance_n(config, mass_kg, v, conditions);
        thrust = p_shaft / v if v > 0.01 else p_shaft / 0.01;
        residual = thrust - r;
        # Derivative of (P/v - R(v)) ≈ -P/v² - dR/dv
        dr_dv = 2.0 * calm_water_resistance_n(config, mass_kg, v) / max(v, 0.01);
        jacobian = -p_shaft / max(v ** 2, 1e-4) - dr_dv;
        delta = residual / max(fabs(jacobian), 1.0);
        v = min(max(v - delta, 0.5), 30.0);
        if fabs(residual) < 10.0 {
            break;
        }
    }

    return max(v, 0.5);
}

"""Fuel consumption [kg] for a segment."""
def fuel_burned_kg(
    config: VesselConfig,
    mass_kg: float,
    distance_nm: float,
    conditions: OceanConditions
) -> float {
    speed_ms = equilibrium_speed_ms(config, mass_kg, conditions);
    speed_kts = speed_ms * 1.944;
    if speed_kts <= 0.0 {
        return float("inf");
    }
    duration_h = distance_nm / speed_kts;
    # Power fraction = R × v / (P_shaft)
    r = total_resistance_n(config, mass_kg, speed_ms, conditions);
    p_shaft = config.propulsion.max_power_kw * 1000.0 * config.propulsion.propulsive_efficiency;
    power_fraction = min(max(r * speed_ms / p_shaft, 0.0), 1.0);
    return fuel_rate_kg_h(config.propulsion, power_fraction) * duration_h;
}
