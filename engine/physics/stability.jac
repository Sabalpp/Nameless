"""Static and dynamic stability — ported from src/physics/stability.rs."""

import from math { sin, radians, fabs }

import from engine.types { HullGeometry, VesselConfig }
import from engine.hull { draft_at_mass, i_waterplane_m4 }

"""Metacentric height GM [m] for a given displacement and hull form.

GM = KB + BM - KG

KB  — centre of buoyancy above keel  (Morrish's formula)
BM  — metacentric radius             (I_waterplane / V_displaced)
KG  — centre of gravity above keel   (estimated from weight distribution)
"""
def metacentric_height_m(hull: HullGeometry, mass_kg: float, kg_m: float) -> float {
    draft = max(draft_at_mass(hull, mass_kg), 0.05);
    v = mass_kg / 1025.0;  # displaced volume [m³]

    # Morrish's formula simplified for typical ASV hull forms:
    kb = draft * (0.53 + 0.08 * hull.block_coeff);

    # BM = second moment of waterplane area / displaced volume
    i_wp = i_waterplane_m4(hull);
    bm = i_wp / max(v, 0.01);

    return kb + bm - kg_m;
}

"""Estimate KG [m] from vessel configuration and current fuel load.
Higher fuel consumption raises KG as ballast fuel is consumed from lower tanks.
"""
def estimate_kg(config: VesselConfig, fuel_remaining_kg: float) -> float {
    hull = config.hull;

    # Light ship KG ≈ 55% of hull depth for typical ASV with low centre of mass
    kg_lightship = hull.depth_m * 0.55;

    # Fuel is stored low; as fuel burns, CG rises slightly
    fuel_fraction = fuel_remaining_kg / max(config.propulsion.fuel_capacity_kg, 1.0);
    # Full fuel: KG pulled 0.06 × D downward; empty tanks: no effect
    fuel_offset = -hull.depth_m * 0.06 * fuel_fraction;

    return min(max(kg_lightship + fuel_offset, hull.depth_m * 0.30), hull.depth_m * 0.80);
}

"""Minimum acceptable GM [m] for safe operation in open ocean.
DNV rule of thumb: GM_min ≥ 0.07 × B for small vessels.
"""
def gm_minimum(hull: HullGeometry) -> float {
    return 0.07 * hull.beam_m;
}

"""True if the vessel is at risk of capsize given current GM and sea state Hs.
Combines static stability margin with dynamic excitation from beam seas.
"""
def capsize_risk(gm_m: float, hull: HullGeometry, hs_m: float, encounter_angle_deg: float) -> bool {
    gm_min = gm_minimum(hull);

    # Static: insufficient righting moment
    if gm_m < gm_min {
        return True;
    }

    # Dynamic: beam-sea resonance can capsize vessels with GM < 0.5×B even if positive
    beam_sea_component: float = fabs(sin(radians(encounter_angle_deg)));
    dynamic_threshold = gm_min + 0.015 * hs_m * hs_m * beam_sea_component;

    return gm_m < dynamic_threshold;
}
