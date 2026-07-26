"""Route planning and ocean-condition services for SeaForge.

Codex proposes geographic waypoint chains.  Open-Meteo supplies a current
marine/weather snapshot when reachable; a deterministic estimate keeps local
and offline runs reproducible.
"""

from __future__ import annotations

import json
import math
import re
import subprocess
import tempfile
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path


ROUTE_SCHEMA = {
    "type": "object",
    "additionalProperties": False,
    "required": ["waypoints", "reasoning"],
    "properties": {
        "waypoints": {
            "type": "array",
            "minItems": 0,
            "maxItems": 10,
            "items": {
                "type": "object",
                "additionalProperties": False,
                "required": ["name", "lat_deg", "lon_deg"],
                "properties": {
                    "name": {"type": "string"},
                    "lat_deg": {
                        "type": "number",
                        "minimum": -90,
                        "maximum": 90,
                    },
                    "lon_deg": {
                        "type": "number",
                        "minimum": -180,
                        "maximum": 180,
                    },
                },
            },
        },
        "reasoning": {"type": "string"},
    },
}


def run_codex_route_planner(
    prompt: str,
    model: str = "gpt-5.6-sol",
    timeout_s: int = 120,
) -> str:
    """Run an isolated Codex route-planning turn and return strict JSON."""
    bounded_timeout = max(15, min(timeout_s, 300))
    with tempfile.TemporaryDirectory(prefix="seaforge-route-") as temp_dir:
        temp_path = Path(temp_dir)
        schema_path = temp_path / "route.schema.json"
        output_path = temp_path / "route.json"
        schema_path.write_text(json.dumps(ROUTE_SCHEMA), encoding="utf-8")
        command = [
            "codex",
            "exec",
            "--ephemeral",
            "--ignore-user-config",
            "--skip-git-repo-check",
            "--cd",
            str(temp_path),
            "--sandbox",
            "read-only",
            "--model",
            model,
            "--output-schema",
            str(schema_path),
            "--output-last-message",
            str(output_path),
            "--color",
            "never",
            "-",
        ]
        completed = subprocess.run(
            command,
            input=prompt,
            text=True,
            capture_output=True,
            cwd=temp_path,
            timeout=bounded_timeout,
            check=False,
        )
        if completed.returncode != 0:
            detail = completed.stderr.strip() or completed.stdout.strip()
            raise RuntimeError(
                f"codex route planning failed with status "
                f"{completed.returncode}: {detail[-1000:]}"
            )
        if not output_path.exists():
            raise RuntimeError("codex route planning produced no final response")
        parsed = json.loads(output_path.read_text(encoding="utf-8"))
        if not isinstance(parsed, dict):
            raise RuntimeError("codex route plan was not an object")
        return json.dumps(parsed)


def _estimated_condition(lat: float, lon: float) -> dict[str, object]:
    phase = math.radians(lat * 2.7 + lon * 1.3)
    hs = 1.1 + 2.4 * abs(math.sin(phase))
    tp = 6.5 + 4.5 * abs(math.cos(math.radians(lon - lat)))
    wind = 5.0 + 11.0 * abs(math.sin(math.radians(lat + lon * 0.7)))
    temp = max(-1.5, min(29.0, 27.0 - abs(lat) * 0.43))
    wave_direction = (lon * 3.1 - lat * 1.7 + 720.0) % 360.0
    return {
        "hs_m": round(hs, 3),
        "tp_s": round(tp, 3),
        "wave_direction_deg": round(wave_direction, 3),
        "water_temp_c": round(temp, 3),
        "wind_speed_ms": round(wind, 3),
        "salinity_ppt": 35.0,
        "ph": 8.1,
        "jonswap_gamma": 3.3,
        "slam_probability": round(min(0.85, 0.08 + hs * 0.08), 3),
        "condition_source": "estimated",
        "navigable": True,
    }


def _fetch_json(url: str, timeout_s: int) -> object:
    request = urllib.request.Request(
        url,
        headers={"User-Agent": "SeaForge-v3-hackathon/1.0"},
    )
    with urllib.request.urlopen(request, timeout=timeout_s) as response:
        return json.loads(response.read().decode("utf-8"))


def _as_location_list(payload: object) -> list[dict[str, object]]:
    if isinstance(payload, list):
        return [item for item in payload if isinstance(item, dict)]
    if isinstance(payload, dict):
        return [payload]
    return []


