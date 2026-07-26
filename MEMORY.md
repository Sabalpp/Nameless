# SeaForge — Living Memory

> Agents: update this file when status changes. Keep it short and current.
> Last updated: 2026-07-26 (~15:20 PT)

## Status

**IN PROGRESS** — Jac port of SeaForge is largely complete and runnable; UI nav redesign was planned but **not implemented** before window reload.

| Area | State |
|------|--------|
| Rust → Jac engine (`engine/`) | Done (parity harness exists) |
| Express → `api.jac` walkers | Done |
| Gemini runner → `agent.jac` | Done |
| React UI → `pages/index.jac` | Done (hover drawer still in place) |
| `jac start --dev` | Was working on :8000 / :8001 after PATH fix |
| Nav UX redesign | **Designed in chat, not coded** |
| Git commit of Jac rewrite | **Not committed** — large WIP on `Sweekar/UI` |

## Now (what we were doing)

1. User asked to simplify the nav for brand-new users: clean, company-like, no AI slop, keep terminal aesthetic.
2. Agreed direction (from [UI nav redesign](b7188449-aac5-40ee-bd14-d8bbc9ea0055)):
   - **Persistent left sidebar** open by default, with minimize/collapse (not hover-only drawer)
   - **Right inspector** for results / analysis / config after a run
   - Plainer labels / clearer workflow: pick mission → run → inspect
3. Session interrupted before implementation. Current UI still uses `panel_open` + `onMouseEnter` / `onMouseLeave` hover drawer in `pages/index.jac` (~L173, ~L852+).

## Next (priority)

1. Implement nav redesign in `pages/index.jac` (+ `assets/styles.css` as needed):
   - Left rail/sidebar: Missions, Brief, Campaign, Run
   - Right inspector: Runs, Cost, Analysis, Parameter config
   - Open by default; explicit minimize (not hover-dismiss)
2. Smoke-test: `export PATH="$HOME/.local/bin:$PATH" && jac start --dev` → http://localhost:8000/
3. Optionally commit Jac rewrite on `Sweekar/UI` (ask user first).

## Decisions (settled)

- Full stack in Jac; delete Rust `src/` and Express `ui/` from the working tree (git shows as deletions).
- Keep `HullDiagram.jsx` as JSX inside `components/`.
- Use `~/.local/bin/jac` (0.34.x), not Frameworks Python `jac` 0.16.x.
- UI talks to backend via Jac walkers (`sv import` / spawn), not the old Node server.
- Nav redesign: persistent sidebar + right inspector (not hover mega-panel).

## Gotchas

- Wrong `jac` on PATH → `No module named 'jaclang.byllm'`. Fix: `export PATH="$HOME/.local/bin:$PATH"`.
- Opening :8001 in the browser is API-only; use :8000 for the app.
- `page()` must return `JsxPage`; `main.jac` needs `app(children)`.
- Do not use `to cl:` (invalid in current Jac).
- Import HullDiagram with explicit `.jsx` path so the client bundler copies it.
- Structural physics: port Stirling gamma helpers verbatim — never substitute `math.gamma`.
- Hover panel vanishes when the cursor leaves — this is the UX pain the redesign fixes.

## Key files for next agent

- `pages/index.jac` — UI + current hover nav
- `assets/styles.css` — styles
- `components/HullDiagram.jsx` — 3D hull
- `api.jac` — REST walkers
- `agent.jac` — Gemini campaign
- `AGENTS.md` — durable project guide
- `jac.toml` — web-app + byllm config

## Environment snapshot

- Branch: `Sweekar/UI`
- Uncommitted: Jac tree added; Rust/UI deleted; README updated
- Dev server: user may need to restart after reload (`jac start --dev`)
