"""SeaForge v3 graph-native API service.

Public walkers:
  SetupMission  - persist a typed mission graph
  RunVoyage     - send one vessel-state walker through the graph
  RunOptimizer  - revise designs from accumulated graph traces
  GetMission    - inspect the graph's persistent knowledge
"""

import math;
import json;
import random;
import from agent_runner.codex_cli {
    run_material_optimizer,
    run_route_planner
}
import from engine.services {
    enrich_route_points,
    save_simulation_trace
}
import from engine.domain {
    RoutePointInput, VesselInput,
    MissionNode, VesselDesignNode, WaypointNode, RouteEvaluation,
    FailureTrace, SuccessTrace,
    HasDesign, StartsAt, RouteSegment, FailedHere, CompletedHere,
    EvaluatedRoute,
    SetupMissionResult, VoyageResult, AttemptSummary, ConfigRevision,
    OptimizerResult, RouteRevision, RouteSummary, PointOptimizationResult,
    FailureView, WaypointView, MissionView
}
import from engine.voyage { VoyageWalker }

# ---------------------------------------------------------------------------
# Codex CLI optimizer
# ---------------------------------------------------------------------------

def _codex_prompt(
    history: list[AttemptSummary],
    design: VesselDesignNode,
    best_survivor_cost_usd: float
) -> str {
    lines: list[str] = [
        "You are SeaForge's vessel cost-optimization agent.",
        "Choose exactly one next vessel configuration.",
        "Fix diagnosed failures with the smallest targeted change.",
        "After a survivor exists, probe a cheaper nearby design.",
        "Never repeat an already tested configuration.",
        "The response must match the supplied JSON schema.",
        "",
        "Allowed materials: MildSteelA, MildSteelE, Ah36, Dh36, Eh36, Eh40, Aluminum5083.",
        "Allowed welds: Economy, Standard, Premium.",
        "Allowed seals: Economy, Commercial, Marine.",
        "Thickness range: 0.003 through 0.060 meters.",
        "",
        (
            f"Current design: material={design.material}, "
            f"thickness_m={design.thickness_m}, weld={design.weld}, "
            f"seal={design.seal}."
        ),
        f"Best survivor cost so far: {best_survivor_cost_usd:.2f} USD.",
        "",
        "Persisted graph attempt history:"
    ];
    for attempt in history {
        lines.append(
            (
                f"- attempt={attempt.attempt}, survived={attempt.survived}, "
                f"cost_usd={attempt.cost_usd:.2f}, "
                f"material={attempt.material}, "
                f"thickness_m={attempt.thickness_m}, "
                f"weld={attempt.weld}, seal={attempt.seal}, "
                f"failure_mode={attempt.failure_mode}, "
                f"failure_zone={attempt.failure_zone}, "
                f"distance_pct={attempt.distance_pct:.2f}, "
                f"reason={attempt.failure_reason}"
            )
        );
    }
    return "\n".join(lines);
}

def _codex_revision(
    history: list[AttemptSummary],
    design: VesselDesignNode,
    best_survivor_cost_usd: float,
    model: str,
    timeout_s: int
) -> ConfigRevision {
    prompt = _codex_prompt(history, design, best_survivor_cost_usd);
    raw_json = run_material_optimizer(
        prompt, model, timeout_s
    );
    parsed = json.loads(raw_json);
    if not isinstance(parsed, dict) {
        raise ValueError("Codex returned a non-object revision");
    }
    revision = parsed as dict[str, any];
    return ConfigRevision(
        material=_valid_material(str(revision.get("material", ""))),
        thickness_m=_number(
            revision, "thickness_m", design.thickness_m
        ),
        weld=_valid_weld(str(revision.get("weld", ""))),
        seal=_valid_seal(str(revision.get("seal", ""))),
        reasoning=str(revision.get("reasoning", ""))
    );
}

obj BuiltRoute {
    has origin: WaypointNode | None = None,
        distance_nm: float = 0.0,
        condition_score: float = 0.0,
        navigable: bool = True,
        condition_source: str = "",
        waypoint_names: list[str] = [];
}

def _route_prompt(
    origin: RoutePointInput,
    destination: RoutePointInput,
    history: list[RouteSummary],
    direct_distance_nm: float
) -> str {
    lines: list[str] = [
        "You are SeaForge's ocean-route planning agent.",
        "Return only intermediate geographic waypoints between the endpoints.",
        "Choose a physically plausible water route and avoid crossing land.",
        "Use 0-2 intermediate points for short trips and up to 10 for long trips.",
        "Do not repeat a prior route. Improve current marine-condition score.",
        "Coordinates use WGS84 degrees. Do not include either endpoint.",
        "This is simulation planning, not navigational advice.",
        "The response must match the supplied JSON schema.",
        "",
        (
            f"Origin: {origin.name}, lat={origin.lat_deg}, "
            f"lon={origin.lon_deg}."
        ),
        (
            f"Destination: {destination.name}, lat={destination.lat_deg}, "
            f"lon={destination.lon_deg}."
        ),
        f"Great-circle distance: {direct_distance_nm:.1f} nautical miles.",
        "",
        "Persisted route evaluations:"
    ];
    if not history {
        lines.append("- none; propose the safest reasonable water route");
    }
    for route in history {
        lines.append(
            (
                f"- route={route.route_id}, survived={route.survived}, "
                f"navigable={route.navigable}, "
                f"condition_score={route.condition_score:.2f}, "
                f"distance_nm={route.distance_nm:.1f}, "
                f"source={route.condition_source}, "
                f"waypoints={', '.join(route.waypoint_names)}, "
                f"failure={route.failure_reason}"
            )
        );
    }
    return "\n".join(lines);
}

def _codex_route(
    origin: RoutePointInput,
    destination: RoutePointInput,
    history: list[RouteSummary],
    direct_distance_nm: float,
    model: str,
    timeout_s: int
) -> RouteRevision {
    raw_json = run_route_planner(
        _route_prompt(origin, destination, history, direct_distance_nm),
        model,
        timeout_s
    );
    parsed = json.loads(raw_json);
    if not isinstance(parsed, dict) {
        raise ValueError("Codex returned a non-object route");
    }
    route = parsed as dict[str, any];
    raw_waypoints = route.get("waypoints", []);
    waypoints: list[dict[str, any]] = [];
    if isinstance(raw_waypoints, list) {
        for raw_waypoint in raw_waypoints[:10] {
            if isinstance(raw_waypoint, dict) {
                waypoint = raw_waypoint as dict[str, any];
                lat = _number(waypoint, "lat_deg", 999.0);
                lon = _number(waypoint, "lon_deg", 999.0);
                if -90.0 <= lat <= 90.0 and -180.0 <= lon <= 180.0 {
                    waypoints.append({
                        "name": str(
                            waypoint.get(
                                "name", f"Ocean waypoint {len(waypoints) + 1}"
                            )
                        ),
                        "lat_deg": lat,
                        "lon_deg": lon
                    });
                }
            }
        }
    }
    return RouteRevision(
        waypoints=waypoints,
        reasoning=str(route.get("reasoning", ""))
    );
}

def _fallback_route(
    origin: RoutePointInput,
    destination: RoutePointInput,
    route_id: int,
    direct_distance_nm: float
) -> RouteRevision {
    count = max(0, min(6, int(direct_distance_nm / 500.0)));
    if count == 0 and direct_distance_nm > 80.0 {
        count = 1;
    }
    waypoints: list[dict[str, any]] = [];
    offset_pattern = [-1.0, 0.0, 1.0];
    lateral = offset_pattern[(route_id - 1) % len(offset_pattern)];
    corridor_offset = lateral * min(4.0, direct_distance_nm / 700.0);
    delta_lat = destination.lat_deg - origin.lat_deg;
    delta_lon = destination.lon_deg - origin.lon_deg;
    norm = max(0.001, (delta_lat ** 2 + delta_lon ** 2) ** 0.5);
    for index in range(count) {
        fraction = float(index + 1) / float(count + 1);
        bow = math.sin(math.pi * fraction);
        lat = (
            origin.lat_deg + delta_lat * fraction
            - (delta_lon / norm) * corridor_offset * bow
        );
        lon = (
            origin.lon_deg + delta_lon * fraction
            + (delta_lat / norm) * corridor_offset * bow
        );
        if lon > 180.0 { lon -= 360.0; }
        elif lon < -180.0 { lon += 360.0; }
        waypoints.append({
            "name": f"Fallback ocean waypoint {index + 1}",
            "lat_deg": max(-89.0, min(89.0, lat)),
            "lon_deg": lon
        });
    }
    return RouteRevision(
        waypoints=waypoints,
        reasoning="Generated a deterministic great-circle corridor fallback"
    );
}