def enrich_route_points(
    points_json: str,
    use_live_conditions: bool = True,
    timeout_s: int = 12,
) -> str:
    """Attach current marine conditions to a JSON list of route points."""
    raw = json.loads(points_json)
    if not isinstance(raw, list):
        raise ValueError("route points must be a JSON list")
    points = [point for point in raw if isinstance(point, dict)]
    output: list[dict[str, object]] = []
    for index, point in enumerate(points):
        lat = float(point.get("lat_deg", 0.0))
        lon = float(point.get("lon_deg", 0.0))
        enriched = {
            "name": str(point.get("name", f"Waypoint {index + 1}")),
            "lat_deg": lat,
            "lon_deg": lon,
            **_estimated_condition(lat, lon),
        }
        output.append(enriched)

    if not use_live_conditions or not output:
        return json.dumps(output)

    latitudes = ",".join(str(point["lat_deg"]) for point in output)
    longitudes = ",".join(str(point["lon_deg"]) for point in output)
    marine_query = urllib.parse.urlencode(
        {
            "latitude": latitudes,
            "longitude": longitudes,
            "current": (
                "wave_height,wave_direction,wave_period,"
                "sea_surface_temperature"
            ),
        },
        safe=",",
    )
    weather_query = urllib.parse.urlencode(
        {
            "latitude": latitudes,
            "longitude": longitudes,
            "current": "wind_speed_10m",
            "wind_speed_unit": "ms",
        },
        safe=",",
    )
    try:
        marine = _as_location_list(
            _fetch_json(
                f"https://marine-api.open-meteo.com/v1/marine?{marine_query}",
                max(2, min(timeout_s, 30)),
            )
        )
    except (OSError, ValueError, TimeoutError):
        return json.dumps(output)
    try:
        weather = _as_location_list(
            _fetch_json(
                f"https://api.open-meteo.com/v1/forecast?{weather_query}",
                max(2, min(timeout_s, 30)),
            )
        )
    except (OSError, ValueError, TimeoutError):
        # Marine data remains useful when the separate atmospheric API is
        # rate-limited; retain the deterministic wind estimate.
        weather = []

    for index, enriched in enumerate(output):
        if index >= len(marine):
            continue
        marine_current = marine[index].get("current")
        if not isinstance(marine_current, dict):
            enriched["navigable"] = False
            enriched["condition_source"] = "live-land-or-unavailable"
            continue
        wave_height = marine_current.get("wave_height")
        if not isinstance(wave_height, (int, float)):
            enriched["navigable"] = False
            enriched["condition_source"] = "live-land-or-unavailable"
            continue
        enriched["hs_m"] = float(wave_height)
        enriched["tp_s"] = float(marine_current.get("wave_period") or 8.0)
        enriched["wave_direction_deg"] = float(
            marine_current.get("wave_direction") or 0.0
        )
        enriched["water_temp_c"] = float(
            marine_current.get("sea_surface_temperature") or 15.0
        )
        if index < len(weather):
            weather_current = weather[index].get("current")
            if isinstance(weather_current, dict):
                wind = weather_current.get("wind_speed_10m")
                if isinstance(wind, (int, float)):
                    enriched["wind_speed_ms"] = float(wind)
        enriched["slam_probability"] = min(
            0.95, 0.08 + float(enriched["hs_m"]) * 0.08
        )
        enriched["condition_source"] = "open-meteo-current"
        enriched["navigable"] = True
    return json.dumps(output)


def _safe_slug(value: str) -> str:
    slug = re.sub(r"[^a-z0-9]+", "-", value.lower()).strip("-")
    return (slug or "simulation")[:80]


