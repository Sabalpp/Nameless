# SeaForge — Agent Guide

Read **`MEMORY.md` first** on every new session (after window reload, compaction, or handoff). Update it when you finish a meaningful unit of work.

## What this project is

**SeaForge** — naval hull simulation + Gemini design optimizer, ported from Rust/Express/React to **Jac**.

- Repo (local): `/Users/sweekarshrestha/JacHacks`
- Remote: `https://github.com/deltoidal-icositetrahedron/SeaForge.git`
- Branch in progress: `Sweekar/UI`
- Entry: `main.jac` (`jac.toml` → `kind = "web-app"`, `entry-point = "main.jac"`)

## Run

```bash
# REQUIRED: jaclang ≥ 0.34 with byLLM (not the old pip jaclang 0.16)
export PATH="$HOME/.local/bin:$PATH"

jac install
jac install --npm
jac start --dev          # UI :8000, API :8001
```

- **UI:** http://localhost:8000/
- **API only:** http://localhost:8001/ (will say `Client function 'app' not found` if opened as the app — that is expected)
- Set `GEMINI_API_KEY` for `POST /api/gemini/run`

CLI:

```bash
jac run cli.jac simulate-params examples/simulation_params.json result.json
jac run cli.jac brief mission-briefs/01_north_atlantic_sprint.json out.json --tier=lowest
jac run cli.jac optimize examples/search_space.json examples/voyage_route.json opt.json
```

## Layout (source of truth)

| Path | Role |
|------|------|
| `engine/` | Physics, voyage loop, optimizer, envelope, types |
| `engine/physics/` | corrosion, ice, resistance, stability, structural |
| `api.jac` | REST walkers (replaces Express `ui/server.js`) |
| `agent.jac` | byLLM Gemini campaign optimizer |
| `engine/graph.jac` | Campaign / Iteration graph under root |
| `pages/index.jac` | Main UI (Jac client codespace) |
| `components/HullDiagram.jsx` | Three.js hull (kept as JSX) |
| `components/missions.js` / `missions.jac` | Mission brief imports |
| `assets/` | STL, GeoJSON, `styles.css` |
| `parity/golden/` | Rust golden outputs for differential tests |
| `docs/allowed_parameters.json` | Parameter schema |
| `mission-briefs/` | Scenario JSON |
| `vision.pdf` | Scientific / product vision |

**Deleted / replaced (do not resurrect unless asked):** Rust `src/`, Express/Vite `ui/`, old `gemini_runner/*.js`. Git still shows them as deleted on `Sweekar/UI`.

## Architecture facts agents forget

1. **Parity with Rust is sacred** for physics (`voyage`, materials, structural Stirling gamma). Match constants and formulas; do not “simplify” with `math.gamma`.
2. **Client API calls** use `sv import` + `root spawn` walkers — not raw `fetch` to Express.
3. **`main.jac`** must export `def:pub app(children) -> JsxElement` and import API walkers so REST mounts.
4. **Pages** must return `JsxPage` (not bare `JsxElement`). Invalid: `to cl:` blocks in current Jac.
5. **JSX assets:** Jac client copies `.jsx` when imported with an explicit `.jsx` path. Prefer `import from "../components/HullDiagram.jsx"`.
6. **Mission JSON** must be importable from the client bundle (`components/missions.js`).
7. **byLLM** comes from `jaclang.byllm` on the `~/.local/bin/jac` install; `jac.toml` has `[dependencies] byllm = "~=0.6"`.

## Memory protocol

1. Session start → read `MEMORY.md` + this file.
2. After decisions / completed work / blockers → update `MEMORY.md` (Status, Now, Next, Decisions, Gotchas).
3. Before reload / long break → refresh `MEMORY.md` so the next agent is current.
4. Do not store secrets in memory files.

## Related chats (Cursor transcripts)

- [UI nav redesign](b7188449-aac5-40ee-bd14-d8bbc9ea0055) — simplify nav; decisions pending implementation
- [byLLM / jac start fix](69461173-b87f-4e99-a6d0-43c6e0ebbbd7) — PATH + Vite + page types
- [React → Jac UI port](009fa926-a73c-4379-9986-dfacb65f0cd8)
- [Full Jac port orchestration](708d0d03-36a7-4e56-bf0a-b18b8ef2730f)
