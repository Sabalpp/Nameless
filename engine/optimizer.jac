"""Grid-search and per-zone greedy optimizers — port of main.rs optimizer sections.

run_optimizer: cartesian sweep over materials × welds × seals × thicknesses.
run_per_zone_optimizer: cheapest-first candidates, greedily upgrade failing zones.

Survivor ranking uses a stable sort with explicit tiebreak (cost_usd, then material).
"""

import from engine.types {
    FailureMode,
    FailureModeKind,
    HullGeometry,
    HullZone,
    MaterialGrade,
    OptimizerResult,
    PropulsionSpec,
    SealQuality,
    SearchSpace,
    SimOutcome,
    SurvivorEntry,
    VesselConfig,
    VoyageRoute,
    WeldQuality,
    ZoneSpec,
    ZoneSummary,
    all_hull_zones
}
import from engine.materials { parse_material, parse_weld, parse_seal }
import from engine.config { uniform }
import from engine.cost { total_config_cost_usd }
import from engine.voyage { run_voyage }
import from engine.outcome { survived, failure_mode_label }

# ---------------------------------------------------------------------------
# Local types
# ---------------------------------------------------------------------------

obj ZoneCandidate {
    has material: MaterialGrade,
        thickness_m: float,
        weld: WeldQuality,
        seal: SealQuality;
}

obj PerZoneResult {
    has config: VesselConfig,
        optimizer: OptimizerResult;
}

# ---------------------------------------------------------------------------
# SearchSpace helpers
# ---------------------------------------------------------------------------

"Default material / quality / thickness sweep used by demo and brief cheapest tier."
def default_sweep(hull: HullGeometry, propulsion: PropulsionSpec) -> SearchSpace {
    return SearchSpace(
        hull=hull,
        propulsion=propulsion,
        materials=[
            "MildSteelA",
            "MildSteelE",
            "Ah36",
            "Dh36",
            "Aluminum5083"
        ],
        weld_qualities=["Economy", "Standard", "Premium"],
        seal_qualities=["Economy", "Commercial", "Marine"],
        thicknesses_m=[0.004, 0.005, 0.006, 0.008]
    );
}

def search_space_config_count(space: SearchSpace) -> int {
    return (
        len(space.materials)
        * len(space.weld_qualities)
        * len(space.seal_qualities)
        * len(space.thicknesses_m)
    );
}

"AI-friendly optimizer-only envelope (OptimizerResult::as_ai_output)."
def optimizer_as_ai_output(result: OptimizerResult) -> dict[str, any] {
    cheapest: dict[str, any] | None = None;
    if result.cheapest_survivor is not None {
        s = result.cheapest_survivor;
        cheapest = {
            "material": s.material,
            "thickness_mm": s.thickness_mm,
            "weld_quality": s.weld_quality,
            "seal_quality": s.seal_quality,
            "cost_usd": s.cost_usd,
            "fuel_remaining_kg": s.fuel_remaining_kg,
            "final_gm_m": s.final_gm_m,
            "worst_zone_fatigue": s.worst_zone_fatigue
        };
    }
    all_list: list[dict[str, any]] = [];
    for s in result.all_survivors {
        all_list.append({
            "material": s.material,
            "thickness_mm": s.thickness_mm,
            "weld_quality": s.weld_quality,
            "seal_quality": s.seal_quality,
            "cost_usd": s.cost_usd,
            "fuel_remaining_kg": s.fuel_remaining_kg,
            "final_gm_m": s.final_gm_m,
            "worst_zone_fatigue": s.worst_zone_fatigue
        });
    }
    return {
        "schema_version": "1.0",
        "optimizer": {
            "configs_tested": result.configs_tested,
            "survivors_found": result.survivors_found,
            "cheapest_survivor": cheapest,
            "all_survivors": all_list,
            "failure_summary": result.failure_summary
        }
    };
}

# ---------------------------------------------------------------------------
# Ranking / helpers
# ---------------------------------------------------------------------------

def:priv _worst_fatigue(summaries: list[ZoneSummary]) -> float {
    worst = 0.0;
    for z in summaries {
        if z.fatigue_consumed > worst {
            worst = z.fatigue_consumed;
        }
    }
    return worst;
}

"Stable sort key: primary cost_usd, secondary material name (explicit tiebreak)."
def:priv _survivor_rank_key(s: SurvivorEntry) -> list[object] {
    return [s.cost_usd, s.material];
}

