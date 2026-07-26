"""Core voyage simulation loop — port of src/sim/voyage.rs.

Constants must match Rust exactly (also exposed as globals in types.jac):
  SIM_STEP_H=1.0, SIM_TIME_MULTIPLIER=100.0, DAMAGE_RATE_MULTIPLIER=3.4,
  CRACK_GROWTH_MULTIPLIER=0.12, CORROSION_RATE_MULTIPLIER=5.0
"""

import from math { fabs, pow, radians, sin, sqrt }

import from engine.types {
    FailureDiagnosis,
    FailureMode,
    FailureModeKind,
    HullZone,
    SegmentSnapshot,
    SimOutcome,
    VesselConfig,
    VesselState,
    VoyageRoute,
    ZoneState,
    ZoneSummary,
    all_hull_zones,
    hull_zone_is_submerged,
    SIM_STEP_H,
    SIM_TIME_MULTIPLIER,
    DAMAGE_RATE_MULTIPLIER,
    CRACK_GROWTH_MULTIPLIER,
    CORROSION_RATE_MULTIPLIER,
    NET_THICKNESS_FLOOR
}
import from engine.cost { total_config_cost_usd }
import from engine.config { total_mass_kg }
import from engine.state {
    new_zone_state,
    net_thickness_m,
    is_fatigued,
    initial_vessel_state,
    vessel_zone
}
import from engine.materials {
    material_spec,
    initial_crack_m,
    hourly_survival_prob
}
import from engine.route { total_distance_nm }
import from engine.physics.corrosion {
    thickness_loss_m,
    corrosion_fatigue_multiplier
}
import from engine.physics.ice {
    spray_icing_rate_kg_per_h,
    gm_with_ice
}
import from engine.physics.resistance {
    equilibrium_speed_ms,
    fuel_burned_kg
}
import from engine.physics.stability {
    capsize_risk,
    estimate_kg,
    gm_minimum,
    metacentric_height_m
}
import from engine.physics.structural {
    is_critical_crack,
    paris_crack_growth_per_cycle,
    segment_fatigue_damage,
    significant_stress_mpa,
    stress_intensity_factor
}
import from engine.ocean { zero_crossing_period_s }

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def:priv _clamp(value: float, lo: float, hi: float) -> float {
    if value < lo { return lo; }
    if value > hi { return hi; }
    return value;
}

