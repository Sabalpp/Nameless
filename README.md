# SeaForge v3

SeaForge v3 is a graph-native autonomous-vessel mission simulator.

- Each candidate route is a persistent chain of `WaypointNode` nodes.
- Typed `RouteSegment` edges hold transit distance and environmental exposure.
- `VesselDesignNode` holds the current candidate design.
- Each `VoyageWalker` carries fuel, stability, corrosion, fatigue, cracks, and
  ice through the route.
- A failed walker persists a `FailureTrace` at its terminal waypoint.
- The optimizer reads prior attempts from the graph, revises the design, and
  launches another walker. It keeps the cheapest survivor among all attempted
  configurations rather than stopping at the first survivor.

## Project layout

```text
seaforge_v3/
├── main.jac                    # full-stack entrypoint
├── engine/
│   ├── orchestrator.jac        # HTTP and WebSocket optimizer walkers
│   ├── domain.jac              # persistent graph schema and API models
│   ├── physics.jac             # structural, stability, fuel, and cost model
│   ├── voyage.jac              # state-carrying physical voyage walker
│   └── services.jac            # marine conditions and JSON graph export
├── agent_runner/
│   └── codex_cli.jac           # isolated route/material Codex runner
├── web/                        # Jac dashboard, graph, and node inspector
├── examples/                   # POST payload examples
└── simulations/                # generated self-learning traces
```

The dependency direction is one-way: `main.jac` mounts the UI and imports the
orchestrator; the physics engine never launches or depends on an AI agent.
All project source is Jac. The agent runner and engine services use standard
library modules directly through Jac imports; there is no Python bridge or
`.pyi` stub layer.

## Validate

```bash
jac install
.jac/venv/bin/jac check main.jac engine/orchestrator.jac web/
.jac/venv/bin/jac test engine/orchestrator.jac -v
.jac/venv/bin/jac build main.jac
```

## Run the dashboard and API

```bash
.jac/venv/bin/jac start main.jac
```

Open `http://localhost:8000`. The dashboard starts the optimizer through
`ws://localhost:8000/ws/StreamOptimizeFromPoints`, draws every route and
material iteration, and opens complete node data when a graph node is clicked.

The API and graph inspector are also available at:

- `POST /walker/SetupMission`
- `POST /walker/OptimizeFromPoints`
- `POST /walker/RunVoyage`
- `POST /walker/RunOptimizer`
- `POST /walker/GetMission`
- `POST /function/MissionGraphDot`
- `GET /graph`
- `GET /docs`

## Two-point autonomous workflow

The primary hackathon endpoint needs only point A and point B:

```bash
curl -X POST http://localhost:8000/walker/OptimizeFromPoints \
  -H 'Content-Type: application/json' \
  --data @examples/two_points.json
```

Every POST saves a pretty-printed trace under `simulations/` and returns its
relative path in `simulation_file`, for example:

```json
{
  "status": "solved",
  "simulation_file": "simulations/norfolk-to-bermuda-a1b2c3d4.json",
  "simulation_error": ""
}
```

Each trace contains:

- `iterations`: the chronological self-improvement timeline
- `iterations[].decision_reasoning`: why Codex chose that route or design
- `iterations[].path`: every waypoint and its environmental conditions
- `iterations[].configuration`: material, thickness, weld, seal, geometry,
  fuel capacity, and revision
- `iterations[].result`: distance reached, percentage complete, cost, terminal
  waypoint, and exact failure diagnosis
- `iterations[].improvement`: route-score and survivor-cost deltas
- `graph.nodes` and `graph.edges`: an explicit graph representation connecting
  missions, routes, waypoints, configurations, and voyage outcomes
- `best`: the final locked route and cheapest successful configuration

Set `"save_simulation": false` only when an ephemeral run is desired.

It performs two strictly ordered stages:

1. Codex proposes multiple water routes. Each route becomes its own persistent
   waypoint chain, current wave/wind/temperature conditions are attached to
   its nodes, and a high-margin certification vessel walks the route.
2. After at least one route reaches point B, the lowest-condition-score
   successful route is locked. Codex then searches for the cheapest material,
   thickness, weld, and seal configuration that can still traverse that exact
   route.

Optional controls can be added beside the two points:

```json
{
  "origin": {"name": "Norfolk", "lat_deg": 36.8508, "lon_deg": -76.2859},
  "destination": {"name": "Bermuda", "lat_deg": 32.3078, "lon_deg": -64.7505},
  "route_iterations": 3,
  "material_iterations": 10,
  "use_codex": true,
  "use_live_conditions": true
}
```

Live conditions come from Open-Meteo's current marine and weather forecast
APIs. If they cannot be reached, nodes receive deterministic estimated
conditions and the response labels the source `estimated-or-mixed`. This is a
design simulation, not a navigation system.

Create the demonstration mission:

```bash
curl -X POST http://localhost:8000/walker/SetupMission \
  -H 'Content-Type: application/json' \
  --data @examples/hackathon_mission.json
```

Run the graph-memory optimizer without an external model:

```bash
curl -X POST http://localhost:8000/walker/RunOptimizer \
  -H 'Content-Type: application/json' \
  -d '{"mission_name":"North Atlantic Demonstrator","iterations":8,"use_codex":false}'
```

Use `"use_codex": true` to launch an ephemeral, read-only `codex exec`
subprocess for each design revision. It uses the existing Codex CLI login and
defaults to `gpt-5.6-sol`; override `codex_model` or `codex_timeout_s` in the
walker request when needed. If Codex is unavailable or times out, the optimizer
records a fallback and uses its local graph-driven revision rules.