def _enriched_points(
    origin_raw: dict[str, any],
    destination_raw: dict[str, any],
    revision: RouteRevision,
    use_live_conditions: bool,
    timeout_s: int
) -> list[RoutePointInput] {
    raw_points: list[dict[str, any]] = [origin_raw];
    raw_points.extend(revision.waypoints);
    raw_points.append(destination_raw);
    enriched_json = enrich_route_points(
        json.dumps(raw_points), use_live_conditions, timeout_s
    );
    parsed = json.loads(enriched_json);
    points: list[RoutePointInput] = [];
    if isinstance(parsed, list) {
        for index in range(len(parsed)) {
            raw_point = parsed[index];
            if isinstance(raw_point, dict) {
                point = _point_from_dict(
                    raw_point as dict[str, any],
                    (
                        "Origin" if index == 0
                        else "Destination" if index == len(parsed) - 1
                        else f"Waypoint {index}"
                    )
                );
                if index == 0 or index == len(parsed) - 1 {
                    point.navigable = True;
                }
                points.append(point);
            }
        }
    }
    return points;
}

def _point_condition_score(point: RoutePointInput) -> float {
    cold_penalty = max(0.0, 4.0 - point.water_temp_c) * 3.0;
    return (
        point.hs_m ** 2 * 8.0
        + point.wind_speed_ms * 1.5
        + point.slam_probability * 25.0
        + cold_penalty
    );
}

def _build_route(
    mission: MissionNode,
    route_id: int,
    points: list[RoutePointInput]
) -> BuiltRoute {
    if len(points) < 2 {
        return BuiltRoute(navigable=False);
    }
    distance = 0.0;
    weighted_score = 0.0;
    navigable = True;
    all_live = True;
    names: list[str] = [];
    previous: WaypointNode | None = None;
    origin_node: WaypointNode | None = None;

    for index in range(len(points)) {
        point = points[index];
        point_score = _point_condition_score(point);
        waypoint = WaypointNode(
            route_id=route_id,
            sequence=index,
            name=point.name,
            lat_deg=point.lat_deg,
            lon_deg=point.lon_deg,
            is_origin=index == 0,
            is_destination=index == len(points) - 1,
            hs_m=point.hs_m,
            tp_s=point.tp_s,
            jonswap_gamma=point.jonswap_gamma,
            water_temp_c=point.water_temp_c,
            salinity_ppt=point.salinity_ppt,
            ph=point.ph,
            wind_speed_ms=point.wind_speed_ms,
            slam_probability=point.slam_probability,
            condition_source=point.condition_source,
            navigable=point.navigable,
            condition_score=point_score
        );
        names.append(point.name);
        navigable = navigable and point.navigable;
        all_live = (
            all_live and point.condition_source == "open-meteo-current"
        );

        if previous is None {
            _start = mission +>:StartsAt():+> waypoint;
            origin_node = waypoint;
        } else {
            prior = previous as WaypointNode;
            segment_distance = _haversine_nm(
                prior.lat_deg, prior.lon_deg,
                waypoint.lat_deg, waypoint.lon_deg
            );
            heading = _initial_bearing_deg(
                prior.lat_deg, prior.lon_deg,
                waypoint.lat_deg, waypoint.lon_deg
            );
            encounter: float = (
                math.fabs(heading - point.wave_direction_deg) % 360.0
            );
            if encounter > 180.0 {
                encounter = 360.0 - encounter;
            }
            _segment = prior +>:RouteSegment(
                sequence=index,
                distance_nm=segment_distance,
                heading_deg=heading,
                hs_m=point.hs_m,
                tp_s=point.tp_s,
                jonswap_gamma=point.jonswap_gamma,
                encounter_angle_deg=encounter,
                water_temp_c=point.water_temp_c,
                salinity_ppt=point.salinity_ppt,
                ph=point.ph,
                wind_speed_ms=point.wind_speed_ms,
                slam_probability=point.slam_probability
            ):+> waypoint;
            distance += segment_distance;
            weighted_score += point_score * segment_distance;
        }
        previous = waypoint;
    }
    average_score = weighted_score / max(1.0, distance);
    return BuiltRoute(
        origin=origin_node,
        distance_nm=distance,
        condition_score=average_score + distance * 0.01,
        navigable=navigable,
        condition_source=(
            "open-meteo-current" if all_live else "estimated-or-mixed"
        ),
        waypoint_names=names
    );
}

def _design_snapshot(design: VesselDesignNode) -> dict[str, any] {
    return {
        "material": design.material,
        "thickness_m": design.thickness_m,
        "thickness_mm": design.thickness_m * 1000.0,
        "weld": design.weld,
        "seal": design.seal,
        "loa_m": design.loa_m,
        "beam_m": design.beam_m,
        "depth_m": design.depth_m,
        "fuel_capacity_kg": design.fuel_capacity_kg,
        "revision": design.revision
    };
}

def _point_snapshots(
    points: list[RoutePointInput]
) -> list[dict[str, any]] {
    snapshots: list[dict[str, any]] = [];
    for index in range(len(points)) {
        point = points[index];
        snapshots.append({
            "sequence": index,
            "name": point.name,
            "lat_deg": point.lat_deg,
            "lon_deg": point.lon_deg,
            "hs_m": point.hs_m,
            "tp_s": point.tp_s,
            "wave_direction_deg": point.wave_direction_deg,
            "water_temp_c": point.water_temp_c,
            "wind_speed_ms": point.wind_speed_ms,
            "salinity_ppt": point.salinity_ppt,
            "ph": point.ph,
            "slam_probability": point.slam_probability,
            "condition_source": point.condition_source,
            "condition_score": _point_condition_score(point),
            "navigable": point.navigable
        });
    }
    return snapshots;
}

def _voyage_snapshot(
    result: VoyageResult | None,
    points: list[RoutePointInput],
    route_distance_nm: float,
    fallback_reason: str
) -> dict[str, any] {
    if result is None {
        return {
            "survived": False,
            "attempt": 0,
            "distance_nm": 0.0,
            "total_distance_nm": route_distance_nm,
            "distance_pct": 0.0,
            "cost_usd": 0.0,
            "failure_mode": "route_rejected",
            "failure_zone": "Route",
            "failure_reason": fallback_reason,
            "terminal_waypoint": "",
            "terminal_sequence": -1
        };
    }
    voyage = result as VoyageResult;
    terminal_sequence = -1;
    for index in range(len(points)) {
        if points[index].name == voyage.terminal_waypoint {
            terminal_sequence = index;
            break;
        }
    }
    return {
        "survived": voyage.survived,
        "attempt": voyage.attempt,
        "distance_nm": voyage.distance_nm,
        "total_distance_nm": voyage.total_distance_nm,
        "distance_pct": (
            voyage.distance_nm / max(1.0, voyage.total_distance_nm)
        ) * 100.0,
        "elapsed_h": voyage.elapsed_h,
        "fuel_remaining_kg": voyage.fuel_remaining_kg,
        "gm_m": voyage.gm_m,
        "cost_usd": voyage.cost_usd,
        "failure_mode": voyage.failure_mode,
        "failure_zone": voyage.failure_zone,
        "failure_reason": voyage.failure_reason,
        "terminal_waypoint": voyage.terminal_waypoint,
        "terminal_sequence": terminal_sequence
    };
}

