"""Vessel / zone runtime state helpers — port of src/vessel/state.rs."""

import from engine.types { HullZone, VesselState, ZoneState }

"Construct a fresh ZoneState for a hull zone."
def new_zone_state(zone: HullZone, initial_crack_half_length_m: float) -> ZoneState {
    return ZoneState(
        zone=zone,
        fatigue_consumed=0.0,
        corrosion_depth_m=0.0,
        crack_half_length_m=initial_crack_half_length_m
    );
}

"Net structural thickness remaining [m]."
def net_thickness_m(zone_state: ZoneState, nominal: float) -> float {
    return max(nominal - zone_state.corrosion_depth_m, 0.001);
}

"True when Miner's cumulative damage has reached the failure threshold (0.75)."
def is_fatigued(zone_state: ZoneState) -> bool {
    return zone_state.fatigue_consumed >= 0.75;
}

"Initial vessel runtime state at departure."
def initial_vessel_state(
    fuel_capacity_kg: float,
    zones: list[ZoneState],
    gm_m: float
) -> VesselState {
    return VesselState(
        distance_nm=0.0,
        elapsed_h=0.0,
        fuel_kg=fuel_capacity_kg,
        gm_m=gm_m,
        speed_kts=0.0,
        zones=zones,
        ice_mass_kg=0.0
    );
}

"Retrieve the ZoneState for a specific hull zone."
def vessel_zone(state: VesselState, zone: HullZone) -> ZoneState {
    for z in state.zones {
        if z.zone == zone {
            return z;
        }
    }
    raise ValueError("zone must exist");
}
