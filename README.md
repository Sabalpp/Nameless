# SeaForge (Jac)

Naval hull simulation engine with a React/Three.js globe UI and Gemini-powered design optimization — now entirely in [Jac](https://docs.jaseci.org).

## Quick start

```bash
# Install Jac (once)
curl -fsSL https://raw.githubusercontent.com/jaseci-labs/jaseci/main/scripts/install.sh | bash

# Install project deps
jac install
jac install --npm

# Run API + UI (HMR on :8000, API on :8001)
jac start --dev

# CLI simulation
jac run cli.jac simulate-params examples/simulation_params.json result.json
jac run cli.jac brief mission-briefs/01_north_atlantic_sprint.json out.json --tier=lowest
jac run cli.jac optimize examples/search_space.json examples/voyage_route.json opt.json
```

Set `GEMINI_API_KEY` for the AI campaign optimizer (`POST /api/gemini/run`).

## Project layout

```
engine/           # Physics, voyage loop, optimizer, envelope builder
api.jac           # REST walkers (replaces Express server.js)
agent.jac         # byLLM campaign optimizer (replaces gemini_runner)
graph.jac         # Persistent Campaign/Iteration graph under root
pages/index.jac   # Main UI (Jac client codespace)
components/       # HullDiagram.jsx (Three.js, kept as JSX)
assets/           # STL model, GeoJSON, CSS
parity/           # Differential harness vs Rust golden outputs
examples/         # Sample configs and search spaces
mission-briefs/   # Scenario JSON for UI + optimizer
docs/             # allowed_parameters.json — parameter schema (source of truth)
```

## Parity

Rust golden outputs live in `parity/golden/`. Regenerate with:

```bash
./parity/capture_golden.sh
./parity/run_parity.sh
```

Core physics (status, failure point, ticks, result metrics) matches Rust at ~1e-9 relative tolerance on verified cases.

## Scientific basis

See the original references in `vision.pdf` and the module docstrings under `engine/physics/`. SeaForge is an engineering approximation for exploration — not for real-world design decisions.
