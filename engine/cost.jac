"""Material and fabrication cost — port of src/cost/mod.rs."""

import from math { ceil }

import from engine.types {
    CostBreakdown,
    VesselConfig,
    all_hull_zones
}
import from engine.hull { wetted_area_m2 }
import from engine.materials {
    material_spec,
    weld_cost_factor,
    seal_cost_factor
}

glob BASE_WELD_COST_PER_M_USD: float = 45.0;
glob BASE_SEAL_COST_PER_M_USD: float = 18.0;
glob FUEL_CAPACITY_COST_PER_KG_USD: float = 1.15;
glob COST_SCALE_MULTIPLIER: float = 1000.0;

def:priv scaled_cost(value: float) -> float {
    return value * COST_SCALE_MULTIPLIER;
}

def:priv raw_material_cost_usd(config: VesselConfig) -> float {
    draft = config.hull.draft_m;
    total_area = wetted_area_m2(config.hull, draft);
    zone_area = total_area / float(len(all_hull_zones()));
    total = 0.0;
    for z in config.zones {
        spec = material_spec(z.material);
        mass_kg = zone_area * z.thickness_m * spec.density_kg_m3;
        total += mass_kg * spec.cost_per_kg_usd;
    }
    return total;
}

def:priv raw_weld_cost_usd(config: VesselConfig) -> float {
    h = config.hull;
    # Total weld length: hull perimeter repeated every frame spacing (~0.4m)
    perimeter = 2.0 * h.loa_m + 2.0 * h.beam_m + 4.0 * h.depth_m;
    frame_count = float(ceil(h.loa_m / 0.4));
    total_weld_m = perimeter + frame_count * (h.beam_m + h.depth_m * 2.0);

    if len(config.zones) == 0 {
        weld_factor = 1.0;
    } else {
        weld_sum = 0.0;
        for z in config.zones {
            weld_sum += weld_cost_factor(z.weld_quality);
        }
        weld_factor = weld_sum / float(len(config.zones));
    }

    return total_weld_m * BASE_WELD_COST_PER_M_USD * weld_factor;
}

def:priv raw_seal_cost_usd(config: VesselConfig) -> float {
    h = config.hull;
    seal_perimeter = 2.0 * h.loa_m + 2.0 * h.beam_m;

    if len(config.zones) == 0 {
        seal_factor = 1.0;
    } else {
        seal_sum = 0.0;
        for z in config.zones {
            seal_sum += seal_cost_factor(z.seal_quality);
        }
        seal_factor = seal_sum / float(len(config.zones));
    }

    return seal_perimeter * BASE_SEAL_COST_PER_M_USD * seal_factor;
}

def:priv raw_fuel_capacity_cost_usd(config: VesselConfig) -> float {
    return config.propulsion.fuel_capacity_kg * FUEL_CAPACITY_COST_PER_KG_USD;
}

"Material cost [USD]: mass × cost_per_kg, summed across zones, scaled."
def material_cost_usd(config: VesselConfig) -> float {
    return scaled_cost(raw_material_cost_usd(config));
}

"Fabrication cost [USD] for structural welds."
def weld_cost_usd(config: VesselConfig) -> float {
    return scaled_cost(raw_weld_cost_usd(config));
}

"Sealing cost [USD] for all watertight penetrations and deck seals."
def seal_cost_usd(config: VesselConfig) -> float {
    return scaled_cost(raw_seal_cost_usd(config));
}

"Fuel storage + carried fuel allowance cost [USD]."
def fuel_capacity_cost_usd(config: VesselConfig) -> float {
    return scaled_cost(raw_fuel_capacity_cost_usd(config));
}

"Total material + fabrication cost [USD] for a vessel configuration."
def total_config_cost_usd(config: VesselConfig) -> float {
    return (
        material_cost_usd(config)
        + weld_cost_usd(config)
        + seal_cost_usd(config)
        + fuel_capacity_cost_usd(config)
    );
}

"Break down cost into material, weld, seal, and fuel-capacity components."
def cost_breakdown_for_config(config: VesselConfig) -> CostBreakdown {
    return CostBreakdown(
        material_usd=material_cost_usd(config),
        weld_usd=weld_cost_usd(config),
        seal_usd=seal_cost_usd(config),
        fuel_capacity_usd=fuel_capacity_cost_usd(config)
    );
}