"Human-readable failure label — matches FailureMode::label() in outcome.rs."
def:priv failure_mode_label(mode: FailureMode) -> str {
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

def:priv peak_stress_for(peak_stress: dict[HullZone, float], zone: HullZone) -> float {
    if zone in peak_stress {
        return peak_stress[zone];
    }
    return 0.0;
}

def build_zone_summaries(
    state: VesselState,
    peak_stress: dict[HullZone, float],
    _config: VesselConfig
) -> list[ZoneSummary] {
    summaries: list[ZoneSummary] = [];
    for zs in state.zones {
        summaries.append(ZoneSummary(
            zone=zs.zone,
            fatigue_consumed=zs.fatigue_consumed,
            corrosion_depth_mm=zs.corrosion_depth_m * 1000.0,
            crack_half_length_mm=zs.crack_half_length_m * 1000.0,
            peak_stress_mpa=peak_stress_for(peak_stress, zs.zone)
        ));
    }
    return summaries;
}

def snapshot_at(
    state: VesselState,
    seg_idx: int,
    seg_label: str,
    speed_kts: float,
    peak_stress: dict[HullZone, float],
    config: VesselConfig,
    failure: str | None
) -> SegmentSnapshot {
    return SegmentSnapshot(
        segment_index=seg_idx,
        segment_label=seg_label,
        distance_completed_nm=state.distance_nm,
        elapsed_h=state.elapsed_h,
        speed_kts=speed_kts,
        fuel_remaining_kg=state.fuel_kg,
        gm_m=state.gm_m,
        zones=build_zone_summaries(state, peak_stress, config),
        failure=failure
    );
}

def build_failure(
    mode: FailureMode,
    state: VesselState,
    seg_idx: int,
    seg_label: str,
    total_distance_nm_val: float,
    total_cost: float,
    peak_stress: dict[HullZone, float],
    config: VesselConfig,
    ticks: list[SegmentSnapshot]
) -> SimOutcome {
    diagnosis = FailureDiagnosis(
        mode=mode,
        distance_completed_nm=state.distance_nm,
        total_distance_nm=total_distance_nm_val,
        segment_index=seg_idx,
        segment_label=seg_label,
        elapsed_h=state.elapsed_h
    );
    return SimOutcome(
        failure=diagnosis,
        distance_completed_nm=state.distance_nm,
        total_distance_nm=total_distance_nm_val,
        time_elapsed_h=state.elapsed_h,
        fuel_remaining_kg=state.fuel_kg,
        final_gm_m=state.gm_m,
        zone_summaries=build_zone_summaries(state, peak_stress, config),
        total_config_cost_usd=total_cost,
        ticks=ticks
    );
}

# ---------------------------------------------------------------------------
# Main simulation
# ---------------------------------------------------------------------------

"Run the full voyage simulation for a vessel configuration over a route."
def run_voyage(config: VesselConfig, route: VoyageRoute) -> SimOutcome {
    total_distance = total_distance_nm(route);
    total_cost = total_config_cost_usd(config);

    zone_states: list[ZoneState] = [];
    for z in config.zones {
        zone_states.append(
            new_zone_state(z.zone, initial_crack_m(z.weld_quality) * 0.25)
        );
    }

    initial_mass = total_mass_kg(config);
    initial_kg = estimate_kg(config, config.propulsion.fuel_capacity_kg);
    initial_gm = metacentric_height_m(config.hull, initial_mass, initial_kg);

    state = initial_vessel_state(
        config.propulsion.fuel_capacity_kg,
        zone_states,
        initial_gm
    );

    peak_stress: dict[HullZone, float] = {};
    for z in all_hull_zones() {
        peak_stress[z] = 0.0;
    }

    ticks: list[SegmentSnapshot] = [];
    if len(route.segments) > 0 {
        first_segment = route.segments[0];
        ticks.append(snapshot_at(
            state, 0, first_segment.label, 0.0, peak_stress, config, None
        ));
    }

    seg_idx = 0;
    for segment in route.segments {
        conditions = segment.conditions;

        # --------------------------------------------------------------------
        # Stability check at segment start (conditions constant per segment)
        # --------------------------------------------------------------------
        current_mass = max(
            total_mass_kg(config)
            - (config.propulsion.fuel_capacity_kg - state.fuel_kg),
            500.0
        );
        kg = estimate_kg(config, state.fuel_kg);
        state.gm_m = metacentric_height_m(config.hull, current_mass, kg);
        gm_min = gm_minimum(config.hull);

        if capsize_risk(
            state.gm_m,
            config.hull,
            conditions.hs_m,
            conditions.encounter_angle_deg
        ) {
            beam_component = fabs(sin(radians(conditions.encounter_angle_deg)));
            gm_effective_min = max(
                gm_min + 0.015 * (conditions.hs_m ** 2) * beam_component,
                gm_min
            );
            mode = FailureMode(
                kind=FailureModeKind.CAPSIZE,
                gm_m=state.gm_m,
                gm_required_m=gm_effective_min
            );
            ticks.append(snapshot_at(
                state, seg_idx, segment.label, state.speed_kts,
                peak_stress, config, failure_mode_label(mode)
            ));
            return build_failure(
                mode, state, seg_idx, segment.label,
                total_distance, total_cost, peak_stress, config, ticks
            );
        }

        # Speed is constant within a segment (conditions don't change)
        speed_ms = equilibrium_speed_ms(config, current_mass, conditions);
        speed_kts = speed_ms * 1.944;
        state.speed_kts = speed_kts;
        seg_duration_h = (
            segment.distance_nm / max(speed_kts, 0.1)
        ) * max(segment.duration_scale, 0.05);

        # --------------------------------------------------------------------
        # Inner time loop — hourly steps through the segment
        # --------------------------------------------------------------------
        seg_elapsed_h = 0.0;

        while seg_elapsed_h < seg_duration_h {
            step_h = min(seg_duration_h - seg_elapsed_h, SIM_STEP_H);
            exposure_step_h = step_h * SIM_TIME_MULTIPLIER;
            exposure_step_s = exposure_step_h * 3600.0;
            step_distance_nm = segment.distance_nm * (step_h / seg_duration_h);

            step_mass = max(
                total_mass_kg(config)
                - (config.propulsion.fuel_capacity_kg - state.fuel_kg),
                500.0
            );

            # Fuel consumption for this step
            fuel_burned = fuel_burned_kg(
                config, step_mass, step_distance_nm, conditions
            );
            if fuel_burned >= state.fuel_kg {
                distance_on_remaining = (
                    state.fuel_kg / max(fuel_burned, 1.0) * step_distance_nm
                );
                if step_distance_nm > 0.0 {
                    step_fraction = _clamp(
                        distance_on_remaining / step_distance_nm, 0.0, 1.0
                    );
                } else {
                    step_fraction = 0.0;
                }
                state.distance_nm = min(
                    state.distance_nm + distance_on_remaining, total_distance
                );
                state.elapsed_h += exposure_step_h * step_fraction;
                mode = FailureMode(
                    kind=FailureModeKind.FUEL_EXHAUSTION,
                    distance_remaining_nm=total_distance - state.distance_nm
                );
                ticks.append(snapshot_at(
                    state, seg_idx, segment.label, speed_kts,
                    peak_stress, config, failure_mode_label(mode)
                ));
                return build_failure(
                    mode, state, seg_idx, segment.label,
                    total_distance, total_cost, peak_stress, config, ticks
                );
            }
            state.fuel_kg -= fuel_burned;
            state.distance_nm = min(
                state.distance_nm + step_distance_nm, total_distance
            );
            state.elapsed_h += exposure_step_h;
            seg_elapsed_h += step_h;

            # ----------------------------------------------------------------
            # Spray-ice accretion (sub-4°C water → topside ice raises KG)
            # ----------------------------------------------------------------
            ice_rate = spray_icing_rate_kg_per_h(config.hull, conditions);
            if ice_rate > 0.0 {
                state.ice_mass_kg += ice_rate * exposure_step_h;
                kg = estimate_kg(config, state.fuel_kg);
                base_gm = metacentric_height_m(config.hull, step_mass, kg);
                state.gm_m = gm_with_ice(
                    base_gm, config.hull, step_mass, kg, state.ice_mass_kg
                );
                if capsize_risk(
                    state.gm_m,
                    config.hull,
                    conditions.hs_m,
                    conditions.encounter_angle_deg
                ) {
                    gm_min = gm_minimum(config.hull);
                    beam_component = fabs(
                        sin(radians(conditions.encounter_angle_deg))
                    );
                    gm_effective_min = max(
                        gm_min + 0.015 * (conditions.hs_m ** 2) * beam_component,
                        gm_min
                    );
                    mode = FailureMode(
                        kind=FailureModeKind.CAPSIZE,
                        gm_m=state.gm_m,
                        gm_required_m=gm_effective_min
                    );
                    ticks.append(snapshot_at(
                        state, seg_idx, segment.label, speed_kts,
                        peak_stress, config, failure_mode_label(mode)
                    ));
                    return build_failure(
                        mode, state, seg_idx, segment.label,
                        total_distance, total_cost, peak_stress, config, ticks
                    );
                }
            }

            # Per-zone structural assessment for this step
            elapsed_h_snapshot = state.elapsed_h;
            for zone_spec in config.zones {
                zone = zone_spec.zone;
                material = zone_spec.material;
                mat_spec = material_spec(material);
                zone_state = vessel_zone(state, zone);

                if conditions.water_temp_c < mat_spec.min_temp_c {
                    mode = FailureMode(
                        kind=FailureModeKind.COLD_TEMPERATURE_BRITTLENESS,
                        zone=zone,
                        water_temp_c=conditions.water_temp_c,
                        min_rated_temp_c=mat_spec.min_temp_c
                    );
                    ticks.append(snapshot_at(
                        state, seg_idx, segment.label, speed_kts,
                        peak_stress, config, failure_mode_label(mode)
                    ));
                    return build_failure(
                        mode, state, seg_idx, segment.label,
                        total_distance, total_cost, peak_stress, config, ticks
                    );
                }

                submerged = hull_zone_is_submerged(zone);
                new_loss = (
                    thickness_loss_m(
                        material, conditions, submerged, exposure_step_h
                    ) * CORROSION_RATE_MULTIPLIER
                );
                zone_state.corrosion_depth_m += new_loss;

                net_t = net_thickness_m(zone_state, zone_spec.thickness_m);
                thickness_ratio = _clamp(
                    zone_spec.thickness_m / max(net_t, 0.0005), 1.0, 8.0
                );
                fatigue_softening = (
                    1.0 + _clamp(zone_state.fatigue_consumed, 0.0, 0.64) * 1.8
                );
                crack_softening = (
                    1.0 + _clamp(
                        sqrt(
                            zone_state.crack_half_length_m
                            / max(zone_spec.thickness_m, 0.001)
                        ),
                        0.0,
                        1.5
                    )
                );
                weakening_multiplier = _clamp(
                    pow(thickness_ratio, 2.2) * fatigue_softening * crack_softening,
                    1.0,
                    18.0
                );

                if net_t < zone_spec.thickness_m * NET_THICKNESS_FLOOR {
                    zone_state.fatigue_consumed = 1.0;
                    mode = FailureMode(
                        kind=FailureModeKind.FATIGUE_FAILURE,
                        zone=zone,
                        damage_accumulated=zone_state.fatigue_consumed
                    );
                    ticks.append(snapshot_at(
                        state, seg_idx, segment.label, speed_kts,
                        peak_stress, config, failure_mode_label(mode)
                    ));
                    return build_failure(
                        mode, state, seg_idx, segment.label,
                        total_distance, total_cost, peak_stress, config, ticks
                    );
                }

                corr_multiplier = corrosion_fatigue_multiplier(
                    material, conditions, elapsed_h_snapshot
                );
                base_damage = segment_fatigue_damage(
                    config.hull,
                    conditions,
                    zone,
                    zone_spec,
                    mat_spec,
                    exposure_step_s
                );
                zone_state.fatigue_consumed += (
                    base_damage
                    * corr_multiplier
                    * weakening_multiplier
                    * DAMAGE_RATE_MULTIPLIER
                );

                sig_stress = (
                    significant_stress_mpa(
                        config.hull, conditions, zone, zone_spec
                    ) * weakening_multiplier
                );
                if sig_stress > peak_stress_for(peak_stress, zone) {
                    peak_stress[zone] = sig_stress;
                }

                if is_fatigued(zone_state) {
                    zone_state.fatigue_consumed = 1.0;
                    mode = FailureMode(
                        kind=FailureModeKind.FATIGUE_FAILURE,
                        zone=zone,
                        damage_accumulated=zone_state.fatigue_consumed
                    );
                    ticks.append(snapshot_at(
                        state, seg_idx, segment.label, speed_kts,
                        peak_stress, config, failure_mode_label(mode)
                    ));
                    return build_failure(
                        mode, state, seg_idx, segment.label,
                        total_distance, total_cost, peak_stress, config, ticks
                    );
                }

                delta_stress = sig_stress * 2.0;
                tz = zero_crossing_period_s(conditions);
                n_cycles = exposure_step_s / max(tz, 0.5);
                dk = stress_intensity_factor(
                    delta_stress, max(zone_state.crack_half_length_m, 1e-6)
                );
                da_per_cycle = paris_crack_growth_per_cycle(dk, mat_spec);
                zone_state.crack_half_length_m += (
                    da_per_cycle
                    * n_cycles
                    * CRACK_GROWTH_MULTIPLIER
                    * sqrt(weakening_multiplier)
                );

                k_applied = stress_intensity_factor(
                    sig_stress, zone_state.crack_half_length_m
                );
                if is_critical_crack(
                    zone_state.crack_half_length_m,
                    sig_stress,
                    mat_spec.k_ic_mpa_sqrtm
                ) {
                    mode = FailureMode(
                        kind=FailureModeKind.BRITTLE_FRACTURE,
                        zone=zone,
                        crack_half_length_m=zone_state.crack_half_length_m,
                        k_applied_mpa_sqrtm=k_applied,
                        k_ic_mpa_sqrtm=mat_spec.k_ic_mpa_sqrtm
                    );
                    ticks.append(snapshot_at(
                        state, seg_idx, segment.label, speed_kts,
                        peak_stress, config, failure_mode_label(mode)
                    ));
                    return build_failure(
                        mode, state, seg_idx, segment.label,
                        total_distance, total_cost, peak_stress, config, ticks
                    );
                }
            }

            ticks.append(snapshot_at(
                state, seg_idx, segment.label, speed_kts,
                peak_stress, config, None
            ));
        }

        # --------------------------------------------------------------------
        # Seal check per segment (cumulative exposure over full segment)
        # --------------------------------------------------------------------
        for zone_spec in config.zones {
            zone = zone_spec.zone;
            hourly_survival = hourly_survival_prob(zone_spec.seal_quality);
            seal_survival = pow(
                hourly_survival, seg_duration_h * SIM_TIME_MULTIPLIER
            );
            if seal_survival < 0.50 {
                mode = FailureMode(
                    kind=FailureModeKind.SEAL_BREACH_FLOODING,
                    zone=zone,
                    elapsed_h=state.elapsed_h
                );
                ticks.append(snapshot_at(
                    state, seg_idx, segment.label, speed_kts,
                    peak_stress, config, failure_mode_label(mode)
                ));
                return build_failure(
                    mode, state, seg_idx, segment.label,
                    total_distance, total_cost, peak_stress, config, ticks
                );
            }
        }

        seg_idx += 1;
    }

    zone_summaries = build_zone_summaries(state, peak_stress, config);
    return SimOutcome(
        failure=None,
        distance_completed_nm=state.distance_nm,
        total_distance_nm=total_distance,
        time_elapsed_h=state.elapsed_h,
        fuel_remaining_kg=state.fuel_kg,
        final_gm_m=state.gm_m,
        zone_summaries=zone_summaries,
        total_config_cost_usd=total_cost,
        ticks=ticks
    );
}
