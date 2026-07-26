"""Environmental data and simulation-trace services for SeaForge."""

import json;
import math;
import os;
import re;
import urllib.parse as urlparse;
import urllib.request as urlrequest;
import from datetime { datetime, timezone }

def _float_value(value: any, fallback: float) -> float {
    if isinstance(value, int) or isinstance(value, float) {
        return float(value);
    }
    return fallback;
}

def _round3(value: float) -> float {
    return math.floor(value * 1000.0 + 0.5) / 1000.0;
}

def _estimated_condition(
    lat: float, lon: float
) -> dict[str, any] {
    phase: float = math.radians(lat * 2.7 + lon * 1.3);
    hs: float = 1.1 + 2.4 * math.fabs(math.sin(phase));
    tp: float = (
        6.5
        + 4.5 * math.fabs(math.cos(math.radians(lon - lat)))
    );
    wind: float = (
        5.0
        + 11.0 * math.fabs(
            math.sin(math.radians(lat + lon * 0.7))
        )
    );
    temp: float = max(
        -1.5, min(29.0, 27.0 - math.fabs(lat) * 0.43)
    );
    wave_direction: float = (
        lon * 3.1 - lat * 1.7 + 720.0
    ) % 360.0;
    return {
        "hs_m": _round3(hs),
        "tp_s": _round3(tp),
        "wave_direction_deg": _round3(wave_direction),
        "water_temp_c": _round3(temp),
        "wind_speed_ms": _round3(wind),
        "salinity_ppt": 35.0,
        "ph": 8.1,
        "jonswap_gamma": 3.3,
        "slam_probability": _round3(
            min(0.85, 0.08 + hs * 0.08)
        ),
        "condition_source": "estimated",
        "navigable": True
    };
}

def _fetch_json(url: str, timeout_s: int) -> any {
    request = urlrequest.Request(
        url,
        headers={"User-Agent": "SeaForge-v3-hackathon/1.0"}
    );
    response = urlrequest.urlopen(
        request, timeout=float(timeout_s)
    );
    try {
        body = response.read().decode("utf-8") as str;
    } finally {
        response.close();
    }
    return json.loads(body);
}

def _as_location_list(payload: any) -> list[dict[str, any]] {
    locations: list[dict[str, any]] = [];
    if isinstance(payload, list) {
        for item in payload {
            if isinstance(item, dict) {
                locations.append(item as dict[str, any]);
            }
        }
    } elif isinstance(payload, dict) {
        locations.append(payload as dict[str, any]);
    }
    return locations;
}

def enrich_route_points(
    points_json: str,
    use_live_conditions: bool = True,
    timeout_s: int = 12
) -> str {
    raw = json.loads(points_json);
    if not isinstance(raw, list) {
        raise ValueError("route points must be a JSON list");
    }
    points: list[dict[str, any]] = [];
    for item in raw {
        if isinstance(item, dict) {
            points.append(item as dict[str, any]);
        }
    }
    output: list[dict[str, any]] = [];
    for index in range(len(points)) {
        point = points[index];
        lat = _float_value(point.get("lat_deg"), 0.0);
        lon = _float_value(point.get("lon_deg"), 0.0);
        enriched = _estimated_condition(lat, lon);
        enriched["name"] = str(
            point.get("name", f"Waypoint {index + 1}")
        );
        enriched["lat_deg"] = lat;
        enriched["lon_deg"] = lon;
        output.append(enriched);
    }

    if not use_live_conditions or not output {
        return json.dumps(output);
    }

    latitudes = ",".join(
        [str(point["lat_deg"]) for point in output]
    );
    longitudes = ",".join(
        [str(point["lon_deg"]) for point in output]
    );
    marine_query = urlparse.urlencode(
        {
            "latitude": latitudes,
            "longitude": longitudes,
            "current": (
                "wave_height,wave_direction,wave_period,"
                "sea_surface_temperature"
            )
        },
        safe=","
    );
    weather_query = urlparse.urlencode(
        {
            "latitude": latitudes,
            "longitude": longitudes,
            "current": "wind_speed_10m",
            "wind_speed_unit": "ms"
        },
        safe=","
    );
    marine: list[dict[str, any]];
    try {
        marine = _as_location_list(_fetch_json(
            (
                "https://marine-api.open-meteo.com/v1/marine?"
                + marine_query
            ),
            max(2, min(timeout_s, 30))
        ));
    } except Exception {
        return json.dumps(output);
    }
    weather: list[dict[str, any]] = [];
    try {
        weather = _as_location_list(_fetch_json(
            (
                "https://api.open-meteo.com/v1/forecast?"
                + weather_query
            ),
            max(2, min(timeout_s, 30))
        ));
    } except Exception {
        weather = [];
    }

    for index in range(len(output)) {
        enriched = output[index];
        if index >= len(marine) {
            continue;
        }
        marine_current_raw = marine[index].get("current");
        if not isinstance(marine_current_raw, dict) {
            enriched["navigable"] = False;
            enriched["condition_source"] = "live-land-or-unavailable";
            continue;
        }
        marine_current = marine_current_raw as dict[str, any];
        wave_height = marine_current.get("wave_height");
        if not (
            isinstance(wave_height, int)
            or isinstance(wave_height, float)
        ) {
            enriched["navigable"] = False;
            enriched["condition_source"] = "live-land-or-unavailable";
            continue;
        }
        enriched["hs_m"] = float(wave_height);
        enriched["tp_s"] = _float_value(
            marine_current.get("wave_period"), 8.0
        );
        enriched["wave_direction_deg"] = _float_value(
            marine_current.get("wave_direction"), 0.0
        );
        enriched["water_temp_c"] = _float_value(
            marine_current.get("sea_surface_temperature"), 15.0
        );
        if index < len(weather) {
            weather_current_raw = weather[index].get("current");
            if isinstance(weather_current_raw, dict) {
                weather_current = (
                    weather_current_raw as dict[str, any]
                );
                enriched["wind_speed_ms"] = _float_value(
                    weather_current.get("wind_speed_10m"),
                    _float_value(enriched.get("wind_speed_ms"), 10.0)
                );
            }
        }
        enriched["slam_probability"] = min(
            0.95,
            0.08 + _float_value(enriched.get("hs_m"), 2.5) * 0.08
        );
        enriched["condition_source"] = "open-meteo-current";
        enriched["navigable"] = True;
    }
    return json.dumps(output);
}

