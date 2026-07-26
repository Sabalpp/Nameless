"""Vessel configuration helpers — port of src/vessel/config.rs."""

import from engine.types {
    HullGeometry,
    HullZone,
    MaterialModel,
    PropulsionSpec,
    SealQuality,
    VesselConfig,
    WeldQuality,
    ZoneSpec,
    all_hull_zones
}
import from engine.hull { wetted_area_m2 }
import from engine.materials { material_spec }

"Build a config with identical material + quality across all zones."
def uniform(
    hull: HullGeometry,
    material: MaterialModel,
    thickness_m: float,
    weld: WeldQuality,
    seal: SealQuality,
    propulsion: PropulsionSpec
) -> VesselConfig {
    zones: list[ZoneSpec] = [];
    for zone in all_hull_zones() {
        zones.append(ZoneSpec(
            zone=zone,
            material=material,
            thickness_m=thickness_m,
            weld_quality=weld,
            seal_quality=seal
        ));
    }
    return VesselConfig(hull=hull, zones=zones, propulsion=propulsion);
}

"Retrieve the spec for a specific zone."
def config_zone(config: VesselConfig, zone: HullZone) -> ZoneSpec {
    for z in config.zones {
        if z.zone == zone {
            return z;
        }
    }
    raise ValueError("all zones must be present in VesselConfig");
}

"""Shell mass of the entire hull [kg], summed across zones.
Each zone is approximated as a fraction of total wetted area.
"""
def shell_mass_kg(config: VesselConfig) -> float {
    draft = config.hull.draft_m;
    total_area = wetted_area_m2(config.hull, draft);
    zone_area_fraction = total_area / float(len(all_hull_zones()));
    total = 0.0;
    for z in config.zones {
        spec = material_spec(z.material);
        total += zone_area_fraction * z.thickness_m * spec.density_kg_m3;
    }
    return total;
}

"Total vessel operating mass including fuel [kg]."
def total_mass_kg(config: VesselConfig) -> float {
    systems_kg = 280.0 + config.hull.loa_m * config.hull.beam_m * 22.0;
    return shell_mass_kg(config) + systems_kg + config.propulsion.fuel_capacity_kg;
}