def:priv _zone_candidate_cost(
    candidate: ZoneCandidate,
    hull: HullGeometry,
    propulsion: PropulsionSpec
) -> float {
    config = uniform(
        hull,
        candidate.material,
        candidate.thickness_m,
        candidate.weld,
        candidate.seal,
        propulsion
    );
    return total_config_cost_usd(config);
}

def:priv _candidate_cost_key(
    candidate: ZoneCandidate,
    hull: HullGeometry,
    propulsion: PropulsionSpec
) -> float {
    return _zone_candidate_cost(candidate, hull, propulsion);
}

def:priv failure_zone(mode: FailureMode) -> HullZone | None {
    match mode.kind {
        case FailureModeKind.FATIGUE_FAILURE
            | FailureModeKind.BRITTLE_FRACTURE
            | FailureModeKind.SEAL_BREACH_FLOODING
            | FailureModeKind.COLD_TEMPERATURE_BRITTLENESS:
            return mode.zone;
        case FailureModeKind.CAPSIZE | FailureModeKind.FUEL_EXHAUSTION:
            return None;
    }
}

def:priv zone_index(zone: HullZone) -> int {
    zones = all_hull_zones();
    i = 0;
    for candidate in zones {
        if candidate == zone {
            return i;
        }
        i += 1;
    }
    return 0;
}

def:priv build_per_zone_config(
    hull: HullGeometry,
    propulsion: PropulsionSpec,
    candidates: list[ZoneCandidate],
    selections: list[int]
) -> VesselConfig {
    zones: list[ZoneSpec] = [];
    all_zones = all_hull_zones();
    idx = 0;
    for zone in all_zones {
        candidate = candidates[selections[idx]];
        zones.append(ZoneSpec(
            zone=zone,
            material=candidate.material,
            thickness_m=candidate.thickness_m,
            weld_quality=candidate.weld,
            seal_quality=candidate.seal
        ));
        idx += 1;
    }
    return VesselConfig(hull=hull, zones=zones, propulsion=propulsion);
}

def:priv survivor_entry_from_config(
    config: VesselConfig,
    outcome: SimOutcome
) -> SurvivorEntry {
    max_thick_mm = 0.0;
    for z in config.zones {
        mm = z.thickness_m * 1000.0;
        if mm > max_thick_mm {
            max_thick_mm = mm;
        }
    }
    return SurvivorEntry(
        material="Mixed per-zone",
        thickness_mm=max_thick_mm,
        weld_quality="Mixed per-zone",
        seal_quality="Mixed per-zone",
        cost_usd=outcome.total_config_cost_usd,
        fuel_remaining_kg=outcome.fuel_remaining_kg,
        final_gm_m=outcome.final_gm_m,
        worst_zone_fatigue=_worst_fatigue(outcome.zone_summaries)
    );
}

def:priv _bump_failure(counts: dict[str, int], label: str) {
    if label in counts {
        counts[label] = counts[label] + 1;
    } else {
        counts[label] = 1;
    }
}

def:priv _max_fatigue_zone(outcome: SimOutcome) -> HullZone {
    best_zone: HullZone = HullZone.KEEL;
    best_fatigue = -1.0;
    for z in outcome.zone_summaries {
        if z.fatigue_consumed > best_fatigue {
            best_fatigue = z.fatigue_consumed;
            best_zone = z.zone;
        }
    }
    return best_zone;
}

# ---------------------------------------------------------------------------
# Grid-search optimizer
# ---------------------------------------------------------------------------

"Cartesian sweep; survivors ranked by (cost_usd, material) with a stable sort."
def run_optimizer(space: SearchSpace, route: VoyageRoute) -> OptimizerResult {
    survivors: list[SurvivorEntry] = [];
    failure_counts: dict[str, int] = {};
    tested = 0;

    for mat_str in space.materials {
        material = parse_material(mat_str);
        if material is None {
            continue;
        }
        for weld_str in space.weld_qualities {
            weld = parse_weld(weld_str);
            if weld is None {
                continue;
            }
            for seal_str in space.seal_qualities {
                seal = parse_seal(seal_str);
                if seal is None {
                    continue;
                }
                for thick in space.thicknesses_m {
                    config = uniform(
                        space.hull,
                        material,
                        thick,
                        weld,
                        seal,
                        space.propulsion
                    );
                    outcome = run_voyage(config, route);
                    tested += 1;

                    if survived(outcome) {
                        survivors.append(SurvivorEntry(
                            material=mat_str,
                            thickness_mm=thick * 1000.0,
                            weld_quality=weld_str,
                            seal_quality=seal_str,
                            cost_usd=outcome.total_config_cost_usd,
                            fuel_remaining_kg=outcome.fuel_remaining_kg,
                            final_gm_m=outcome.final_gm_m,
                            worst_zone_fatigue=_worst_fatigue(outcome.zone_summaries)
                        ));
                    } elif outcome.failure is not None {
                        _bump_failure(
                            failure_counts,
                            failure_mode_label(outcome.failure.mode)
                        );
                    }
                }
            }
        }
    }

    # Stable sort + explicit tiebreak (cost_usd, then material name).
    survivors = sorted(survivors, key=_survivor_rank_key);

    cheapest: SurvivorEntry | None = None;
    if len(survivors) > 0 {
        cheapest = survivors[0];
    }

    return OptimizerResult(
        configs_tested=tested,
        survivors_found=len(survivors),
        cheapest_survivor=cheapest,
        all_survivors=survivors,
        failure_summary=failure_counts
    );
}

