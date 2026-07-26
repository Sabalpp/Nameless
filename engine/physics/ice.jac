"""Spray icing and ice-load stability — ported from src/physics/ice.rs."""

import from engine.types { OceanConditions, HullGeometry }

"""Spray-icing accumulation rate on vessel topsides [kg/h].

Spray icing occurs when wind-driven sea spray contacts superstructure surfaces
that are cooled below 0°C. Water temperature serves as proxy for air temperature
(sub-4°C water correlates with icing-capable air mass). Calibrated loosely
to Stallabrass (1980) and IMO spray-icing nomograms for small displacement vessels.
"""
def spray_icing_rate_kg_per_h(hull: HullGeometry, conditions: OceanConditions) -> float {
    if conditions.water_temp_c >= 4.0 {
        return 0.0;
    }

    # Cold intensity: peaks at 0°C water (proxy for ~−10°C air), tapers to zero at 4°C
    cold_factor = max(4.0 - conditions.water_temp_c, 0.0) / 4.0;

    # Wind-driven spray kinetic energy scales with V²; normalised to 12 m/s reference
    wind_factor = min((conditions.wind_speed_ms / 12.0) ** 2, 4.0);

    # Wave height drives spray volume above deck; normalised to Hs = 2 m reference
    wave_factor = min(max(conditions.hs_m / 2.0, 0.0), 3.0);

    # Exposed topside area: beam × LOA × 30% (upper hull + minimal superstructure for ASV)
    topside_area_m2 = hull.beam_m * hull.loa_m * 0.30;

    # Base rate ≈ 0.70 kg/(m²·h) at reference conditions: 12 m/s wind, 0°C water, Hs 2 m
    base_rate_kg_m2_h: float = 0.70;

    return base_rate_kg_m2_h * cold_factor * wind_factor * wave_factor * topside_area_m2;
}

"""Height above keel of the accumulated-ice center of gravity [m].
Ice builds up on the superstructure and upper hull topsides, well above vessel KG.
"""
def ice_kg_height_m(hull: HullGeometry) -> float {
    return hull.depth_m * 1.05;
}

"""Metacentric height with topside ice load applied [m].

Ice raises the combined center of gravity (KG_combined > KG_vessel), compressing
the GM = KB + BM − KG margin. A small ice load on a high CG is disproportionately
dangerous compared to the same mass added low in the hull.
"""
def gm_with_ice(
    base_gm_m: float,
    hull: HullGeometry,
    vessel_mass_kg: float,
    vessel_kg_m: float,
    ice_mass_kg: float
) -> float {
    if ice_mass_kg <= 0.0 {
        return base_gm_m;
    }
    kg_ice = ice_kg_height_m(hull);
    total_mass = vessel_mass_kg + ice_mass_kg;
    kg_combined = (vessel_mass_kg * vessel_kg_m + ice_mass_kg * kg_ice) / total_mass;
    # Raising KG by Δ = (kg_combined − kg_vessel) reduces GM by the same amount
    return base_gm_m - (kg_combined - vessel_kg_m);
}