def _build_trace_graph(trace: dict[str, object]) -> dict[str, object]:
    mission = trace.get("mission")
    mission_data = mission if isinstance(mission, dict) else {}
    mission_id = str(mission_data.get("id", "mission"))
    nodes: list[dict[str, object]] = [
        {
            "id": f"mission:{mission_id}",
            "kind": "mission",
            **mission_data,
        }
    ]
    edges: list[dict[str, object]] = []
    route_node_ids: set[str] = set()
    iterations = trace.get("iterations")
    events = iterations if isinstance(iterations, list) else []

    for event_index, raw_event in enumerate(events, start=1):
        if not isinstance(raw_event, dict):
            continue
        event_id = str(raw_event.get("event_id", f"iteration-{event_index}"))
        route_id = int(raw_event.get("route_id", 0))
        route_node_id = f"route:{route_id}"
        path = raw_event.get("path")
        path_points = path if isinstance(path, list) else []

        if route_node_id not in route_node_ids:
            route_node_ids.add(route_node_id)
            nodes.append(
                {
                    "id": route_node_id,
                    "kind": "route",
                    "route_id": route_id,
                    "condition_score": raw_event.get("condition_score", 0.0),
                    "distance_nm": raw_event.get("route_distance_nm", 0.0),
                }
            )
            edges.append(
                {
                    "source": f"mission:{mission_id}",
                    "target": route_node_id,
                    "kind": "HAS_ROUTE",
                }
            )
            previous_waypoint_id = ""
            for point_index, point in enumerate(path_points):
                if not isinstance(point, dict):
                    continue
                waypoint_id = f"route:{route_id}:waypoint:{point_index}"
                nodes.append(
                    {
                        "id": waypoint_id,
                        "kind": "waypoint",
                        "route_id": route_id,
                        "sequence": point_index,
                        **point,
                    }
                )
                if previous_waypoint_id:
                    edges.append(
                        {
                            "source": previous_waypoint_id,
                            "target": waypoint_id,
                            "kind": "ROUTE_SEGMENT",
                        }
                    )
                else:
                    edges.append(
                        {
                            "source": route_node_id,
                            "target": waypoint_id,
                            "kind": "STARTS_AT",
                        }
                    )
                previous_waypoint_id = waypoint_id

        config = raw_event.get("configuration")
        config_data = config if isinstance(config, dict) else {}
        config_node_id = f"configuration:{event_id}"
        nodes.append(
            {
                "id": config_node_id,
                "kind": "vessel_configuration",
                "event_id": event_id,
                **config_data,
            }
        )
        edges.append(
            {
                "source": config_node_id,
                "target": route_node_id,
                "kind": "TESTED_ON",
            }
        )

        result = raw_event.get("result")
        result_data = result if isinstance(result, dict) else {}
        outcome_node_id = f"outcome:{event_id}"
        nodes.append(
            {
                "id": outcome_node_id,
                "kind": "voyage_outcome",
                "event_id": event_id,
                **result_data,
            }
        )
        edges.append(
            {
                "source": config_node_id,
                "target": outcome_node_id,
                "kind": "PRODUCED",
            }
        )
        terminal_sequence = result_data.get("terminal_sequence")
        if isinstance(terminal_sequence, int) and terminal_sequence >= 0:
            edges.append(
                {
                    "source": outcome_node_id,
                    "target": (
                        f"route:{route_id}:waypoint:{terminal_sequence}"
                    ),
                    "kind": "TERMINATED_AT",
                }
            )

    return {"nodes": nodes, "edges": edges}


def _add_improvement_deltas(
    iterations: list[dict[str, object]],
) -> list[dict[str, object]]:
    prior_route_score: float | None = None
    best_success_cost: float | None = None
    enriched: list[dict[str, object]] = []
    for raw_event in iterations:
        event = dict(raw_event)
        phase = str(event.get("phase", ""))
        result = event.get("result")
        result_data = result if isinstance(result, dict) else {}
        improvement: dict[str, object] = {}
        if phase == "route_search":
            score = event.get("condition_score")
            if isinstance(score, (int, float)):
                improvement["condition_score_delta_vs_previous"] = (
                    None
                    if prior_route_score is None
                    else float(score) - prior_route_score
                )
                prior_route_score = float(score)
        if bool(result_data.get("survived", False)):
            cost = result_data.get("cost_usd")
            if isinstance(cost, (int, float)) and float(cost) > 0:
                improvement["cost_delta_vs_best_survivor"] = (
                    None
                    if best_success_cost is None
                    else float(cost) - best_success_cost
                )
                if best_success_cost is None or float(cost) < best_success_cost:
                    best_success_cost = float(cost)
                improvement["best_survivor_cost_after_iteration"] = (
                    best_success_cost
                )
        event["improvement"] = improvement
        enriched.append(event)
    return enriched


def save_simulation_trace(trace_json: str) -> str:
    """Save an atomic, pretty JSON trace and return its workspace-relative path."""
    parsed = json.loads(trace_json)
    if not isinstance(parsed, dict):
        raise ValueError("simulation trace must be a JSON object")
    mission = parsed.get("mission")
    mission_data = mission if isinstance(mission, dict) else {}
    mission_name = str(mission_data.get("name", "simulation"))
    mission_id = _safe_slug(str(mission_data.get("id", "unknown")))[:16]
    raw_iterations = parsed.get("iterations")
    iterations = (
        [item for item in raw_iterations if isinstance(item, dict)]
        if isinstance(raw_iterations, list)
        else []
    )
    parsed["schema_version"] = "seaforge.simulation.v1"
    parsed["generated_at_utc"] = datetime.now(timezone.utc).isoformat()
    parsed["iterations"] = _add_improvement_deltas(iterations)
    parsed["graph"] = _build_trace_graph(parsed)

    simulations_dir = Path.cwd() / "simulations"
    simulations_dir.mkdir(parents=True, exist_ok=True)
    filename = f"{_safe_slug(mission_name)}-{mission_id}.json"
    destination = simulations_dir / filename
    temporary = simulations_dir / f".{filename}.tmp"
    temporary.write_text(
        json.dumps(parsed, indent=2, sort_keys=False) + "\n",
        encoding="utf-8",
    )
    temporary.replace(destination)
    return str(Path("simulations") / filename)