# ---------------------------------------------------------------------------
# Per-zone greedy optimizer
# ---------------------------------------------------------------------------

"""Greedy per-zone upgrade: candidates sorted cheapest-first; on failure, bump
the failed zone (or next cheapest upgradeable zone) until a survivor is found
or the search is exhausted. Returns best-progress config when none survive.
"""
def run_per_zone_optimizer(space: SearchSpace, route: VoyageRoute) -> PerZoneResult {
    candidates: list[ZoneCandidate] = [];

    for mat_str in space.materials {
        material = parse_material(mat_str);
        if material is None {
            continue;
        }
        for weld_str in space.weld_qualities {
            weld = parse_weld(weld_str);
            if weld is None {
                continue;
            }
            for seal_str in space.seal_qualities {
                seal = parse_seal(seal_str);
                if seal is None {
                    continue;
                }
                for thickness_m in space.thicknesses_m {
                    candidates.append(ZoneCandidate(
                        material=material,
                        thickness_m=thickness_m,
                        weld=weld,
                        seal=seal
                    ));
                }
            }
        }
    }

    candidates = sorted(
        candidates,
        key=lambda (c: ZoneCandidate) -> float {
            return _candidate_cost_key(c, space.hull, space.propulsion);
        }
    );

    if len(candidates) == 0 {
        candidates.append(ZoneCandidate(
            material=MaterialGrade.MILD_STEEL_A,
            thickness_m=0.004,
            weld=WeldQuality.ECONOMY,
            seal=SealQuality.ECONOMY
        ));
    }

    selections: list[int] = [];
    for _z in all_hull_zones() {
        selections.append(0);
    }

    tested = 0;
    failure_counts: dict[str, int] = {};
    max_iterations = len(all_hull_zones()) * len(candidates);
    best_config = build_per_zone_config(
        space.hull, space.propulsion, candidates, selections
    );
    best_distance = -1.0;

    for _iter in range(max_iterations) {
        config = build_per_zone_config(
            space.hull, space.propulsion, candidates, selections
        );
        outcome = run_voyage(config, route);
        tested += 1;

        if outcome.distance_completed_nm > best_distance {
            best_distance = outcome.distance_completed_nm;
            best_config = config;
        }

        if survived(outcome) {
            survivor = survivor_entry_from_config(config, outcome);
            return PerZoneResult(
                config=config,
                optimizer=OptimizerResult(
                    configs_tested=tested,
                    survivors_found=1,
                    cheapest_survivor=survivor,
                    all_survivors=[survivor],
                    failure_summary=failure_counts
                )
            );
        }

        if outcome.failure is None {
            break;
        }

        failure = outcome.failure;
        _bump_failure(failure_counts, failure_mode_label(failure.mode));

        target = failure_zone(failure.mode);
        if target is None {
            target = _max_fatigue_zone(outcome);
        }
        idx = zone_index(target);

        if selections[idx] + 1 >= len(candidates) {
            found_next = False;
            next_idx = 0;
            min_sel = 999999;
            zi = 0;
            for sel in selections {
                if sel + 1 < len(candidates) and sel < min_sel {
                    min_sel = sel;
                    next_idx = zi;
                    found_next = True;
                }
                zi += 1;
            }
            if not found_next {
                break;
            }
            idx = next_idx;
        }
        selections[idx] = selections[idx] + 1;
    }

    return PerZoneResult(
        config=best_config,
        optimizer=OptimizerResult(
            configs_tested=tested,
            survivors_found=0,
            cheapest_survivor=None,
            all_survivors=[],
            failure_summary=failure_counts
        )
    );
}
