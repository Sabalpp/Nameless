"""Seawater corrosion — ported from src/physics/corrosion.rs."""

import from math { sqrt }

import from engine.types { MaterialModel, OceanConditions }
import from engine.materials { material_spec, material_corrodes }

"""Seawater corrosion rate [mm/year] for a given material and ocean chemistry.

The causal chain is: salinity + temperature + pH → electrochemical attack rate.
Higher salinity increases ion concentration (up to ~35 ppt peak), warmer water
accelerates reaction kinetics (Arrhenius), and lower pH dissolves passive oxide films.
"""
def corrosion_rate_mm_yr(
    material: MaterialModel,
    conditions: OceanConditions,
    submerged: bool
) -> float {
    base = material_spec(material).base_corrosion_rate_mm_yr;
    if base <= 0.0 {
        return 0.0;  # CFRP and fully inert materials
    }

    # Salinity factor: peak near typical open-ocean (~35 ppt); drops in fresher water
    salinity_factor = min(max(conditions.salinity_ppt / 35.0, 0.3), 1.4);

    # Temperature factor: Arrhenius-type doubling per ~10°C above 10°C baseline
    temp_delta = conditions.water_temp_c - 10.0;
    temp_factor = min(max(2.0 ** (temp_delta / 10.0), 0.4), 3.5);

    # pH factor: passive oxide film dissolves below ocean-normal pH of 8.1
    ph_factor = min(max(1.0 + 0.18 * max(8.1 - conditions.ph, 0.0), 1.0), 2.2);

    # Permanently submerged zones are ~1.4× faster than waterline / splash zones
    immersion_factor = 1.40 if submerged else 1.00;

    return base * salinity_factor * temp_factor * ph_factor * immersion_factor;
}

"""Thickness lost to corrosion over a time period [m]."""
def thickness_loss_m(
    material: MaterialModel,
    conditions: OceanConditions,
    submerged: bool,
    duration_h: float
) -> float {
    rate_mm_yr = corrosion_rate_mm_yr(material, conditions, submerged);
    # Convert [mm/yr] × [hours] → [m]
    return rate_mm_yr * duration_h / (8760.0 * 1000.0);
}

"""Fatigue damage multiplier due to corrosion-induced surface pitting.

Corrosion pits act as local stress raisers, accelerating fatigue crack initiation.
Returns a multiplier > 1.0 that scales Miner's damage when corrosion is present.
"""
def corrosion_fatigue_multiplier(
    material: MaterialModel,
    conditions: OceanConditions,
    elapsed_h: float
) -> float {
    if not material_corrodes(material) {
        return 1.0;
    }
    rate = corrosion_rate_mm_yr(material, conditions, True);
    # Pit depth grows proportionally to √time (diffusion-limited)
    pit_depth_mm = rate * sqrt(elapsed_h / 8760.0);
    # Pit stress concentration scales with pit depth; typical pit SCF ~ 1 + 2√(d/r) ≈ 1 + 8√d
    pit_scf = 1.0 + 8.0 * sqrt(pit_depth_mm);
    return min(max(pit_scf, 1.0), 4.0);
}