def _save_simulation(
    mission: MissionNode,
    origin: RoutePointInput,
    destination: RoutePointInput,
    iterations: list[dict[str, any]],
    best_route_names: list[str],
    status: str,
    use_codex: bool,
    codex_model: str
) -> str {
    payload: dict[str, any] = {
        "mission": {
            "id": jid(mission),
            "name": mission.name,
            "status": status,
            "origin": {
                "name": origin.name,
                "lat_deg": origin.lat_deg,
                "lon_deg": origin.lon_deg
            },
            "destination": {
                "name": destination.name,
                "lat_deg": destination.lat_deg,
                "lon_deg": destination.lon_deg
            }
        },
        "optimizer": {
            "backend": "codex-cli" if use_codex else "local-rules",
            "model": codex_model if use_codex else "",
            "stage_order": [
                "route_search",
                "lock_best_successful_route",
                "material_search"
            ]
        },
        "iterations": iterations,
        "best": {
            "route_id": mission.best_route_id,
            "route_score": mission.best_route_score,
            "route_distance_nm": mission.total_distance_nm,
            "route_waypoints": best_route_names,
            "cost_usd": mission.best_cost_usd,
            "material": mission.best_material,
            "thickness_m": mission.best_thickness_m,
            "thickness_mm": mission.best_thickness_m * 1000.0,
            "weld": mission.best_weld,
            "seal": mission.best_seal
        }
    };
    return save_simulation_trace(json.dumps(payload));
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _haversine_nm(
    lat1: float, lon1: float, lat2: float, lon2: float
) -> float {
    radius_nm = 3440.065;
    lat1_rad = lat1 * math.pi / 180.0;
    lat2_rad = lat2 * math.pi / 180.0;
    delta_lat = (lat2 - lat1) * math.pi / 180.0;
    delta_lon = (lon2 - lon1) * math.pi / 180.0;
    value = (
        math.sin(delta_lat / 2.0) ** 2
        + math.cos(lat1_rad)
        * math.cos(lat2_rad)
        * math.sin(delta_lon / 2.0) ** 2
    );
    angle = 2.0 * math.atan2(math.sqrt(value), math.sqrt(1.0 - value));
    return float(radius_nm * angle);
}

def _initial_bearing_deg(
    lat1: float, lon1: float, lat2: float, lon2: float
) -> float {
    lat1_rad = lat1 * math.pi / 180.0;
    lat2_rad = lat2 * math.pi / 180.0;
    delta_lon = (lon2 - lon1) * math.pi / 180.0;
    y_value = math.sin(delta_lon) * math.cos(lat2_rad);
    x_value = (
        math.cos(lat1_rad) * math.sin(lat2_rad)
        - math.sin(lat1_rad)
        * math.cos(lat2_rad)
        * math.cos(delta_lon)
    );
    return float(
        (math.atan2(y_value, x_value) * 180.0 / math.pi + 360.0) % 360.0
    );
}

def _number(
    raw: dict[str, any], key: str, fallback: float
) -> float {
    value = raw.get(key, fallback);
    if isinstance(value, int) or isinstance(value, float) {
        return float(value);
    }
    if isinstance(value, str) {
        try {
            return float(value);
        } except ValueError {
            return fallback;
        }
    }
    return fallback;
}

def _point_from_dict(
    raw: dict[str, any], fallback_name: str
) -> RoutePointInput {
    return RoutePointInput(
        name=str(raw.get("name", fallback_name)),
        lat_deg=_number(raw, "lat_deg", 0.0),
        lon_deg=_number(raw, "lon_deg", 0.0),
        hs_m=_number(raw, "hs_m", 2.5),
        tp_s=_number(raw, "tp_s", 9.0),
        jonswap_gamma=_number(raw, "jonswap_gamma", 3.3),
        encounter_angle_deg=_number(raw, "encounter_angle_deg", 0.0),
        water_temp_c=_number(raw, "water_temp_c", 15.0),
        salinity_ppt=_number(raw, "salinity_ppt", 35.0),
        ph=_number(raw, "ph", 8.1),
        wind_speed_ms=_number(raw, "wind_speed_ms", 10.0),
        slam_probability=_number(raw, "slam_probability", 0.15),
        duration_scale=_number(raw, "duration_scale", 1.0),
        wave_direction_deg=_number(raw, "wave_direction_deg", 0.0),
        condition_source=str(raw.get("condition_source", "provided")),
        navigable=bool(raw.get("navigable", True))
    );
}

def _vessel_from_dict(raw: dict[str, any]) -> VesselInput {
    return VesselInput(
        loa_m=_number(raw, "loa_m", 7.3),
        beam_m=_number(raw, "beam_m", 2.4),
        depth_m=_number(raw, "depth_m", 1.1),
        draft_m=_number(raw, "draft_m", 0.32),
        block_coeff=_number(raw, "block_coeff", 0.58),
        waterplane_coeff=_number(raw, "waterplane_coeff", 0.78),
        material=str(raw.get("material", "MildSteelA")),
        thickness_m=_number(raw, "thickness_m", 0.004),
        weld=str(raw.get("weld", "Economy")),
        seal=str(raw.get("seal", "Economy")),
        max_power_kw=_number(raw, "max_power_kw", 300.0),
        fuel_capacity_kg=_number(raw, "fuel_capacity_kg", 2000.0),
        sfc_g_per_kwh=_number(raw, "sfc_g_per_kwh", 220.0),
        propulsive_efficiency=_number(
            raw, "propulsive_efficiency", 0.72
        ),
        hull_drag_coeff=_number(raw, "hull_drag_coeff", 0.007)
    );
}

def _find_mission(mission_name: str) -> MissionNode | None {
    for mission in [root -->[?:MissionNode]] {
        if mission.name == mission_name {
            return mission;
        }
    }
    return None;
}

def _get_design(mission: MissionNode) -> VesselDesignNode | None {
    designs = [mission ->:HasDesign:->];
    return designs[0] if designs else None;
}

def _get_origin(
    mission: MissionNode, route_id: int = -1
) -> WaypointNode | None {
    origins = [mission ->:StartsAt:->];
    selected_id = (
        route_id
        if route_id >= 0
        else mission.best_route_id if mission.best_route_id > 0 else 0
    );
    for origin in origins {
        if origin.route_id == selected_id {
            return origin;
        }
    }
    return origins[0] if origins else None;
}

def _valid_material(material: str) -> str {
    allowed = [
        "MildSteelA", "MildSteelE", "Ah36", "Dh36",
        "Eh36", "Eh40", "Aluminum5083"
    ];
    return material if material in allowed else "MildSteelA";
}

def _valid_weld(weld: str) -> str {
    return weld if weld in ["Economy", "Standard", "Premium"] else "Economy";
}

def _valid_seal(seal: str) -> str {
    return seal if seal in ["Economy", "Commercial", "Marine"] else "Economy";
}

def _apply_revision(
    design: VesselDesignNode, revision: ConfigRevision
) {
    design.material = _valid_material(revision.material);
    design.thickness_m = max(0.003, min(0.060, revision.thickness_m));
    design.weld = _valid_weld(revision.weld);
    design.seal = _valid_seal(revision.seal);
    design.revision += 1;
}

def _configuration_key(design: VesselDesignNode) -> str {
    return (
        design.material
        + "|"
        + f"{design.thickness_m:.6f}"
        + "|"
        + design.weld
        + "|"
        + design.seal
    );
}

def _rule_revision(
    history: list[AttemptSummary],
    design: VesselDesignNode
) -> ConfigRevision {
    if not history {
        return ConfigRevision(
            material=design.material,
            thickness_m=design.thickness_m,
            weld=design.weld,
            seal=design.seal,
            reasoning="Start from the persisted baseline design"
        );
    }

    latest = history[-1];
    cheapest_survivor: AttemptSummary | None = None;
    first_survivor_index = -1;
    for history_index in range(len(history)) {
        candidate = history[history_index];
        if candidate.survived {
            if first_survivor_index < 0 {
                first_survivor_index = history_index;
            }
            if (
                cheapest_survivor is None
                or candidate.cost_usd
                < (cheapest_survivor as AttemptSummary).cost_usd
            ) {
                cheapest_survivor = candidate;
            }
        }
    }
    if cheapest_survivor is not None {
        best = cheapest_survivor as AttemptSummary;
        probe = max(0, len(history) - first_survivor_index - 1);
        weld_options = ["Economy", "Standard", "Premium"];
        seal_options = ["Economy", "Commercial", "Marine"];
        material_options = [
            "MildSteelA", "MildSteelE", "Ah36", "Eh36"
        ];
        combinations_per_thickness = (
            len(weld_options)
            * len(seal_options)
            * len(material_options)
        );
        combination = probe % combinations_per_thickness;
        thickness_level = (
            int(probe / combinations_per_thickness) + 1
        );
        probe_weld = weld_options[
            combination % len(weld_options)
        ];
        probe_seal = seal_options[
            int(combination / len(weld_options))
            % len(seal_options)
        ];
        probe_material = material_options[
            int(
                combination
                / (len(weld_options) * len(seal_options))
            ) % len(material_options)
        ];
        return ConfigRevision(
            material=probe_material,
            thickness_m=max(
                0.003,
                best.thickness_m - 0.001 * thickness_level
            ),
            weld=probe_weld,
            seal=probe_seal,
            reasoning=(
                "Explore a distinct lower-cost material, weld, seal, "
                "and thickness combination around the cheapest survivor"
            )
        );
    }
    repeated_mode = 0;
    for prior_attempt in history {
        if (
            not prior_attempt.survived
            and prior_attempt.failure_mode == latest.failure_mode
        ) {
            repeated_mode += 1;
        }
    }
    material = design.material;
    thickness = design.thickness_m;
    weld = design.weld;
    seal = design.seal;
    reason = "Apply the smallest rule-based revision";

    if latest.survived {
        if weld == "Premium" {
            weld = "Standard";
            reason = "Probe a cheaper weld after a successful attempt";
        } elif weld == "Standard" {
            weld = "Economy";
            reason = "Probe the cheapest weld after a successful attempt";
        } elif seal == "Marine" {
            seal = "Commercial";
            reason = "Probe a cheaper seal after a successful attempt";
        } elif seal == "Commercial" {
            seal = "Economy";
            reason = "Probe the cheapest seal after a successful attempt";
        } elif thickness > 0.003 {
            thickness = max(0.003, thickness - 0.001);
            reason = "Reduce plate thickness by one millimeter after survival";
        } elif material != "MildSteelA" {
            material = "MildSteelA";
            reason = "Probe the least expensive material after survival";
        }
    } elif latest.failure_mode == "seal_breach" {
        seal = "Commercial" if seal == "Economy" else "Marine";
        reason = "Upgrade only the seal implicated by the failure trace";
    } elif latest.failure_mode == "cold_embrittlement" {
        material = "MildSteelE" if material == "MildSteelA" else "Eh36";
        reason = "Select a colder-rated material";
    } elif latest.failure_mode in ["fatigue", "brittle_fracture"] {
        if weld == "Economy" {
            weld = "Standard";
            reason = "Reduce the crack-driving weld stress concentration";
        } elif repeated_mode >= 7 and material != "Eh36" {
            material = "Eh36";
            reason = "Repeated structural failures justify cold-tough EH36 steel";
        } elif repeated_mode >= 5 and material == "MildSteelA" {
            material = "Ah36";
            reason = "Repeated structural failures justify higher-strength AH36 steel";
        } elif repeated_mode >= 3 and weld == "Standard" {
            weld = "Premium";
            reason = "Persistent fatigue requires the lowest weld stress concentration";
        } elif thickness < 0.060 {
            thickness = min(
                0.060,
                thickness + (0.006 if repeated_mode >= 7 else 0.002)
            );
            reason = (
                "Increase plating faster after repeated fatigue traces"
            );
        } else {
            weld = "Premium";
            reason = "Use premium welds after thickness revisions were exhausted";
        }
    } elif latest.failure_mode == "corrosion_thinning" {
        material = "Ah36" if material == "MildSteelA" else "Eh36";
        reason = "Move to a more corrosion-resistant steel grade";
    } elif latest.failure_mode in ["capsize", "capsize_ice"] {
        material = "Aluminum5083";
        reason = "Reduce shell mass to improve the stability margin";
    } elif latest.failure_mode == "fuel_exhaustion" {
        thickness = max(0.003, thickness - 0.001);
        reason = "Reduce shell mass and fuel demand";
    } else {
        thickness = min(0.060, thickness + 0.003);
        reason = "Increase structural margin for the unclassified failure";
    }

    return ConfigRevision(
        material=material,
        thickness_m=thickness,
        weld=weld,
        seal=seal,
        reasoning=reason
    );
}

def _spawn_voyage(
    origin: WaypointNode,
    design: VesselDesignNode,
    mission: MissionNode,
    attempt: int,
    total_distance_nm: float = 0.0
) -> VoyageWalker {
    return origin spawn VoyageWalker(
        loa_m=design.loa_m,
        beam_m=design.beam_m,
        depth_m=design.depth_m,
        draft_m=design.draft_m,
        block_coeff=design.block_coeff,
        waterplane_coeff=design.waterplane_coeff,
        material=design.material,
        thickness_m=design.thickness_m,
        weld=design.weld,
        seal=design.seal,
        max_power_kw=design.max_power_kw,
        fuel_capacity_kg=design.fuel_capacity_kg,
        sfc_g_per_kwh=design.sfc_g_per_kwh,
        propulsive_efficiency=design.propulsive_efficiency,
        hull_drag_coeff=design.hull_drag_coeff,
        route_id=origin.route_id,
        attempt=attempt,
        total_distance_nm=(
            total_distance_nm
            if total_distance_nm > 0.0
            else mission.total_distance_nm
        )
    );
}

def _summarize(result: VoyageResult) -> AttemptSummary {
    completion = (
        result.distance_nm / max(1.0, result.total_distance_nm)
    ) * 100.0;
    return AttemptSummary(
        attempt=result.attempt,
        survived=result.survived,
        cost_usd=result.cost_usd,
        material=result.material,
        thickness_m=result.thickness_mm / 1000.0,
        weld=result.weld,
        seal=result.seal,
        failure_mode=result.failure_mode,
        failure_zone=result.failure_zone,
        failure_reason=result.failure_reason,
        distance_pct=min(100.0, completion)
    );
}

def _update_best(
    mission: MissionNode,
    design: VesselDesignNode,
    result: VoyageResult
) {
    if (
        result.survived
        and (
            not mission.solved
            or result.cost_usd < mission.best_cost_usd
        )
    ) {
        mission.solved = True;
        mission.best_cost_usd = result.cost_usd;
        mission.best_material = design.material;
        mission.best_thickness_m = design.thickness_m;
        mission.best_weld = design.weld;
        mission.best_seal = design.seal;
    }
}

# ---------------------------------------------------------------------------
# SetupMission - construct the persistent graph
# ---------------------------------------------------------------------------

walker:pub SetupMission {
    has name: str,
        origin: dict[str, any],
        destination: dict[str, any],
        vessel: dict[str, any],
        waypoints: list[dict[str, any]] = [],
        distance_nm: float = 0.0,
        max_iterations: int = 20,
        reports: list[SetupMissionResult] = [];

    can setup with Root entry {
        if _find_mission(self.name) is not None {
            report SetupMissionResult(
                status="exists",
                mission=self.name,
                message="A mission with this name already exists"
            );
            disengage;
        }

        points: list[RoutePointInput] = [
            _point_from_dict(self.origin, "Origin")
        ];
        for raw_waypoint in self.waypoints {
            points.append(_point_from_dict(raw_waypoint, "Waypoint"));
        }
        points.append(_point_from_dict(self.destination, "Destination"));
        vessel = _vessel_from_dict(self.vessel);
        computed_distance = 0.0;
        for index in range(len(points) - 1) {
            computed_distance += _haversine_nm(
                points[index].lat_deg,
                points[index].lon_deg,
                points[index + 1].lat_deg,
                points[index + 1].lon_deg
            );
        }
        total_distance = (
            self.distance_nm if self.distance_nm > 0.0 else computed_distance
        );
        distance_scale = (
            total_distance / computed_distance
            if computed_distance > 0.0
            else 1.0
        );

        mission = (root ++> MissionNode(
            name=self.name,
            total_distance_nm=total_distance,
            max_iterations=max(1, self.max_iterations)
        ))[0] as MissionNode;
        _design = mission +>:HasDesign():+> VesselDesignNode(
            loa_m=vessel.loa_m,
            beam_m=vessel.beam_m,
            depth_m=vessel.depth_m,
            draft_m=vessel.draft_m,
            block_coeff=vessel.block_coeff,
            waterplane_coeff=vessel.waterplane_coeff,
            material=_valid_material(vessel.material),
            thickness_m=max(0.003, min(0.015, vessel.thickness_m)),
            weld=_valid_weld(vessel.weld),
            seal=_valid_seal(vessel.seal),
            max_power_kw=vessel.max_power_kw,
            fuel_capacity_kg=vessel.fuel_capacity_kg,
            sfc_g_per_kwh=vessel.sfc_g_per_kwh,
            propulsive_efficiency=vessel.propulsive_efficiency,
            hull_drag_coeff=vessel.hull_drag_coeff
        );

        previous: WaypointNode | None = None;
        for index in range(len(points)) {
            point = points[index];
            waypoint = WaypointNode(
                route_id=0,
                sequence=index,
                name=point.name,
                lat_deg=point.lat_deg,
                lon_deg=point.lon_deg,
                is_origin=index == 0,
                is_destination=index == len(points) - 1,
                hs_m=point.hs_m,
                tp_s=point.tp_s,
                jonswap_gamma=point.jonswap_gamma,
                encounter_angle_deg=point.encounter_angle_deg,
                water_temp_c=point.water_temp_c,
                salinity_ppt=point.salinity_ppt,
                ph=point.ph,
                wind_speed_ms=point.wind_speed_ms,
                slam_probability=point.slam_probability,
                condition_source=point.condition_source,
                navigable=point.navigable,
                condition_score=_point_condition_score(point)
            );

            if previous is None {
                _start = mission +>:StartsAt():+> waypoint;
            } else {
                prior = previous as WaypointNode;
                segment_distance = _haversine_nm(
                    prior.lat_deg, prior.lon_deg,
                    waypoint.lat_deg, waypoint.lon_deg
                ) * distance_scale;
                heading = _initial_bearing_deg(
                    prior.lat_deg, prior.lon_deg,
                    waypoint.lat_deg, waypoint.lon_deg
                );
                _segment = prior +>:RouteSegment(
                    sequence=index,
                    distance_nm=segment_distance,
                    heading_deg=heading,
                    duration_scale=point.duration_scale,
                    hs_m=point.hs_m,
                    tp_s=point.tp_s,
                    jonswap_gamma=point.jonswap_gamma,
                    encounter_angle_deg=point.encounter_angle_deg,
                    water_temp_c=point.water_temp_c,
                    salinity_ppt=point.salinity_ppt,
                    ph=point.ph,
                    wind_speed_ms=point.wind_speed_ms,
                    slam_probability=point.slam_probability
                ):+> waypoint;
            }
            previous = waypoint;
        }

        report SetupMissionResult(
            status="created",
            mission_id=jid(mission),
            mission=self.name,
            waypoints=len(points),
            segments=len(points) - 1,
            total_distance_nm=total_distance
        );
    }
}

# ---------------------------------------------------------------------------
# OptimizeFromPoints - route first, then cheapest surviving vessel
# The shared base keeps the HTTP and WebSocket implementations identical.
# ---------------------------------------------------------------------------

walker PointOptimizerCore {
    has origin: dict[str, any],
        destination: dict[str, any],
        name: str = "",
        route_iterations: int = 3,
        material_iterations: int = 10,
        convergence_min_attempts: int = 30,
        convergence_patience: int = 20,
        route_waypoints: list[dict[str, any]] = [],
        vessel: dict[str, any] = {},
        use_codex: bool = True,
        use_live_conditions: bool = True,
        save_simulation: bool = True,
        codex_model: str = "gpt-5.6-sol",
        codex_timeout_s: int = 120,
        condition_timeout_s: int = 12,
        stream_events: bool = False,
        reports: list[any] = [];

    can optimize_points with Root entry {
        origin_point = _point_from_dict(self.origin, "Point A");
        destination_point = _point_from_dict(
            self.destination, "Point B"
        );
        mission_name = (
            self.name
            if self.name
            else (
                f"{origin_point.name} to {destination_point.name} "
                f"({origin_point.lat_deg:.3f},{origin_point.lon_deg:.3f})"
            )
        );
        if (
            origin_point.lat_deg < -90.0
            or origin_point.lat_deg > 90.0
            or destination_point.lat_deg < -90.0
            or destination_point.lat_deg > 90.0
            or origin_point.lon_deg < -180.0
            or origin_point.lon_deg > 180.0
            or destination_point.lon_deg < -180.0
            or destination_point.lon_deg > 180.0
        ) {
            report PointOptimizationResult(
                status="invalid_input",
                mission=mission_name,
                message="Latitude must be -90..90 and longitude -180..180"
            );
            disengage;
        }
        if _find_mission(mission_name) is not None {
            report PointOptimizationResult(
                status="exists",
                mission=mission_name,
                message="A mission with this name already exists"
            );
            disengage;
        }

        direct_distance = _haversine_nm(
            origin_point.lat_deg, origin_point.lon_deg,
            destination_point.lat_deg, destination_point.lon_deg
        );
        if direct_distance < 0.05 {
            report PointOptimizationResult(
                status="invalid_input",
                mission=mission_name,
                message="Point A and point B must be different"
            );
            disengage;
        }

        vessel = _vessel_from_dict(self.vessel);
        if not "fuel_capacity_kg" in self.vessel {
            vessel.fuel_capacity_kg = max(
                2000.0, direct_distance * 3.0
            );
        }
        mission = (root ++> MissionNode(
            name=mission_name,
            total_distance_nm=direct_distance,
            max_iterations=max(1, self.material_iterations)
        ))[0] as MissionNode;
        design = (mission +>:HasDesign():+> VesselDesignNode(
            loa_m=vessel.loa_m,
            beam_m=vessel.beam_m,
            depth_m=vessel.depth_m,
            draft_m=vessel.draft_m,
            block_coeff=vessel.block_coeff,
            waterplane_coeff=vessel.waterplane_coeff,
            material="Eh40",
            thickness_m=0.060,
            weld="Premium",
            seal="Marine",
            max_power_kw=vessel.max_power_kw,
            fuel_capacity_kg=vessel.fuel_capacity_kg,
            sfc_g_per_kwh=vessel.sfc_g_per_kwh,
            propulsive_efficiency=vessel.propulsive_efficiency,
            hull_drag_coeff=vessel.hull_drag_coeff
        ))[0] as VesselDesignNode;
        if self.stream_events {
            report {
                "event_type": "session_started",
                "mission_id": jid(mission),
                "mission": mission.name,
                "origin": self.origin,
                "destination": self.destination,
                "route_iterations": max(1, min(8, self.route_iterations)),
                "material_iterations": max(
                    0, min(100, self.material_iterations)
                ),
                "agent_backend": (
                    "codex-cli" if self.use_codex else "local-rules"
                ),
                "codex_model": (
                    self.codex_model if self.use_codex else ""
                ),
                "configuration": _design_snapshot(design)
            };
        }

        route_count = max(1, min(8, self.route_iterations));
        route_history: list[RouteSummary] = [];
        fallbacks = 0;
        best_route_id = 0;
        best_route_score = 0.0;
        best_route_distance = 0.0;
        best_route_names: list[str] = [];
        best_certification: AttemptSummary | None = None;
        simulation_iterations: list[dict[str, any]] = [];

        for route_index in range(route_count) {
            route_id = route_index + 1;
            if self.stream_events {
                report {
                    "event_type": "progress",
                    "phase": "route_search",
                    "status": "planning",
                    "iteration": route_id,
                    "total_iterations": route_count,
                    "message": (
                        f"Planning route {route_id} of {route_count}"
                    )
                };
            }
            route_revision: RouteRevision;
            # One Codex call seeds the route search; Jac generates the remaining
            # alternatives locally so interactive demo runs stay fast.
            if route_index == 0 and self.route_waypoints {
                route_revision = RouteRevision(
                    waypoints=self.route_waypoints,
                    reasoning=(
                        "Land-mask-verified water route supplied by the "
                        "interactive globe planner"
                    )
                );
            } elif self.use_codex and route_index == 0 {
                try {
                    route_revision = _codex_route(
                        origin_point,
                        destination_point,
                        route_history,
                        direct_distance,
                        self.codex_model,
                        self.codex_timeout_s
                    );
                } except Exception {
                    fallbacks += 1;
                    route_revision = _fallback_route(
                        origin_point, destination_point,
                        route_id, direct_distance
                    );
                }
            } else {
                route_revision = _fallback_route(
                    origin_point, destination_point,
                    route_id, direct_distance
                );
            }
            points = _enriched_points(
                self.origin,
                self.destination,
                route_revision,
                self.use_live_conditions,
                self.condition_timeout_s
            );
            built = _build_route(mission, route_id, points);
            mission.route_attempts += 1;
            survived = False;
            failure_reason = "";
            route_certification: AttemptSummary | None = None;
            route_voyage: VoyageResult | None = None;

            if not built.navigable {
                failure_reason = (
                    "At least one intermediate waypoint has no marine data; "
                    "the proposed path likely crosses land"
                );
            } elif built.origin is None {
                failure_reason = "Route planner produced fewer than two points";
            } else {
                mission.attempts += 1;
                route_walker = _spawn_voyage(
                    built.origin,
                    design,
                    mission,
                    mission.attempts,
                    built.distance_nm
                );
                if route_walker.result is None {
                    failure_reason = (
                        "Voyage walker ended without a terminal result"
                    );
                } else {
                    route_result = route_walker.result;
                    route_voyage = route_result;
                    route_certification = _summarize(route_result);
                    survived = route_result.survived;
                    failure_reason = route_result.failure_reason;
                    _update_best(mission, design, route_result);
                }
            }

            summary = RouteSummary(
                route_id=route_id,
                survived=survived,
                navigable=built.navigable,
                condition_score=built.condition_score,
                distance_nm=built.distance_nm,
                condition_source=built.condition_source,
                failure_reason=failure_reason,
                waypoint_names=built.waypoint_names
            );
            route_history.append(summary);
            route_event: dict[str, any] = {
                "event_id": f"route-{route_id}",
                "phase": "route_search",
                "iteration": route_id,
                "route_id": route_id,
                "decision_reasoning": route_revision.reasoning,
                "condition_score": built.condition_score,
                "condition_source": built.condition_source,
                "route_distance_nm": built.distance_nm,
                "navigable": built.navigable,
                "configuration": _design_snapshot(design),
                "path": _point_snapshots(points),
                "result": _voyage_snapshot(
                    route_voyage,
                    points,
                    built.distance_nm,
                    failure_reason
                )
            };
            simulation_iterations.append(route_event);
            if self.stream_events {
                report {
                    "event_type": "iteration",
                    "phase": "route_search",
                    "completed": route_id,
                    "total": route_count,
                    "iteration": route_event
                };
            }
            _evaluation = mission +>:EvaluatedRoute():+> RouteEvaluation(
                route_id=route_id,
                survived=survived,
                navigable=built.navigable,
                condition_score=built.condition_score,
                distance_nm=built.distance_nm,
                condition_source=built.condition_source,
                reasoning=route_revision.reasoning,
                failure_reason=failure_reason,
                waypoint_names=built.waypoint_names
            );

            if (
                survived
                and (
                    best_route_id == 0
                    or built.condition_score < best_route_score
                )
            ) {
                best_route_id = route_id;
                best_route_score = built.condition_score;
                best_route_distance = built.distance_nm;
                best_route_names = built.waypoint_names;
                best_certification = route_certification;
            }
        }

        if best_route_id == 0 {
            simulation_file = "";
            simulation_error = "";
            if self.save_simulation {
                try {
                    simulation_file = _save_simulation(
                        mission,
                        origin_point,
                        destination_point,
                        simulation_iterations,
                        [],
                        "no_successful_route",
                        self.use_codex,
                        self.codex_model
                    );
                } except Exception as error {
                    simulation_error = str(error);
                }
            }
            if self.stream_events {
                report {
                    "event_type": "complete",
                    "status": "no_successful_route",
                    "mission_id": jid(mission),
                    "mission": mission.name,
                    "fallbacks_used": fallbacks,
                    "simulation_file": simulation_file,
                    "simulation_error": simulation_error,
                    "message": (
                        "No route candidate reached point B with the "
                        "certification vessel"
                    )
                };
            }
            report PointOptimizationResult(
                status="no_successful_route",
                mission_id=jid(mission),
                mission=mission.name,
                agent_backend=(
                    "codex-cli" if self.use_codex else "local-rules"
                ),
                codex_model=self.codex_model if self.use_codex else "",
                route_attempts=len(route_history),
                fallbacks_used=fallbacks,
                routes=route_history,
                simulation_file=simulation_file,
                simulation_error=simulation_error,
                message=(
                    "No route candidate reached point B with the "
                    "certification vessel; material optimization was not run"
                )
            );
            disengage;
        }

        mission.best_route_id = best_route_id;
        mission.best_route_score = best_route_score;
        mission.route_locked = True;
        mission.total_distance_nm = best_route_distance;
        if self.stream_events {
            report {
                "event_type": "route_locked",
                "route_id": best_route_id,
                "condition_score": best_route_score,
                "distance_nm": best_route_distance,
                "waypoints": best_route_names,
                "message": (
                    f"Route {best_route_id} survived and is now locked"
                )
            };
        }
        best_origin = _get_origin(mission, best_route_id);
        material_history: list[AttemptSummary] = [];
        tried_configurations: list[str] = [];
        material_count = max(0, min(100, self.material_iterations));
        minimum_attempts = min(
            material_count,
            max(1, self.convergence_min_attempts)
        );
        patience = max(1, self.convergence_patience);
        attempts_without_improvement = 0;

        if best_origin is not None {
            # Begin optimization from a genuinely exploratory vessel instead of
            # exposing the strong route-certification vessel as attempt one.
            design.material = random.choice([
                "MildSteelA", "MildSteelE", "Aluminum5083"
            ]);
            design.thickness_m = random.uniform(0.003, 0.006);
            design.weld = random.choice(["Economy", "Standard"]);
            design.seal = random.choice(["Economy", "Commercial"]);
            design.revision += 1;
            for _material_index in range(material_count) {
                if self.stream_events {
                    report {
                        "event_type": "progress",
                        "phase": "material_search",
                        "status": "planning",
                        "iteration": _material_index + 1,
                        "total_iterations": material_count,
                        "message": (
                            "Choosing material configuration "
                            f"{_material_index + 1} of {material_count}"
                        )
                    };
                }
                config_revision: ConfigRevision;
                # Record the random baseline first. Let Codex react to that
                # trace once, then let Jac's persistent history drive revisions.
                # the persistent Jac graph/history drive cheap local revisions.
                if _material_index == 0 {
                    config_revision = ConfigRevision(
                        material=design.material,
                        thickness_m=design.thickness_m,
                        weld=design.weld,
                        seal=design.seal,
                        reasoning="Random exploratory baseline"
                    );
                } elif self.use_codex and _material_index == 1 {
                    try {
                        config_revision = _codex_revision(
                            material_history,
                            design,
                            mission.best_cost_usd,
                            self.codex_model,
                            self.codex_timeout_s
                        );
                    } except Exception {
                        fallbacks += 1;
                        config_revision = _rule_revision(
                            material_history, design
                        );
                    }
                } else {
                    config_revision = _rule_revision(
                        material_history, design
                    );
                }
                _apply_revision(design, config_revision);
                configuration_key = _configuration_key(design);
                if (
                    configuration_key in tried_configurations
                    and _material_index == 1
                ) {
                    config_revision = _rule_revision(
                        material_history, design
                    );
                    _apply_revision(design, config_revision);
                    configuration_key = _configuration_key(design);
                }
                if configuration_key in tried_configurations {
                    # Never terminate merely because a rule revisited a prior
                    # design. Nudge thickness to create a nearby cost probe.
                    probe_offset = 0.0001 * (
                        (_material_index % 9) + 1
                    );
                    probe_thickness = design.thickness_m + probe_offset;
                    if probe_thickness > 0.060 {
                        probe_thickness = design.thickness_m - probe_offset;
                    }
                    config_revision = ConfigRevision(
                        material=design.material,
                        thickness_m=max(0.003, probe_thickness),
                        weld=design.weld,
                        seal=design.seal,
                        reasoning=(
                            "Probe a nearby untested thickness instead of "
                            "stopping on a repeated configuration"
                        )
                    );
                    _apply_revision(design, config_revision);
                    configuration_key = _configuration_key(design);
                }
                tried_configurations.append(configuration_key);
                mission.attempts += 1;
                material_walker = _spawn_voyage(
                    best_origin,
                    design,
                    mission,
                    mission.attempts,
                    best_route_distance
                );
                if material_walker.result is None {
                    break;
                }
                material_result = material_walker.result;
                material_summary = _summarize(material_result);
                material_history.append(material_summary);
                previous_best_cost = mission.best_cost_usd;
                previously_solved = mission.solved;
                _update_best(mission, design, material_result);
                if mission.solved {
                    if (
                        not previously_solved
                        or mission.best_cost_usd < previous_best_cost
                    ) {
                        attempts_without_improvement = 0;
                    } else {
                        attempts_without_improvement += 1;
                    }
                }
                locked_points: list[RoutePointInput] = [];
                current_waypoint: WaypointNode | None = best_origin;
                while current_waypoint is not None {
                    locked_points.append(RoutePointInput(
                        name=current_waypoint.name,
                        lat_deg=current_waypoint.lat_deg,
                        lon_deg=current_waypoint.lon_deg,
                        hs_m=current_waypoint.hs_m,
                        tp_s=current_waypoint.tp_s,
                        jonswap_gamma=current_waypoint.jonswap_gamma,
                        encounter_angle_deg=(
                            current_waypoint.encounter_angle_deg
                        ),
                        water_temp_c=current_waypoint.water_temp_c,
                        salinity_ppt=current_waypoint.salinity_ppt,
                        ph=current_waypoint.ph,
                        wind_speed_ms=current_waypoint.wind_speed_ms,
                        slam_probability=current_waypoint.slam_probability,
                        condition_source=current_waypoint.condition_source,
                        navigable=current_waypoint.navigable
                    ));
                    next_locked = [
                        current_waypoint ->:RouteSegment:->
                    ];
                    current_waypoint = (
                        next_locked[0] if next_locked else None
                    );
                }
                material_event: dict[str, any] = {
                    "event_id": (
                        f"material-{_material_index + 1}-"
                        f"attempt-{material_result.attempt}"
                    ),
                    "phase": "material_search",
                    "iteration": _material_index + 1,
                    "route_id": best_route_id,
                    "decision_reasoning": config_revision.reasoning,
                    "condition_score": best_route_score,
                    "condition_source": (
                        route_history[best_route_id - 1].condition_source
                    ),
                    "route_distance_nm": best_route_distance,
                    "navigable": True,
                    "configuration": _design_snapshot(design),
                    "path": _point_snapshots(locked_points),
                    "result": _voyage_snapshot(
                        material_result,
                        locked_points,
                        best_route_distance,
                        material_result.failure_reason
                    )
                };
                simulation_iterations.append(material_event);
                if self.stream_events {
                    report {
                        "event_type": "iteration",
                        "phase": "material_search",
                        "completed": _material_index + 1,
                        "total": material_count,
                        "iteration": material_event
                    };
                }
                if (
                    len(material_history) >= minimum_attempts
                    and mission.solved
                    and attempts_without_improvement >= patience
                ) {
                    if self.stream_events {
                        report {
                            "event_type": "progress",
                            "phase": "material_search",
                            "status": "converged",
                            "iteration": len(material_history),
                            "total_iterations": material_count,
                            "message": (
                                "Cost search converged after "
                                f"{attempts_without_improvement} attempts "
                                "without a cheaper successful design"
                            )
                        };
                    }
                    break;
                }
            }
        }

        simulation_file = "";
        simulation_error = "";
        if self.save_simulation {
            try {
                simulation_file = _save_simulation(
                    mission,
                    origin_point,
                    destination_point,
                    simulation_iterations,
                    best_route_names,
                    "solved",
                    self.use_codex,
                    self.codex_model
                );
            } except Exception as error {
                simulation_error = str(error);
            }
        }
        if self.stream_events {
            report {
                "event_type": "complete",
                "status": "solved",
                "mission_id": jid(mission),
                "mission": mission.name,
                "fallbacks_used": fallbacks,
                "simulation_file": simulation_file,
                "simulation_error": simulation_error,
                "best": {
                    "route_id": best_route_id,
                    "route_score": best_route_score,
                    "route_distance_nm": best_route_distance,
                    "route_waypoints": best_route_names,
                    "cost_usd": mission.best_cost_usd,
                    "material": mission.best_material,
                    "thickness_mm": (
                        mission.best_thickness_m * 1000.0
                    ),
                    "weld": mission.best_weld,
                    "seal": mission.best_seal
                },
                "message": (
                    "Best successful route and cheapest survivor selected"
                )
            };
        }
        report PointOptimizationResult(
            status="solved",
            mission_id=jid(mission),
            mission=mission.name,
            agent_backend=(
                "codex-cli" if self.use_codex else "local-rules"
            ),
            codex_model=self.codex_model if self.use_codex else "",
            route_attempts=len(route_history),
            material_attempts=max(0, len(material_history) - 1),
            fallbacks_used=fallbacks,
            best_route_id=best_route_id,
            best_route_score=best_route_score,
            best_route_distance_nm=best_route_distance,
            best_route_waypoints=best_route_names,
            best_cost_usd=mission.best_cost_usd,
            best_material=mission.best_material,
            best_thickness_mm=mission.best_thickness_m * 1000.0,
            best_weld=mission.best_weld,
            best_seal=mission.best_seal,
            routes=route_history,
            material_history=material_history,
            simulation_file=simulation_file,
            simulation_error=simulation_error,
            message=(
                "Best successful route locked before cheapest surviving "
                "vessel selection"
            )
        );
    }
}

walker:pub OptimizeFromPoints(PointOptimizerCore) {
}

@restspec(protocol=APIProtocol.WEBSOCKET)
async walker:pub StreamOptimizeFromPoints(PointOptimizerCore) {
    has stream_events: bool = True;
}

# ---------------------------------------------------------------------------
# RunVoyage - one walker, one persisted attempt
# ---------------------------------------------------------------------------

walker:pub RunVoyage {
    has mission_name: str,
        reports: list[VoyageResult] = [];

    can run with Root entry {
        mission = _find_mission(self.mission_name);
        if mission is None {
            report VoyageResult(
                failure_mode="mission_not_found",
                failure_reason=f"Mission '{self.mission_name}' does not exist"
            );
            disengage;
        }
        design = _get_design(mission);
        origin = _get_origin(mission);
        if design is None or origin is None {
            report VoyageResult(
                failure_mode="invalid_graph",
                failure_reason="Mission is missing its design or origin"
            );
            disengage;
        }

        mission.attempts += 1;
        attempt_walker = _spawn_voyage(
            origin, design, mission, mission.attempts
        );
        if attempt_walker.result is None {
            report VoyageResult(
                attempt=mission.attempts,
                failure_mode="walker_error",
                failure_reason="Voyage walker ended without a terminal result"
            );
            disengage;
        }
        result = attempt_walker.result;
        _update_best(mission, design, result);
        report result;
    }
}

# ---------------------------------------------------------------------------
# RunOptimizer - graph memory drives each subsequent walker
# ---------------------------------------------------------------------------

walker:pub RunOptimizer {
    has mission_name: str,
        iterations: int = 0,
        use_codex: bool = True,
        codex_model: str = "gpt-5.6-sol",
        codex_timeout_s: int = 120,
        reports: list[OptimizerResult] = [];

    can optimize with Root entry {
        mission = _find_mission(self.mission_name);
        if mission is None {
            report OptimizerResult(
                status="not_found",
                mission=self.mission_name,
                message="Mission does not exist"
            );
            disengage;
        }
        design = _get_design(mission);
        origin = _get_origin(mission);
        if design is None or origin is None {
            report OptimizerResult(
                status="invalid_graph",
                mission=self.mission_name,
                message="Mission is missing its design or origin"
            );
            disengage;
        }

        run_count = (
            self.iterations if self.iterations > 0 else mission.max_iterations
        );
        history: list[AttemptSummary] = [];
        survivors = 0;
        fallbacks = 0;

        for _iteration in range(run_count) {
            mission.attempts += 1;
            attempt_walker = _spawn_voyage(
                origin, design, mission, mission.attempts
            );
            if attempt_walker.result is None {
                break;
            }
            result = attempt_walker.result;
            summary = _summarize(result);
            history.append(summary);

            if result.survived {
                survivors += 1;
            }
            _update_best(mission, design, result);

            if len(history) < run_count {
                revision: ConfigRevision;
                if self.use_codex {
                    try {
                        revision = _codex_revision(
                            history,
                            design,
                            mission.best_cost_usd,
                            self.codex_model,
                            self.codex_timeout_s
                        );
                    } except Exception {
                        fallbacks += 1;
                        revision = _rule_revision(history, design);
                    }
                } else {
                    revision = _rule_revision(history, design);
                }
                _apply_revision(design, revision);
            }
        }

        report OptimizerResult(
            status="solved" if mission.solved else "no_survivor",
            mission=mission.name,
            agent_backend=(
                "codex-cli" if self.use_codex else "local-rules"
            ),
            codex_model=self.codex_model if self.use_codex else "",
            fallbacks_used=fallbacks,
            attempts_run=len(history),
            survivors_found=survivors,
            best_cost_usd=mission.best_cost_usd,
            best_material=mission.best_material,
            best_thickness_mm=mission.best_thickness_m * 1000.0,
            best_weld=mission.best_weld,
            best_seal=mission.best_seal,
            history=history,
            message=(
                "Cheapest survivor among attempted configurations"
                if mission.solved
                else "No attempted configuration reached the destination"
            )
        );
    }
}

# ---------------------------------------------------------------------------
# GetMission - inspect persistent route and trace knowledge
# ---------------------------------------------------------------------------

walker:pub GetMission {
    has mission_name: str,
        reports: list[MissionView] = [];

    can inspect with Root entry {
        mission = _find_mission(self.mission_name);
        if mission is None {
            report MissionView(
                found=False,
                name=self.mission_name,
                message="Mission does not exist"
            );
            disengage;
        }
        design = _get_design(mission);
        current = _get_origin(mission);
        waypoint_views: list[WaypointView] = [];
        failure_views: list[FailureView] = [];

        while current is not None {
            failures = [current ->:FailedHere:->];
            successes = [current ->:CompletedHere:->];
            waypoint_views.append(WaypointView(
                id=jid(current),
                route_id=current.route_id,
                sequence=current.sequence,
                name=current.name,
                lat_deg=current.lat_deg,
                lon_deg=current.lon_deg,
                is_origin=current.is_origin,
                is_destination=current.is_destination,
                failures=len(failures),
                successes=len(successes),
                hs_m=current.hs_m,
                tp_s=current.tp_s,
                wind_speed_ms=current.wind_speed_ms,
                water_temp_c=current.water_temp_c,
                condition_source=current.condition_source,
                condition_score=current.condition_score
            ));
            for trace in failures {
                failure_views.append(FailureView(
                    attempt=trace.attempt,
                    waypoint=current.name,
                    mode=trace.failure_mode,
                    zone=trace.failure_zone,
                    reason=trace.failure_reason,
                    distance_pct=(
                        trace.distance_completed_nm
                        / max(1.0, trace.total_distance_nm)
                    ) * 100.0,
                    material=trace.material,
                    thickness_mm=trace.thickness_m * 1000.0,
                    weld=trace.weld,
                    seal=trace.seal
                ));
            }
            next_waypoints = [current ->:RouteSegment:->];
            current = next_waypoints[0] if next_waypoints else None;
        }

        report MissionView(
            found=True,
            mission_id=jid(mission),
            name=mission.name,
            total_distance_nm=mission.total_distance_nm,
            attempts=mission.attempts,
            solved=mission.solved,
            best_cost_usd=mission.best_cost_usd,
            best_route_id=mission.best_route_id,
            best_route_score=mission.best_route_score,
            current_material=design.material if design is not None else "",
            current_thickness_mm=(
                design.thickness_m * 1000.0 if design is not None else 0.0
            ),
            current_weld=design.weld if design is not None else "",
            current_seal=design.seal if design is not None else "",
            waypoints=waypoint_views,
            failures=failure_views
        );
    }
}

def:pub MissionGraphDot(mission_name: str) -> str {
    mission = _find_mission(mission_name);
    return printgraph(mission) if mission is not None else "";
}

# ---------------------------------------------------------------------------
# End-to-end graph tests (`jac run` ignores test blocks)
# ---------------------------------------------------------------------------

test "voyage walker leaves one persistent terminal trace" {
    setup = root spawn SetupMission(
        name="test_graph_voyage",
        origin={
            "name": "Test Origin",
            "lat_deg": 36.85,
            "lon_deg": -76.29,
            "hs_m": 0.5,
            "tp_s": 8.0,
            "water_temp_c": 20.0,
            "wind_speed_ms": 3.0
        },
        destination={
            "name": "Test Destination",
            "lat_deg": 36.90,
            "lon_deg": -76.20,
            "hs_m": 0.5,
            "tp_s": 8.0,
            "water_temp_c": 20.0,
            "wind_speed_ms": 3.0
        },
        vessel={
            "material": "Eh36",
            "thickness_m": 0.012,
            "weld": "Premium",
            "seal": "Marine",
            "fuel_capacity_kg": 5000.0
        },
        distance_nm=5.0,
        max_iterations=3
    );
    assert len(setup.reports) == 1;
    assert setup.reports[0].status == "created";

    mission = _find_mission("test_graph_voyage");
    assert mission is not None;
    origin = _get_origin(mission);
    assert origin is not None;
    segments = [edge origin ->:RouteSegment:->];
    destinations = [origin ->:RouteSegment:->];
    assert len(segments) == 1;
    assert len(destinations) == 1;
    assert abs(segments[0].distance_nm - 5.0) < 0.001;

    run = root spawn RunVoyage(mission_name="test_graph_voyage");
    assert len(run.reports) == 1;
    assert run.reports[0].attempt == 1;

    terminal = destinations[0];
    failure_count = len([terminal ->:FailedHere:->]);
    success_count = len([terminal ->:CompletedHere:->]);
    assert failure_count + success_count == 1;
    assert mission.attempts == 1;
}

test "offline optimizer launches repeated graph walkers" {
    run = root spawn RunOptimizer(
        mission_name="test_graph_voyage",
        iterations=3,
        use_codex=False
    );
    assert len(run.reports) == 1;
    assert run.reports[0].attempts_run == 3;
    assert len(run.reports[0].history) == 3;

    mission = _find_mission("test_graph_voyage");
    assert mission is not None;
    assert mission.attempts == 4;
    view = root spawn GetMission(mission_name="test_graph_voyage");
    assert len(view.reports) == 1;
    assert view.reports[0].found;
    assert len(view.reports[0].waypoints) == 2;
}

test "failed walker persists diagnosis at terminal waypoint" {
    setup = root spawn SetupMission(
        name="test_failure_trace",
        origin={
            "name": "Failure Origin",
            "lat_deg": 40.0,
            "lon_deg": -70.0
        },
        destination={
            "name": "Failure Point",
            "lat_deg": 39.0,
            "lon_deg": -68.0,
            "hs_m": 8.0,
            "tp_s": 7.0,
            "wind_speed_ms": 25.0,
            "slam_probability": 0.9
        },
        vessel={
            "material": "MildSteelA",
            "thickness_m": 0.003,
            "weld": "Economy",
            "seal": "Economy",
            "fuel_capacity_kg": 1.0
        },
        distance_nm=100.0
    );
    assert setup.reports[0].status == "created";

    run = root spawn RunVoyage(mission_name="test_failure_trace");
    assert len(run.reports) == 1;
    assert not run.reports[0].survived;
    assert run.reports[0].failure_mode != "";

    mission = _find_mission("test_failure_trace");
    assert mission is not None;
    origin = _get_origin(mission);
    assert origin is not None;
    terminal = [origin ->:RouteSegment:->][0];
    traces = [terminal ->:FailedHere:->];
    assert len(traces) == 1;
    assert traces[0].failure_mode == run.reports[0].failure_mode;
    assert traces[0].attempt == 1;
}

test "two-point workflow locks route before material optimization" {
    run = root spawn OptimizeFromPoints(
        name="test_two_point_optimizer",
        origin={
            "name": "Point A",
            "lat_deg": 36.85,
            "lon_deg": -76.29
        },
        destination={
            "name": "Point B",
            "lat_deg": 36.90,
            "lon_deg": -76.20
        },
        route_iterations=2,
        material_iterations=2,
        use_codex=False,
        use_live_conditions=False,
        save_simulation=False
    );
    assert len(run.reports) == 1;
    result = run.reports[0] as PointOptimizationResult;
    assert result.status == "solved";
    assert result.route_attempts == 2;
    assert result.best_route_id > 0;
    assert len(result.best_route_waypoints) == 2;
    assert result.material_attempts == 2;
    assert result.best_cost_usd > 0.0;

    mission = _find_mission("test_two_point_optimizer");
    assert mission is not None;
    assert mission.route_locked;
    assert mission.best_route_id == result.best_route_id;
    evaluations = [mission ->:EvaluatedRoute:->];
    assert len(evaluations) == 2;
}