def _safe_slug(value: str) -> str {
    slug = re.sub(r"[^a-z0-9]+", "-", value.lower()).strip("-");
    return (slug or "simulation")[:80];
}

def _dict_value(value: any) -> dict[str, any] {
    return value as dict[str, any] if isinstance(value, dict) else {};
}

def _dict_list(value: any) -> list[dict[str, any]] {
    items: list[dict[str, any]] = [];
    if isinstance(value, list) {
        for item in value {
            if isinstance(item, dict) {
                items.append(item as dict[str, any]);
            }
        }
    }
    return items;
}

def _merged(
    base: dict[str, any], additions: dict[str, any]
) -> dict[str, any] {
    result = base.copy();
    result.update(additions);
    return result;
}

def _build_trace_graph(
    trace: dict[str, any]
) -> dict[str, any] {
    mission_data = _dict_value(trace.get("mission"));
    mission_id = str(mission_data.get("id", "mission"));
    mission_node = _merged(mission_data, {
        "id": f"mission:{mission_id}",
        "kind": "mission"
    });
    nodes: list[dict[str, any]] = [mission_node];
    edges: list[dict[str, any]] = [];
    route_node_ids: set[str] = set();
    events = _dict_list(trace.get("iterations"));

    for event_index in range(len(events)) {
        raw_event = events[event_index];
        event_id = str(raw_event.get(
            "event_id", f"iteration-{event_index + 1}"
        ));
        route_id = int(_float_value(raw_event.get("route_id"), 0.0));
        route_node_id = f"route:{route_id}";
        path_points = _dict_list(raw_event.get("path"));

        if route_node_id not in route_node_ids {
            route_node_ids.add(route_node_id);
            nodes.append({
                "id": route_node_id,
                "kind": "route",
                "route_id": route_id,
                "condition_score": raw_event.get(
                    "condition_score", 0.0
                ),
                "distance_nm": raw_event.get(
                    "route_distance_nm", 0.0
                )
            });
            edges.append({
                "source": f"mission:{mission_id}",
                "target": route_node_id,
                "kind": "HAS_ROUTE"
            });
            previous_waypoint_id = "";
            for point_index in range(len(path_points)) {
                point = path_points[point_index];
                waypoint_id = (
                    f"route:{route_id}:waypoint:{point_index}"
                );
                nodes.append(_merged(point, {
                    "id": waypoint_id,
                    "kind": "waypoint",
                    "route_id": route_id,
                    "sequence": point_index
                }));
                if previous_waypoint_id {
                    edges.append({
                        "source": previous_waypoint_id,
                        "target": waypoint_id,
                        "kind": "ROUTE_SEGMENT"
                    });
                } else {
                    edges.append({
                        "source": route_node_id,
                        "target": waypoint_id,
                        "kind": "STARTS_AT"
                    });
                }
                previous_waypoint_id = waypoint_id;
            }
        }

        config_data = _dict_value(raw_event.get("configuration"));
        config_node_id = f"configuration:{event_id}";
        nodes.append(_merged(config_data, {
            "id": config_node_id,
            "kind": "vessel_configuration",
            "event_id": event_id
        }));
        edges.append({
            "source": config_node_id,
            "target": route_node_id,
            "kind": "TESTED_ON"
        });

        result_data = _dict_value(raw_event.get("result"));
        outcome_node_id = f"outcome:{event_id}";
        nodes.append(_merged(result_data, {
            "id": outcome_node_id,
            "kind": "voyage_outcome",
            "event_id": event_id
        }));
        edges.append({
            "source": config_node_id,
            "target": outcome_node_id,
            "kind": "PRODUCED"
        });
        terminal_sequence = result_data.get("terminal_sequence");
        if (
            isinstance(terminal_sequence, int)
            and terminal_sequence >= 0
        ) {
            edges.append({
                "source": outcome_node_id,
                "target": (
                    f"route:{route_id}:waypoint:{terminal_sequence}"
                ),
                "kind": "TERMINATED_AT"
            });
        }
    }
    return {"nodes": nodes, "edges": edges};
}

