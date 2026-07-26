"""Graph-native voyage simulation.

A VoyageWalker is one physical vessel attempt. It reads each typed
RouteSegment edge, carries accumulated vessel state forward, and either reaches
the destination or persists a FailureTrace at the waypoint where it stops.
"""

import from engine.domain {
    WaypointNode, RouteSegment, FailedHere, CompletedHere,
    FailureTrace, SuccessTrace, VoyageResult
}
import from engine.physics {
    ALL_ZONES, STEP_H, SIM_TIME_MULT, DAMAGE_MULT, CRACK_MULT, CORR_MULT,
    get_material_spec,
    weld_scf, weld_initial_crack_m, seal_hourly_survival,
    zone_is_submerged, zero_crossing_period_s,
    thickness_loss_m, corrosion_fatigue_multiplier,
    significant_stress_mpa, segment_fatigue_damage,
    stress_intensity_factor, paris_crack_growth, is_critical_crack,
    estimate_kg, metacentric_height_m, capsize_risk,
    equilibrium_speed_ms, fuel_burned_kg,
    spray_icing_rate_kg_per_h, gm_with_ice,
    config_cost_usd
}

walker VoyageWalker {
    # Immutable design snapshot for this attempt.
    has loa_m: float = 7.3,
        beam_m: float = 2.4,
        depth_m: float = 1.1,
        draft_m: float = 0.32,
        block_coeff: float = 0.58,
        waterplane_coeff: float = 0.78,
        material: str = "MildSteelA",
        thickness_m: float = 0.004,
        weld: str = "Economy",
        seal: str = "Economy",
        max_power_kw: float = 300.0,
        fuel_capacity_kg: float = 2000.0,
        sfc_g_per_kwh: float = 220.0,
        propulsive_efficiency: float = 0.72,
        hull_drag_coeff: float = 0.007,
        route_id: int = 0,
        attempt: int = 0,
        total_distance_nm: float = 0.0;

    # Mutable state carried by the walker.
    has initialized: bool = False,
        fuel_kg: float = 2000.0,
        elapsed_h: float = 0.0,
        distance_nm: float = 0.0,
        ice_mass_kg: float = 0.0,
        gm_m: float = 1.0,
        speed_kts: float = 0.0,
        corrosion_m: list[float] = [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
        fatigue: list[float] = [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
        crack_m: list[float] = [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
        failure_mode: str = "",
        failure_zone: str = "",
        failure_reason: str = "",
        configuration_cost_usd: float = 0.0,
        result: VoyageResult | None = None;

    def _initialize {
        initial_crack = weld_initial_crack_m(self.weld) * 0.25;
        self.crack_m = [initial_crack for _ in ALL_ZONES];
        self.corrosion_m = [0.0 for _ in ALL_ZONES];
        self.fatigue = [0.0 for _ in ALL_ZONES];
        self.fuel_kg = self.fuel_capacity_kg;

        mat = get_material_spec(self.material);
        shell_area = 2.0 * (
            self.loa_m * self.depth_m
            + self.loa_m * self.beam_m
            + self.beam_m * self.depth_m
        );
        shell_mass = shell_area * self.thickness_m * mat.density_kg_m3;
        self.configuration_cost_usd = config_cost_usd(
            self.loa_m, self.beam_m, self.depth_m,
            mat.density_kg_m3, self.thickness_m,
            mat.cost_per_kg_usd, self.weld, self.seal,
            self.fuel_capacity_kg
        );
        kg_m = estimate_kg(self.depth_m, self.fuel_kg, self.fuel_capacity_kg);
        self.gm_m = metacentric_height_m(
            self.loa_m, self.beam_m, self.depth_m,
            self.block_coeff, self.waterplane_coeff,
            shell_mass + self.fuel_capacity_kg, kg_m
        );
        self.initialized = True;
    }

    def _record_failure(at: WaypointNode) {
        _trace = at +>:FailedHere():+> FailureTrace(
            route_id=self.route_id,
            attempt=self.attempt,
            failure_mode=self.failure_mode,
            failure_zone=self.failure_zone,
            failure_reason=self.failure_reason,
            distance_completed_nm=self.distance_nm,
            total_distance_nm=self.total_distance_nm,
            elapsed_h=self.elapsed_h,
            fuel_remaining_kg=self.fuel_kg,
            gm_m=self.gm_m,
            ice_mass_kg=self.ice_mass_kg,
            material=self.material,
            thickness_m=self.thickness_m,
            weld=self.weld,
            seal=self.seal,
            corrosion_m=self.corrosion_m.copy(),
            fatigue=self.fatigue.copy(),
            crack_m=self.crack_m.copy()
        );
        self.result = VoyageResult(
            survived=False,
            route_id=self.route_id,
            attempt=self.attempt,
            cost_usd=self.configuration_cost_usd,
            distance_nm=self.distance_nm,
            total_distance_nm=self.total_distance_nm,
            elapsed_h=self.elapsed_h,
            fuel_remaining_kg=self.fuel_kg,
            gm_m=self.gm_m,
            material=self.material,
            thickness_mm=self.thickness_m * 1000.0,
            weld=self.weld,
            seal=self.seal,
            failure_mode=self.failure_mode,
            failure_zone=self.failure_zone,
            failure_reason=self.failure_reason,
            terminal_waypoint=at.name
        );
    }

    def _record_success(at: WaypointNode) {
        cost = self.configuration_cost_usd;
        _trace = at +>:CompletedHere():+> SuccessTrace(
            route_id=self.route_id,
            attempt=self.attempt,
            cost_usd=cost,
            distance_completed_nm=self.distance_nm,
            elapsed_h=self.elapsed_h,
            fuel_remaining_kg=self.fuel_kg,
            gm_m=self.gm_m,
            material=self.material,
            thickness_m=self.thickness_m,
            weld=self.weld,
            seal=self.seal
        );
        self.result = VoyageResult(
            survived=True,
            route_id=self.route_id,
            attempt=self.attempt,
            cost_usd=cost,
            distance_nm=self.distance_nm,
            total_distance_nm=self.total_distance_nm,
            elapsed_h=self.elapsed_h,
            fuel_remaining_kg=self.fuel_kg,
            gm_m=self.gm_m,
            material=self.material,
            thickness_mm=self.thickness_m * 1000.0,
            weld=self.weld,
            seal=self.seal,
            terminal_waypoint=at.name
        );
    }

    can cross_segment with WaypointNode entry {
        if not self.initialized {
            self._initialize();
        }

        if here.is_destination {
            self._record_success(here);
            disengage;
        }

        segment_edges = [edge here ->:RouteSegment:->];
        next_waypoints = [here ->:RouteSegment:->];
        if not segment_edges or not next_waypoints {
            self.failure_mode = "route_gap";
            self.failure_zone = "Route";
            self.failure_reason = f"No outgoing route segment from {here.name}";
            self._record_failure(here);
            disengage;
        }

        segment = segment_edges[0];
        target = next_waypoints[0];
        mat = get_material_spec(self.material);
        scf = weld_scf(self.weld);

        shell_area = 2.0 * (
            self.loa_m * self.depth_m
            + self.loa_m * self.beam_m
            + self.beam_m * self.depth_m
        );
        shell_mass = shell_area * self.thickness_m * mat.density_kg_m3;
        current_mass = max(500.0, shell_mass + self.fuel_kg);
        kg_m = estimate_kg(self.depth_m, self.fuel_kg, self.fuel_capacity_kg);
        self.gm_m = metacentric_height_m(
            self.loa_m, self.beam_m, self.depth_m,
            self.block_coeff, self.waterplane_coeff,
            current_mass, kg_m
        );

        if capsize_risk(
            self.gm_m, self.beam_m, segment.hs_m,
            segment.encounter_angle_deg
        ) {
            self.failure_mode = "capsize";
            self.failure_zone = "Vessel";
            self.failure_reason = (
                f"GM {self.gm_m:.2f}m is insufficient for "
                f"Hs={segment.hs_m:.1f}m on segment {segment.sequence}"
            );
            self._record_failure(target);
            disengage;
        }

        speed_ms = equilibrium_speed_ms(
            self.loa_m, self.beam_m, self.depth_m, self.draft_m,
            self.block_coeff, self.hull_drag_coeff, self.max_power_kw,
            self.propulsive_efficiency, current_mass,
            segment.hs_m, segment.tp_s, segment.encounter_angle_deg,
            segment.wind_speed_ms
        );
        self.speed_kts = speed_ms * 1.944;
        seg_duration_h = (
            segment.distance_nm / max(0.1, self.speed_kts)
        ) * max(0.05, segment.duration_scale);
        seg_elapsed_h = 0.0;
        failed = False;

        while seg_elapsed_h < seg_duration_h {
            step_h = min(STEP_H, seg_duration_h - seg_elapsed_h);
            exposure_h = step_h * SIM_TIME_MULT;
            exposure_s = exposure_h * 3600.0;
            step_distance_nm = segment.distance_nm * (
                step_h / max(0.001, seg_duration_h)
            );
            step_mass = max(500.0, shell_mass + self.fuel_kg);

            fuel_step = fuel_burned_kg(
                self.loa_m, self.beam_m, self.depth_m, self.draft_m,
                self.block_coeff, self.hull_drag_coeff, self.max_power_kw,
                self.propulsive_efficiency, self.sfc_g_per_kwh,
                step_mass, step_distance_nm,
                segment.hs_m, segment.tp_s, segment.encounter_angle_deg,
                segment.wind_speed_ms
            );
            if fuel_step >= self.fuel_kg {
                completion = self.fuel_kg / max(1.0, fuel_step);
                self.distance_nm += step_distance_nm * completion;
                self.elapsed_h += exposure_h * completion;
                self.fuel_kg = 0.0;
                self.failure_mode = "fuel_exhaustion";
                self.failure_zone = "Propulsion";
                self.failure_reason = (
                    "Fuel exhausted with "
                    f"{self.total_distance_nm - self.distance_nm:.0f}nm remaining"
                );
                failed = True;
                break;
            }

            self.fuel_kg -= fuel_step;
            self.distance_nm += step_distance_nm;
            self.elapsed_h += exposure_h;
            seg_elapsed_h += step_h;

            ice_rate = spray_icing_rate_kg_per_h(
                self.loa_m, self.beam_m, segment.water_temp_c,
                segment.wind_speed_ms, segment.hs_m
            );
            if ice_rate > 0.0 {
                self.ice_mass_kg += ice_rate * exposure_h;
                ice_kg = estimate_kg(
                    self.depth_m, self.fuel_kg, self.fuel_capacity_kg
                );
                base_gm = metacentric_height_m(
                    self.loa_m, self.beam_m, self.depth_m,
                    self.block_coeff, self.waterplane_coeff,
                    step_mass, ice_kg
                );
                self.gm_m = gm_with_ice(
                    base_gm, self.depth_m, step_mass, ice_kg,
                    self.ice_mass_kg
                );
                if capsize_risk(
                    self.gm_m, self.beam_m, segment.hs_m,
                    segment.encounter_angle_deg
                ) {
                    self.failure_mode = "capsize_ice";
                    self.failure_zone = "Vessel";
                    self.failure_reason = (
                        f"{self.ice_mass_kg:.0f}kg of ice raised the center "
                        "of gravity beyond the capsize threshold"
                    );
                    failed = True;
                    break;
                }
            }

            zone_failed = False;
            for zone_index in range(len(ALL_ZONES)) {
                zone = ALL_ZONES[zone_index];
                if segment.water_temp_c < mat.min_temp_c {
                    self.failure_mode = "cold_embrittlement";
                    self.failure_zone = zone;
                    self.failure_reason = (
                        f"{self.material} minimum temperature is "
                        f"{mat.min_temp_c:.1f}C; segment water is "
                        f"{segment.water_temp_c:.1f}C"
                    );
                    zone_failed = True;
                    break;
                }

                new_loss = thickness_loss_m(
                    mat.base_corrosion_rate_mm_yr,
                    segment.salinity_ppt,
                    segment.water_temp_c,
                    segment.ph,
                    zone_is_submerged(zone),
                    exposure_h
                ) * CORR_MULT;
                self.corrosion_m[zone_index] += new_loss;
                net_thickness = max(
                    0.0005,
                    self.thickness_m - self.corrosion_m[zone_index]
                );
                thickness_ratio = max(
                    1.0, min(8.0, self.thickness_m / net_thickness)
                );
                fatigue_softening = (
                    1.0 + min(0.64, self.fatigue[zone_index]) * 1.8
                );
                crack_softening = 1.0 + min(
                    1.5,
                    (
                        self.crack_m[zone_index]
                        / max(0.001, self.thickness_m)
                    ) ** 0.5
                );
                weakening = max(
                    1.0,
                    min(
                        18.0,
                        thickness_ratio ** 2.2
                        * fatigue_softening
                        * crack_softening
                    )
                );

                if net_thickness < self.thickness_m * 0.35 {
                    self.failure_mode = "corrosion_thinning";
                    self.failure_zone = zone;
                    self.failure_reason = (
                        f"{zone} corroded from "
                        f"{self.thickness_m * 1000.0:.1f}mm to "
                        f"{net_thickness * 1000.0:.1f}mm"
                    );
                    zone_failed = True;
                    break;
                }

                corr_multiplier = corrosion_fatigue_multiplier(
                    mat.corrodes,
                    mat.base_corrosion_rate_mm_yr,
                    segment.salinity_ppt,
                    segment.water_temp_c,
                    segment.ph,
                    self.elapsed_h
                );
                base_damage = segment_fatigue_damage(
                    self.loa_m, self.beam_m, self.depth_m,
                    self.block_coeff, net_thickness,
                    segment.hs_m, segment.encounter_angle_deg,
                    segment.slam_probability, segment.jonswap_gamma,
                    segment.tp_s, zone, scf,
                    mat.sn_slope, mat.sn_ref_stress_mpa,
                    mat.sn_ref_cycles, exposure_s
                );
                self.fatigue[zone_index] += (
                    base_damage
                    * corr_multiplier
                    * weakening
                    * DAMAGE_MULT
                );
                if self.fatigue[zone_index] >= 1.0 {
                    self.fatigue[zone_index] = 1.0;
                    self.failure_mode = "fatigue";
                    self.failure_zone = zone;
                    self.failure_reason = (
                        f"Miner damage reached 100% at {zone} "
                        f"during segment {segment.sequence}"
                    );
                    zone_failed = True;
                    break;
                }

                stress = significant_stress_mpa(
                    self.loa_m, self.beam_m, self.depth_m,
                    self.block_coeff, net_thickness,
                    segment.hs_m, segment.encounter_angle_deg,
                    segment.slam_probability, segment.jonswap_gamma,
                    segment.tp_s, zone, scf
                ) * weakening;
                zero_period = zero_crossing_period_s(
                    segment.tp_s, segment.jonswap_gamma
                );
                cycles = exposure_s / max(0.5, zero_period);
                delta_k = stress_intensity_factor(
                    stress * 2.0,
                    max(1e-6, self.crack_m[zone_index])
                );
                growth = paris_crack_growth(delta_k, mat.e_gpa);
                self.crack_m[zone_index] += (
                    growth
                    * cycles
                    * CRACK_MULT
                    * weakening ** 0.5
                );
                if is_critical_crack(
                    self.crack_m[zone_index],
                    stress,
                    mat.k_ic_mpa_sqrtm
                ) {
                    self.failure_mode = "brittle_fracture";
                    self.failure_zone = zone;
                    self.failure_reason = (
                        f"{zone} crack reached "
                        f"{self.crack_m[zone_index] * 1000.0:.2f}mm "
                        f"and exceeded KIC={mat.k_ic_mpa_sqrtm:.0f}"
                    );
                    zone_failed = True;
                    break;
                }
            }

            if zone_failed {
                failed = True;
                break;
            }
        }

        if not failed {
            seal_survival = (
                seal_hourly_survival(self.seal)
                ** (seg_duration_h * SIM_TIME_MULT)
            );
            if seal_survival < 0.50 {
                self.failure_mode = "seal_breach";
                self.failure_zone = "Hull";
                self.failure_reason = (
                    "Seal integrity fell to "
                    f"{seal_survival * 100.0:.0f}% during segment "
                    f"{segment.sequence}"
                );
                failed = True;
            }
        }

        if failed {
            self._record_failure(target);
            disengage;
        }

        visit target;
    }
}
