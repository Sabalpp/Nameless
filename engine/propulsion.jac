"""Propulsion helpers — port of src/vessel/propulsion.rs."""

import from engine.types { PropulsionSpec }

"Twin 90 kW marine diesels default (Rust Default for PropulsionSpec)."
def default_propulsion_spec() -> PropulsionSpec {
    return PropulsionSpec(
        max_power_kw=180.0,
        fuel_capacity_kg=5000.0,
        sfc_g_per_kwh=220.0,
        propulsive_efficiency=0.65,
        hull_drag_coeff=0.015
    );
}

"Fuel burn rate [kg/h] at a given shaft power fraction (0..1)."
def fuel_rate_kg_h(prop: PropulsionSpec, power_fraction: float) -> float {
    frac = max(0.0, min(1.0, power_fraction));
    brake_kw = prop.max_power_kw * frac;
    return prop.sfc_g_per_kwh * brake_kw / 1000.0;
}

"Effective thrust [N] at maximum power."
def max_thrust_n(prop: PropulsionSpec, speed_ms: float) -> float {
    if speed_ms <= 0.0 {
        return prop.max_power_kw * 1000.0 * prop.propulsive_efficiency / 0.1;
    }
    return prop.max_power_kw * 1000.0 * prop.propulsive_efficiency / speed_ms;
}