def _add_improvement_deltas(
    iterations: list[dict[str, any]]
) -> list[dict[str, any]] {
    prior_route_score: float | None = None;
    best_success_cost: float | None = None;
    enriched: list[dict[str, any]] = [];
    for raw_event in iterations {
        event = raw_event.copy();
        phase = str(event.get("phase", ""));
        result_data = _dict_value(event.get("result"));
        improvement: dict[str, any] = {};
        if phase == "route_search" {
            score_raw = event.get("condition_score");
            if (
                isinstance(score_raw, int)
                or isinstance(score_raw, float)
            ) {
                score = float(score_raw);
                improvement[
                    "condition_score_delta_vs_previous"
                ] = (
                    None
                    if prior_route_score is None
                    else score - prior_route_score
                );
                prior_route_score = score;
            }
        }
        if bool(result_data.get("survived", False)) {
            cost_raw = result_data.get("cost_usd");
            if (
                (
                    isinstance(cost_raw, int)
                    or isinstance(cost_raw, float)
                )
                and float(cost_raw) > 0.0
            ) {
                cost = float(cost_raw);
                improvement["cost_delta_vs_best_survivor"] = (
                    None
                    if best_success_cost is None
                    else cost - best_success_cost
                );
                if (
                    best_success_cost is None
                    or cost < best_success_cost
                ) {
                    best_success_cost = cost;
                }
                improvement[
                    "best_survivor_cost_after_iteration"
                ] = best_success_cost;
            }
        }
        event["improvement"] = improvement;
        enriched.append(event);
    }
    return enriched;
}

def save_simulation_trace(trace_json: str) -> str {
    raw = json.loads(trace_json);
    if not isinstance(raw, dict) {
        raise ValueError("simulation trace must be a JSON object");
    }
    parsed = raw as dict[str, any];
    mission_data = _dict_value(parsed.get("mission"));
    mission_name = str(mission_data.get("name", "simulation"));
    mission_id = _safe_slug(
        str(mission_data.get("id", "unknown"))
    )[:16];
    iterations = _dict_list(parsed.get("iterations"));
    parsed["schema_version"] = "seaforge.simulation.v1";
    parsed["generated_at_utc"] = datetime.now(
        timezone.utc
    ).isoformat();
    parsed["iterations"] = _add_improvement_deltas(iterations);
    parsed["graph"] = _build_trace_graph(parsed);

    simulations_dir = os.path.join(os.getcwd(), "simulations");
    os.makedirs(simulations_dir, exist_ok=True);
    filename = f"{_safe_slug(mission_name)}-{mission_id}.json";
    destination = os.path.join(simulations_dir, filename);
    temporary = os.path.join(simulations_dir, f".{filename}.tmp");
    with open(temporary, "w", encoding="utf-8") as output_file {
        _ = output_file.write(
            json.dumps(parsed, indent=2, sort_keys=False) + "\n"
        );
    }
    os.replace(temporary, destination);
    return os.path.join("simulations", filename);
}

def:pub list_simulations() -> list[dict[str, any]] {
    simulations_dir = os.path.join(os.getcwd(), "simulations");
    if not os.path.isdir(simulations_dir) {
        return [];
    }
    records: list[dict[str, any]] = [];
    for filename in os.listdir(simulations_dir) {
        if not filename.endswith(".json") {
            continue;
        }
        path = os.path.join(simulations_dir, filename);
        try {
            with open(path, "r", encoding="utf-8") as source_file {
                raw = json.loads(source_file.read());
            }
            if not isinstance(raw, dict) {
                continue;
            }
            trace = raw as dict[str, any];
            mission = _dict_value(trace.get("mission"));
            iterations = _dict_list(trace.get("iterations"));
            records.append({
                "filename": filename,
                "mission": str(mission.get("name", filename)),
                "status": str(mission.get("status", "")),
                "generated_at_utc": str(
                    trace.get("generated_at_utc", "")
                ),
                "iterations": len(iterations),
                "modified_at": float(os.path.getmtime(path))
            });
        } except Exception {
            continue;
        }
    }
    records.sort(
        key=lambda item: _float_value(
            item.get("modified_at", 0.0), 0.0
        ),
        reverse=True
    );
    return records;
}

def:pub load_simulation(filename: str) -> dict[str, any] {
    safe_name = os.path.basename(filename);
    if safe_name != filename or not safe_name.endswith(".json") {
        raise ValueError("invalid simulation filename");
    }
    path = os.path.join(os.getcwd(), "simulations", safe_name);
    if not os.path.isfile(path) {
        raise ValueError("simulation does not exist");
    }
    with open(path, "r", encoding="utf-8") as source_file {
        raw = json.loads(source_file.read());
    }
    if not isinstance(raw, dict) {
        raise ValueError("simulation trace must be a JSON object");
    }
    return raw as dict[str, any];
}
