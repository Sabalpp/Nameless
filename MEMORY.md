# SeaForge — Living Memory

> Agents: update this file when status changes. Keep it short and current.
> Last updated: 2026-07-26 (~16:00 PT)

## Status

**IN PROGRESS** — UI/UX polish pass applied to the light ops-console shell (sidebar → globe → inspector).

| Area | State |
|------|--------|
| Rust → Jac engine (`engine/`) | Done (parity harness exists) |
| Express → `api.jac` walkers | Done |
| Gemini runner → `agent.jac` | Done |
| React UI → `pages/index.jac` | Done + UX polish (first-run coach, inspector hierarchy, tokens) |
| `jac start --dev` | Working on :8000 / :8001 |
| Nav UX redesign | Done (persistent sidebar + right inspector) |
| UI polish pass | **Done** — coach copy, primary CTA, humanized results, sticky inspector metrics, collapsible params, centered playback |
| Git commit of Jac rewrite | **Not committed** — large WIP on `Sweekar/UI` |

## Now

UI/UX polish shipped in `pages/index.jac`, `components/panel.js`, `assets/styles.css`:
- First-run coach under 01 Mission; mission summary always visible after select
- Primary Optimize button + danger Stop; Results chrome only when campaign selected
- Campaign rows show mission name · status; run rows color-coded
- Inspector: sticky Status/Score/Cost, narrative analysis, collapsible params, minimize rail
- Playback centered in remaining globe band; light theme tokens unified

## Next

1. Smoke-test full flow at http://localhost:8000/ (cold load → mission → optimize → inspect → collapse rails)
2. Optionally commit Jac rewrite on `Sweekar/UI` (ask user first)

## Decisions (settled)

- Full stack in Jac; delete Rust `src/` and Express `ui/` from the working tree (git shows as deletions).
- Keep `HullDiagram.jsx` as JSX inside `components/`.
- Use `~/.local/bin/jac` (0.34.x), not Frameworks Python `jac` 0.16.x.
- UI talks to backend via Jac walkers (`sv import` / spawn), not the old Node server.
- Nav redesign: persistent sidebar + right inspector (not hover mega-panel).
- Visual system: light `#C3C4CA` + Courier ops console; tokens in `panel.js` + `styles.css`.

## Gotchas

- Wrong `jac` on PATH → `No module named 'jaclang.byllm'`. Fix: `export PATH="$HOME/.local/bin:$PATH"`.
- Opening :8001 in the browser is API-only; use :8000 for the app.
- `page()` must return `JsxPage`; `main.jac` needs `app(children)`.
- Simulation `params` may use `mission_id` not `id` — `mission_id_from_params()` handles both.
- Structural physics: port Stirling gamma helpers verbatim — never substitute `math.gamma`.

## Key files

- `pages/index.jac` — UI shell + workflow
- `components/panel.js` — shared panel tokens / list styles
- `assets/styles.css` — light theme utilities
- `components/HullDiagram.jsx` — 3D hull
- `api.jac` / `agent.jac` — backend
- `AGENTS.md` — durable project guide

## Environment snapshot

- Branch: `Sweekar/UI`
- Uncommitted: Jac tree + UI polish
- Dev server: `jac start --dev` (UI :8000, API :8001)
