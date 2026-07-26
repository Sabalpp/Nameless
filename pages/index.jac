"""SeaForge home page — Jac client port of ui/src/App.jsx."""

import "../assets/styles.css";
import from "react" { useEffect }
import from "../components/HullDiagram.jsx" { default as HullDiagram }
import from ..components.missions { MISSIONS }
import from ..components.panel {
    CELL_STYLE,
    COACH_TEXT,
    COLLAPSED_RAIL_WIDTH,
    EMPTY_STATE,
    INSPECTOR_WIDTH,
    MISSION_SUMMARY,
    MISSION_SUMMARY_SUB,
    NARRATIVE_BLOCK,
    NARRATIVE_LABEL,
    PANEL_HEADER_STYLE,
    PANEL_LABEL,
    PANEL_ROW,
    PANEL_SECTION_DIVIDER,
    PANEL_SECTION_TITLE,
    PANEL_VALUE,
    PANEL_WRAPPED_VALUE,
    SF_BG,
    SIDEBAR_WIDTH,
    SPINE_STEP_TITLE,
    list_item_style,
    status_color
}
sv import from ..api {
    api_simulations,
    api_gemini_status,
    api_gemini_stop,
    api_simulation,
    api_gemini_run
}

glob TICK_STEP_MS: float = 1000.0;
glob MIN_STEP_SPEED: float = 1.0;
glob MAX_STEP_SPEED: float = 64.0;

def fmt_number(value: any, digits: int = 1, fallback: str = "—") -> str {
    if not Number.isFinite(value) {
        return fallback;
    }
    n: float = float(value as float);
    return f"{n:.{digits}f}";
}

def fmt_range(range_val: any, unit: str = "", digits: int = 1) -> str {
    if not range_val {
        return "—";
    }
    parts: list[str] = [];
    if Number.isFinite(range_val["avg"]) {
        parts = parts + ["avg " + fmt_number(range_val["avg"], digits) + unit];
    }
    if Number.isFinite(range_val["min"]) {
        parts = parts + ["min " + fmt_number(range_val["min"], digits) + unit];
    }
    if Number.isFinite(range_val["max"]) {
        parts = parts + ["max " + fmt_number(range_val["max"], digits) + unit];
    }
    return " / ".join(parts) if len(parts) > 0 else "—";
}

def mission_factor(value: any) -> any {
    if value is None or value == "" or value == "—" {
        return "none";
    }
    if Number.isFinite(value) and float(value as float) == 0.0 {
        return "none";
    }
    text: any = value;
    trimmed: any = (String(text) as any).trim();
    zero_re: any = new(RegExp, "^0(?:\\.0+)?(?:\\s*(?:%|m/s|ppt|°C))?$", "i");
    if zero_re.test(trimmed) {
        return "none";
    }
    return value;
}

def format_failure_detail(failure: any) -> str {
    if not failure {
        return "—";
    }
    detail = failure["detail"];
    if not detail {
        mode = failure["mode"];
        return str(mode) if mode else "—";
    }
    zone = detail["failed_zone"] if detail["failed_zone"] else "Component";
    metric = detail["failed_metric"] if detail["failed_metric"] else (failure["mode"] if failure["mode"] else "failure");
    value = detail["failed_value"] if detail["failed_value"] else "failed";
    return f"{zone} {metric} {value}";
}

def display_status(status: any) -> str {
    return "SUCCESS" if status == "survived" else str(status if status else "—");
}

def js_replace(text: str, pattern: str, flags: str, repl: str) -> str {
    result: any = (text as any).replace(new(RegExp, pattern, flags), repl);
    return str(result);
}

def make_campaign_run_id(mission_id: any) -> str {
    safe_mission = js_replace(str(mission_id if mission_id else "campaign"), "[^A-Za-z0-9_-]", "g", "_");
    stamp_raw: any = new(Date).toISOString();
    stamp = js_replace(str(stamp_raw), "[:.]", "g", "-");
    return f"{safe_mission}_{stamp}";
}

def response_error_message(data: any, fallback: str) -> str {
    if not data {
        return fallback;
    }
    details: list[str] = [];
    if data["error"] {
        details = details + [str(data["error"])];
    }
    if data["stderr"] {
        details = details + [str(data["stderr"])];
    }
    if data["stdout"] {
        details = details + [str(data["stdout"])];
    }
    return "\n".join(details) if len(details) > 0 else fallback;
}

def pad2(n: int) -> str {
    s = str(n);
    return s if len(s) >= 2 else ("0" + s);
}

def format_elapsed_day_label(elapsed_h: any) -> str {
    raw: float = float(elapsed_h as float) if Number.isFinite(elapsed_h) else 0.0;
    safe: float = Math.max(0.0, raw);
    day: int = int(Math.floor(safe / 24.0));
    hour: int = int(Math.floor(safe % 24.0));
    return f"Day {day} {pad2(hour)}h";
}

def campaign_sort_key(c: any) -> float {
    t: any = Date.parse(str(c["created_at"]));
    return (-float(t as float)) if Number.isFinite(t) else 0.0;
}

def sort_campaigns_by_created_at(campaigns: list) -> list {
    return sorted(campaigns, key=campaign_sort_key);
}

def first_report(result: any) -> any {
    if not result {
        return None;
    }
    reports: any = result.reports;
    if reports and len(reports as list) > 0 {
        return reports[0];
    }
    return None;
}

def fmt_usd(value: any) -> str {
    if not Number.isFinite(value) {
        return "—";
    }
    n: any = float(value as float);
    return "$" + str((n as any).toLocaleString("en-US", {"maximumFractionDigits": 0}));
}

def dots(n: int) -> str {
    out = "";
    i = 0;
    while i < n {
        out = out + ".";
        i = i + 1;
    }
    return out;
}

def format_stressor(value: any) -> str {
    if not value {
        return "—";
    }
    return js_replace(str(value), "_", "g", " ");
}

def mission_id_from_params(params: any) -> any {
    if not params {
        return None;
    }
    if params["id"] {
        return params["id"];
    }
    if params["mission_id"] {
        return params["mission_id"];
    }
    return None;
}

def mission_for_campaign(campaign_id: any, simulations: list, missions: list) -> any {
    for sim in simulations {
        if sim["run_id"] == campaign_id {
            mid = mission_id_from_params(sim["params"]);
            if mid {
                for mission in missions {
                    if mission["id"] == mid {
                        return mission;
                    }
                }
            }
        }
    }
    return None;
}

def campaign_display_label(campaign: any, simulations: list, missions: list, running_id: any) -> str {
    mission = mission_for_campaign(campaign["id"], simulations, missions);
    name = mission["name"] if mission else "Optimization";
    status = "running" if campaign["id"] == running_id else "complete";
    return f"{name} · {status}";
}

def run_display_status(sim: any) -> str {
    if sim["failure"] and sim["failure"]["mode"] {
        return str(sim["failure"]["mode"]);
    }
    return display_status(sim["status"]);
}

def:pub page() -> JsxPage {
    has sim_result: any = None;
    has loading: bool = False;
    has error: any = None;
    has tick_position: float = 0.0;
    has step_speed: float = 1.0;
    has selected_mission: any = None;
    has simulations: list = [];
    has selected_campaign_id: any = None;
    has selected_simulation_id: any = None;
    has running_gemini: bool = False;
    has running_campaign_id: any = None;
    has running_campaign_started_at: any = None;
    has gemini_dot_count: int = 0;
    has sidebar_open: bool = True;
    has conditions_open: bool = False;
    has inspector_open: bool = True;
    has params_open: bool = False;
    has inspector_scroll_ref: Ref[any] = Ref(None);
    has gemini_dot_ref: Ref[int] = Ref(0);

    has tick_position_ref: Ref[float] = Ref(0.0);
    has step_speed_ref: Ref[float] = Ref(1.0);
    has held_direction_ref: Ref[float] = Ref(0.0);
    has frame_ref: Ref[any] = Ref(None);
    has last_frame_time_ref: Ref[any] = Ref(None);
    has stopping_gemini_ref: Ref[bool] = Ref(False);

    def set_displayed_tick_position(next_position: float) -> None {
        tick_position_ref.current = next_position;
        tick_position = next_position;
    }

    def set_displayed_step_speed(next_speed: float) -> None {
        step_speed_ref.current = next_speed;
        step_speed = next_speed;
    }

    async def refresh_simulations() -> None {
        try {
            result = root spawn api_simulations();
            data = first_report(result);
            sims: any = data["simulations"] if data and Array.isArray(data["simulations"]) else [];
            simulations = list(sims) if Array.isArray(sims) else [];
        } except Exception {
            simulations = [];
        }
    }

    async def refresh_gemini_status() -> any {
        try {
            result = root spawn api_gemini_status();
            status = first_report(result);
            if status and status["active"] and status["run_id"] {
                running_gemini = True;
                running_campaign_id = status["run_id"];
                running_campaign_started_at = status["started_at"] if status["started_at"] else status["run_id"];
                if not selected_campaign_id {
                    selected_campaign_id = status["run_id"];
                }
                loading = True;
                return status;
            }
            running_gemini = False;
            running_campaign_id = None;
            running_campaign_started_at = None;
            loading = False;
            return status;
        } except Exception {
            return None;
        }
    }

    async can with entry {
        await refresh_simulations();
        await refresh_gemini_status();
    }

    # Build campaign list (derived each render)
    by_id: dict = {};
    for sim in simulations {
        if not sim["run_id"] {
            continue;
        }
        rid = sim["run_id"];
        existing = by_id[rid];
        by_id = {
            **by_id,
            rid: {
                "id": rid,
                "created_at": existing["created_at"] if existing and existing["created_at"] else sim["created_at"],
                "count": (existing["count"] if existing else 0) + 1
            }
        };
    }
    campaign_vals: list = [by_id[k] for k in Object.keys(by_id)];
    campaigns = sort_campaigns_by_created_at(campaign_vals);
    running_in_list = False;
    for c in campaigns {
        if c["id"] == running_campaign_id {
            running_in_list = True;
        }
    }
    visible_campaigns = campaigns;
    if running_campaign_id and not running_in_list {
        visible_campaigns = sort_campaigns_by_created_at([
            {
                "id": running_campaign_id,
                "created_at": running_campaign_started_at if running_campaign_started_at else running_campaign_id,
                "count": 0
            }
        ] + campaigns);
    }

    can with (simulations, selected_campaign_id, running_campaign_id) entry {
        # Recompute visible campaigns inside the effect from current simulations.
        ids: dict = {};
        for sim in simulations {
            if not sim["run_id"] {
                continue;
            }
            rid = sim["run_id"];
            existing = ids[rid];
            ids = {
                **ids,
                rid: {
                    "id": rid,
                    "created_at": existing["created_at"] if existing and existing["created_at"] else sim["created_at"],
                    "count": (existing["count"] if existing else 0) + 1
                }
            };
        }
        vis = sort_campaigns_by_created_at([ids[k] for k in Object.keys(ids)]);
        present = False;
        for c in vis {
            if c["id"] == running_campaign_id {
                present = True;
            }
        }
        if running_campaign_id and not present {
            vis = sort_campaigns_by_created_at([
                {
                    "id": running_campaign_id,
                    "created_at": running_campaign_started_at if running_campaign_started_at else running_campaign_id,
                    "count": 0
                }
            ] + vis);
        }
        if len(vis) == 0 {
            if selected_campaign_id is not None and selected_campaign_id != running_campaign_id {
                selected_campaign_id = None;
            }
            return;
        }
        matched = False;
        for c in vis {
            if c["id"] == selected_campaign_id {
                matched = True;
            }
        }
        if not selected_campaign_id or (not matched and selected_campaign_id != running_campaign_id) {
            selected_campaign_id = vis[0]["id"];
        }
    }

    # Poll simulations + walker status while Gemini runs (replaces fetch polling)
    useEffect(lambda {
        if not running_gemini {
            return lambda {};
        }
        refresh_simulations();
        id = setInterval(lambda { refresh_simulations(); }, 1500);
        return lambda { clearInterval(id); };
    }, [running_gemini]);

    useEffect(lambda {
        if not running_gemini {
            return lambda {};
        }
        id = setInterval(lambda {
            refresh_gemini_status();
        }, 1500);
        return lambda { clearInterval(id); };
    }, [running_gemini]);

    useEffect(lambda {
        if not running_gemini {
            gemini_dot_ref.current = 0;
            gemini_dot_count = 0;
            return lambda {};
        }
        id = setInterval(lambda {
            next_dot: int = int((gemini_dot_ref.current + 1) % 4);
            gemini_dot_ref.current = next_dot;
            gemini_dot_count = next_dot;
        }, 300);
        return lambda { clearInterval(id); };
    }, [running_gemini]);

    useEffect(lambda {
        if not selected_simulation_id {
            return lambda {};
        }
        el = inspector_scroll_ref.current;
        if el {
            if el.scrollTo {
                el.scrollTo({"top": 0, "behavior": "smooth"});
            } else {
                el.scrollTop = 0;
            }
        }
        inspector_open = True;
        return lambda {};
    }, [selected_simulation_id]);

    can with (selected_mission, selected_simulation_id) entry {
        if not selected_mission {
            if not selected_simulation_id {
                sim_result = None;
            }
            error = None;
            return;
        }
        error = None;
        sim_result = None;
        selected_simulation_id = None;
        loading = False;
    }

    async def load_saved_simulation(id: str) -> None {
        loading = True;
        error = None;
        try {
            result = root spawn api_simulation(id=id);
            data = first_report(result);
            if not data or data["error"] {
                raise Exception(response_error_message(data, "Failed to load simulation"));
            }
            selected_mission = None;
            selected_simulation_id = id;
            sim_result = data["result"];
            loading = False;
        } except Exception as e {
            error = str(e);
            loading = False;
        }
    }

    async def run_gemini_simulations() -> None {
        if not selected_mission {
            error = "Select a mission brief before running Gemini.";
            return;
        }
        stopping_gemini_ref.current = False;
        running_gemini = True;
        gemini_dot_count = 0;
        loading = True;
        error = None;
        selected_simulation_id = None;
        run_id = make_campaign_run_id(selected_mission["id"]);
        started_at = new(Date).toISOString();
        running_campaign_id = run_id;
        running_campaign_started_at = started_at;
        selected_campaign_id = run_id;
        try {
            mid: str | None = str(selected_mission["id"]);
            result = root spawn api_gemini_run(
                mission_id=mid,
                tier="lowest",
                run_id=run_id
            );
            manifest = first_report(result);
            if manifest and manifest["error"] {
                raise Exception(response_error_message(manifest, "Gemini run failed"));
            }
            if manifest and manifest["run_id"] {
                selected_campaign_id = manifest["run_id"];
            }
            await refresh_simulations();
            best_survivor = manifest["best_survivor"] if manifest else None;
            iterations: list = list(manifest["iterations"]) if manifest and Array.isArray(manifest["iterations"]) else [];
            last = iterations[len(iterations) - 1] if len(iterations) > 0 else None;
            simulation_to_load = best_survivor if best_survivor and best_survivor["id"] else last;
            if simulation_to_load and simulation_to_load["id"] {
                await load_saved_simulation(str(simulation_to_load["id"]));
            } else {
                loading = False;
            }
        } except Exception as e {
            if not stopping_gemini_ref.current {
                error = str(e);
            }
            loading = False;
        }
        stopping_gemini_ref.current = False;
        running_gemini = False;
        running_campaign_id = None;
        running_campaign_started_at = None;
    }

    async def stop_gemini_simulations() -> None {
        stopping_gemini_ref.current = True;
        try {
            root spawn api_gemini_stop();
            running_gemini = False;
            running_campaign_id = None;
            running_campaign_started_at = None;
            loading = False;
            await refresh_simulations();
        } except Exception as e {
            error = str(e);
        }
    }

    def select_campaign(campaign_id: any) -> None {
        selected_campaign_id = campaign_id;
        selected_simulation_id = None;
        sim_result = None;
    }

    can with [sim_result] entry {
        held_direction_ref.current = 0.0;
        last_frame_time_ref.current = None;
        if frame_ref.current {
            window.cancelAnimationFrame(frame_ref.current as int);
            frame_ref.current = None;
        }
        set_displayed_tick_position(0.0);
        if sim_result {
            inspector_open = True;
            params_open = False;
        }
    }

    ticks: list = list(sim_result["ticks"]) if sim_result and Array.isArray(sim_result["ticks"]) else [];
    tick_count: int = len(ticks);
    is_viewing_simulation = bool(sim_result) and tick_count > 0;
    completed_distance_nm: float = float(sim_result["result"]["distance_completed_nm"] as float) if sim_result and sim_result["result"] and Number.isFinite(sim_result["result"]["distance_completed_nm"]) else 0.0;
    completed_pct: float = float(sim_result["result"]["distance_completed_pct"] as float) if sim_result and sim_result["result"] and Number.isFinite(sim_result["result"]["distance_completed_pct"]) else 0.0;
    total_distance_from_pct: float = (
        completed_distance_nm / (completed_pct / 100.0)
        if completed_distance_nm > 0.0 and completed_pct > 0.0
        else 0.0
    );
    final_tick_distance_nm: float = float(ticks[tick_count - 1]["distance_completed_nm"] as float) if tick_count > 0 and Number.isFinite(ticks[tick_count - 1]["distance_completed_nm"]) else 0.0;
    total_distance_nm: float = (
        total_distance_from_pct
        if total_distance_from_pct > 0.0
        else (completed_distance_nm if completed_distance_nm > 0.0 else final_tick_distance_nm)
    );
    simulation_failed = (sim_result["status"] == "failed" if sim_result else False) or bool(sim_result["failure"] if sim_result else False);
    needs_synthetic = (
        tick_count > 0
        and not simulation_failed
        and total_distance_nm > 0
        and final_tick_distance_nm < total_distance_nm * 0.995
    );
    average_tick_distance_nm = (
        Math.max(final_tick_distance_nm / (tick_count - 1), total_distance_nm / 120.0, 1.0)
        if tick_count > 1
        else Math.max(total_distance_nm / 120.0, 1.0)
    );
    synthetic_destination_tick_count = (
        Math.max(1, Math.ceil((total_distance_nm - final_tick_distance_nm) / average_tick_distance_nm))
        if needs_synthetic
        else 0
    );
    playback_tick_count = tick_count + synthetic_destination_tick_count;
    playback_max_position = Math.max(0.0, float(playback_tick_count - 1));
    clamped_tick_position = (
        Math.max(0.0, Math.min(tick_position, playback_max_position))
        if tick_count > 0
        else 0.0
    );
    active_tick_index: int = (
        int(Math.max(0, Math.min(tick_count - 1, Math.round(clamped_tick_position))))
        if tick_count > 0
        else 0
    );
    active_tick = ticks[active_tick_index] if tick_count > 0 else None;

    average_elapsed_per_tick_h = (
        float(ticks[tick_count - 1]["elapsed_h"] if ticks[tick_count - 1]["elapsed_h"] else 0) / (tick_count - 1)
        if tick_count > 1
        else 1.0
    );

    def elapsed_at(index: int) -> float {
        if index >= tick_count {
            return float(ticks[tick_count - 1]["elapsed_h"] if tick_count > 0 and ticks[tick_count - 1]["elapsed_h"] else 0) + float(index - tick_count + 1) * average_elapsed_per_tick_h;
        }
        safe_i = Math.max(0, index);
        return float(ticks[safe_i]["elapsed_h"] if ticks[safe_i]["elapsed_h"] else 0);
    }

    from_index: int = int(Math.floor(clamped_tick_position));
    to_index: int = int(Math.min(playback_tick_count - 1, from_index + 1));
    t_blend = clamped_tick_position - from_index;
    interpolated_elapsed_h = (
        elapsed_at(from_index) + (elapsed_at(to_index) - elapsed_at(from_index)) * t_blend
        if tick_count > 0
        else 0.0
    );
    active_day_label = format_elapsed_day_label(interpolated_elapsed_h);
    segment_index = active_tick["segment_index"] if active_tick and Number.isFinite(active_tick["segment_index"]) else 0;
    route_segments = (
        sim_result["voyage"]["route_segments"]
        if sim_result and sim_result["voyage"] and Array.isArray(sim_result["voyage"]["route_segments"])
        else []
    );
    active_route_segment = route_segments[segment_index] if segment_index < len(route_segments as list) else None;
    config = sim_result["configuration"] if sim_result else None;
    displayed_zones: list[any] = list(config["zones"]) if config and Array.isArray(config["zones"]) else [];
    failure_detail = format_failure_detail(sim_result["failure"] if sim_result else None);

    selected_simulation = None;
    for sim in simulations {
        if sim["id"] == selected_simulation_id {
            selected_simulation = sim;
        }
    }
    visible_simulations: list = (
        [sim for sim in simulations if sim["run_id"] == selected_campaign_id]
        if selected_campaign_id
        else simulations
    );
    selected_campaign = None;
    for campaign in visible_campaigns {
        if campaign["id"] == selected_campaign_id {
            selected_campaign = campaign;
        }
    }
    selected_campaign_status = (
        "running"
        if selected_campaign and selected_campaign["id"] and running_campaign_id == selected_campaign["id"]
        else "ended"
    );
    campaign_mission_id = None;
    for sim in visible_simulations {
        mid = mission_id_from_params(sim["params"]);
        if mid {
            campaign_mission_id = mid;
            break;
        }
    }
    campaign_mission = None;
    mission_list: list = list(MISSIONS);
    for mission in mission_list {
        if mission["id"] == campaign_mission_id {
            campaign_mission = mission;
        }
    }
    mission_brief = selected_mission;
    env = mission_brief["environmental_profile"] if mission_brief else None;
    campaign_success_count = len([sim for sim in visible_simulations if sim["status"] == "survived"]);
    campaign_failure_count = len([sim for sim in visible_simulations if sim["status"] == "failed"]);
    def iteration_rank(s: any) -> float {
        return -float(s["iteration"] as float) if Number.isFinite(s["iteration"]) else 0.0;
    }

    latest_campaign_simulation = None;
    if len(visible_simulations) > 0 {
        latest_campaign_simulation = sorted(visible_simulations, key=iteration_rank)[0];
    }

    def cost_of(sim: any) -> float {
        if not sim or not sim["result"] {
            return 1.0e30;
        }
        v: any = sim["result"]["total_config_cost_usd"];
        return float(v as float) if Number.isFinite(v) else 1.0e30;
    }

    def survivor_rank(a: any) -> float {
        score: float = float(a["eval"]["score_pct"] as float) if a["eval"] and Number.isFinite(a["eval"]["score_pct"]) else 0.0;
        return cost_of(a) * 1.0e6 - score;
    }

    def score_rank(a: any) -> float {
        score: float = float(a["eval"]["score_pct"] as float) if a["eval"] and Number.isFinite(a["eval"]["score_pct"]) else 0.0;
        return -score;
    }

    survivors = sorted(
        [sim for sim in visible_simulations if sim["status"] == "survived"],
        key=survivor_rank
    );
    best_simulation = survivors[0] if len(survivors) > 0 else (
        sorted(visible_simulations, key=score_rank)[0] if len(visible_simulations) > 0 else None
    );
    best_simulation_label = None;
    if best_simulation {
        score = (
            f"{best_simulation['eval']['score_pct']}%"
            if best_simulation["eval"] and Number.isFinite(best_simulation["eval"]["score_pct"])
            else "—"
        );
        cost_val = best_simulation["result"]["total_config_cost_usd"] if best_simulation["result"] else None;
        cost_label = fmt_usd(cost_val);
        best_simulation_label = f"{pad2(int(best_simulation['iteration']))} ({score} / {cost_label})";
    }

    def distance_at(index: int) -> float {
        if index >= tick_count {
            if synthetic_destination_tick_count <= 0 {
                return float(final_tick_distance_nm);
            }
            frac = Math.min(float(index - tick_count + 1) / float(synthetic_destination_tick_count), 1.0);
            return float(final_tick_distance_nm) + (float(total_distance_nm) - float(final_tick_distance_nm)) * frac;
        }
        d = ticks[index]["distance_completed_nm"] if ticks[index] else 0.0;
        return float(d) if Number.isFinite(d) else 0.0;
    }

    tick_progress = 0.0;
    if playback_tick_count <= 0 or total_distance_nm <= 0 {
        pct = sim_result["result"]["distance_completed_pct"] if sim_result and sim_result["result"] else 0;
        tick_progress = Math.min((float(pct) if Number.isFinite(pct) else 0.0) / 100.0, 1.0);
    } else {
        from_d = distance_at(from_index);
        to_d = distance_at(to_index);
        tick_progress = Math.min((from_d + (to_d - from_d) * t_blend) / float(total_distance_nm), 1.0);
    }

    useEffect(lambda {
        def stop_held_step() -> None {
            held_direction_ref.current = 0.0;
            last_frame_time_ref.current = None;
            if frame_ref.current {
                window.cancelAnimationFrame(frame_ref.current as int);
                frame_ref.current = None;
            }
        }

        def step_frame(now: float) -> None {
            direction = held_direction_ref.current;
            if not direction or not is_viewing_simulation or playback_tick_count <= 1 {
                stop_held_step();
                return;
            }
            previous_time = last_frame_time_ref.current if last_frame_time_ref.current is not None else now;
            last_frame_time_ref.current = now;
            delta_ticks = ((now - previous_time) / TICK_STEP_MS) * step_speed_ref.current;
            next_position = Math.max(
                0.0,
                Math.min(playback_max_position, tick_position_ref.current + direction * delta_ticks)
            );
            set_displayed_tick_position(next_position);
            if (direction > 0 and next_position >= playback_max_position) or (direction < 0 and next_position <= 0) {
                stop_held_step();
                return;
            }
            frame_ref.current = window.requestAnimationFrame(step_frame);
        }

        def start_held_step(direction: float) -> None {
            if not is_viewing_simulation or playback_tick_count <= 1 {
                return;
            }
            if held_direction_ref.current == direction {
                return;
            }
            stop_held_step();
            held_direction_ref.current = direction;
            last_frame_time_ref.current = None;
            frame_ref.current = window.requestAnimationFrame(step_frame);
        }

        def on_key_down(event: any) -> None {
            target = event.target;
            is_editable = target and (
                target.isContentEditable
                or target.tagName == "INPUT"
                or target.tagName == "TEXTAREA"
                or target.tagName == "SELECT"
            );
            if is_editable {
                return;
            }
            if event.code == "ArrowRight" {
                event.preventDefault();
                start_held_step(1.0);
            } elif event.code == "ArrowLeft" {
                event.preventDefault();
                start_held_step(-1.0);
            } elif event.code == "ArrowUp" {
                event.preventDefault();
                set_displayed_step_speed(Math.min(MAX_STEP_SPEED, step_speed_ref.current * 2.0));
            } elif event.code == "ArrowDown" {
                event.preventDefault();
                set_displayed_step_speed(Math.max(MIN_STEP_SPEED, step_speed_ref.current / 2.0));
            }
        }

        def on_key_up(event: any) -> None {
            if (
                (event.code == "ArrowRight" and held_direction_ref.current > 0)
                or (event.code == "ArrowLeft" and held_direction_ref.current < 0)
            ) {
                stop_held_step();
            }
        }

        window.addEventListener("keydown", on_key_down);
        window.addEventListener("keyup", on_key_up);
        window.addEventListener("blur", stop_held_step);
        return lambda {
            window.removeEventListener("keydown", on_key_down);
            window.removeEventListener("keyup", on_key_up);
            window.removeEventListener("blur", stop_held_step);
            stop_held_step();
        };
    }, [is_viewing_simulation, playback_max_position, playback_tick_count]);

    can_step_back = is_viewing_simulation and playback_tick_count > 1 and clamped_tick_position > 0;
    can_step_forward = is_viewing_simulation and playback_tick_count > 1 and clamped_tick_position < playback_max_position;

    def step_back(e: MouseEvent) -> None {
        if not can_step_back {
            return;
        }
        cur_back: float = tick_position_ref.current if tick_position_ref.current is not None else 0.0;
        set_displayed_tick_position(Math.max(0.0, float(Math.round(cur_back)) - 1.0));
    }

    def step_forward(e: MouseEvent) -> None {
        if not can_step_forward {
            return;
        }
        cur_fwd: float = tick_position_ref.current if tick_position_ref.current is not None else 0.0;
        set_displayed_tick_position(Math.min(playback_max_position, float(Math.round(cur_fwd)) + 1.0));
    }

    cell: dict[str, object] = CELL_STYLE;
    sidebar_width: int = SIDEBAR_WIDTH;
    inspector_width: int = INSPECTOR_WIDTH;
    has_results: bool = len(visible_campaigns) > 0 or running_gemini;

    def render_panel_row(label: str, value: any, wrap: bool = False) -> JsxElement {
        value_style: dict[str, object] = ({**PANEL_VALUE, **PANEL_WRAPPED_VALUE} if wrap else PANEL_VALUE) as dict[str, object];
        return <div style={PANEL_ROW}>
            <span style={PANEL_LABEL}>{label}</span>
            <span style={value_style}>{value if value is not None else "—"}</span>
        </div>;
    }

    def render_narrative(label: str, value: any) -> JsxElement {
        if not value {
            return <></>;
        }
        return <div style={NARRATIVE_BLOCK}>
            <div style={NARRATIVE_LABEL}>{label}</div>
            <div>{str(value)}</div>
        </div>;
    }

    route_geo = None;
    if mission_brief {
        route_geo = {
            "origin": mission_brief["origin"],
            "waypoints": mission_brief["waypoints"] if mission_brief["waypoints"] else [],
            "destination": mission_brief["destination"]
        };
    }

    def toggle_sidebar(e: MouseEvent) -> None { sidebar_open = not sidebar_open; }
    def toggle_inspector(e: MouseEvent) -> None { inspector_open = not inspector_open; }
    def toggle_conditions(e: MouseEvent) -> None { conditions_open = not conditions_open; }
    def toggle_params(e: MouseEvent) -> None { params_open = not params_open; }
    def on_run_gemini(e: MouseEvent) -> None { run_gemini_simulations(); }
    def on_stop_gemini(e: MouseEvent) -> None { stop_gemini_simulations(); }

    optimize_label = (
        "Optimizing" + dots(gemini_dot_count)
        if running_gemini
        else ("Select a mission to begin" if not selected_mission else "Optimize Design")
    );
    conditions_label = ("▼ " if conditions_open else "▶ ") + "Conditions";
    zone_count = len(displayed_zones);
    params_label = (("▼ " if params_open else "▶ ") + f"Parameter Configuration ({zone_count} zones)");
    sidebar_toggle_label = "Minimize sidebar" if sidebar_open else "Expand sidebar";
    inspector_toggle_label = "Minimize inspector" if inspector_open else "Expand inspector";
    effective_sidebar_w = sidebar_width if sidebar_open else COLLAPSED_RAIL_WIDTH;
    effective_inspector_w = (
        inspector_width if inspector_open else COLLAPSED_RAIL_WIDTH
    ) if sim_result else 0;
    playback_center = f"calc({effective_sidebar_w}px + (100vw - {effective_sidebar_w + effective_inspector_w}px) / 2)";
    inspector_status = (
        display_status(selected_simulation["status"])
        if selected_simulation
        else display_status(sim_result["status"] if sim_result else None)
    );
    inspector_score = (
        f"{selected_simulation['eval']['score_pct']}%"
        if selected_simulation and selected_simulation["eval"] and Number.isFinite(selected_simulation["eval"]["score_pct"])
        else "—"
    );
    inspector_cost = (
        fmt_usd(sim_result["result"]["total_config_cost_usd"])
        if sim_result and sim_result["result"] and sim_result["result"]["total_config_cost_usd"]
        else "—"
    );
    optimize_btn_class = "sf-btn-primary" + (" sf-optimizing" if running_gemini else "");
    inspector_status_class = "sf-inspector-metric-value";
    if inspector_status == "SUCCESS" {
        inspector_status_class = "sf-inspector-metric-value sf-status-survived";
    } elif inspector_status != "—" {
        inspector_status_class = "sf-inspector-metric-value sf-status-failed";
    }

    return <div style={{
        "width": "100vw",
        "height": "100vh",
        "overflow": "hidden",
        "background": SF_BG,
        "position": "relative"
    }}>
        <HullDiagram
            simResult={sim_result}
            loading={loading}
            progress={tick_progress}
            activeTick={active_tick}
            routeGeo={route_geo}
        />

        <div
            style={{
                "position": "absolute",
                "top": 0,
                "left": 0,
                "width": sidebar_width if sidebar_open else COLLAPSED_RAIL_WIDTH,
                "height": "100vh",
                "background": SF_BG,
                "borderRight": "1px solid rgba(0,0,0,0.13)",
                "overflow": "hidden",
                "zIndex": 10,
                "transition": "width 220ms ease"
            }}
        >
            <button
                type="button"
                onClick={toggle_sidebar}
                aria-label={sidebar_toggle_label}
                style={{
                    "position": "absolute",
                    "top": 0,
                    "left": 0,
                    "width": COLLAPSED_RAIL_WIDTH,
                    "height": 28,
                    "display": "flex",
                    "alignItems": "center",
                    "justifyContent": "center",
                    "background": "transparent",
                    "border": "none",
                    "cursor": "pointer",
                    "zIndex": 2
                }}
            >
                {if sidebar_open {
                    <span style={{
                        "fontFamily": "'Courier New', monospace",
                        "fontSize": 12,
                        "color": "rgba(0,0,0,0.55)"
                    }}>
                        {"❮"}
                    </span>;
                } else {
                    <svg width="14" height="10" viewBox="0 0 14 10" fill="none">
                        <rect y="0" width="14" height="1.5" rx="0.75" fill="rgba(0,0,0,0.52)"/>
                        <rect y="4.25" width="14" height="1.5" rx="0.75" fill="rgba(0,0,0,0.52)"/>
                        <rect y="8.5" width="14" height="1.5" rx="0.75" fill="rgba(0,0,0,0.52)"/>
                    </svg>;
                }}
            </button>

            <div style={{
                "opacity": 1 if sidebar_open else 0,
                "pointerEvents": "auto" if sidebar_open else "none",
                "transition": "opacity 160ms ease",
                "width": sidebar_width,
                "height": "100%",
                "display": "flex",
                "flexDirection": "column"
            }}>
                <div style={{
                    "padding": "8px 14px 8px 36px",
                    "fontFamily": "'Courier New', monospace",
                    "fontSize": 11,
                    "fontWeight": 700,
                    "letterSpacing": "0.16em",
                    "textTransform": "uppercase",
                    "color": "rgba(0,0,0,0.72)",
                    "borderBottom": "1px solid rgba(0,0,0,0.08)"
                }}>
                    SEAFORGE
                </div>

                <div className="no-scrollbar" style={{"flex": 1, "overflowY": "auto"}}>
                    <div style={SPINE_STEP_TITLE}>01 Mission</div>
                    {if not selected_mission {
                        <div style={COACH_TEXT}>
                            Choose a route to optimize. Each mission tests the hull against different sea conditions.
                        </div>;
                    }}
                    <div style={{"flexShrink": 0}}>
                        {for m in mission_list {
                            is_selected = selected_mission and selected_mission["id"] == m["id"];
                            <div
                                key={m["id"]}
                                onClick={lambda (e: MouseEvent) -> None {
                                    selected_simulation_id = None;
                                    selected_mission = None if is_selected else m;
                                    conditions_open = False if is_selected else True;
                                }}
                                style={{
                                    **list_item_style(is_selected),
                                    "display": "flex",
                                    "alignItems": "baseline",
                                    "gap": 8,
                                    "whiteSpace": "nowrap"
                                }}
                            >
                                <span style={{"color": "rgba(0,0,0,0.35)", "fontSize": 10}}>
                                    {str(m["id"]).split("_")[0]}
                                </span>
                                {m["name"]}
                            </div>;
                        }}
                    </div>

                    {if mission_brief {
                        <div style={MISSION_SUMMARY}>
                            <div>{mission_brief["name"]}</div>
                            <div style={MISSION_SUMMARY_SUB}>
                                {format_stressor(mission_brief["primary_stressor"] if mission_brief["primary_stressor"] else "")}
                            </div>
                        </div>
                        <div style={{"borderTop": "1px solid rgba(0,0,0,0.08)"}}>
                            <button
                                type="button"
                                className="sf-disclosure"
                                onClick={toggle_conditions}
                            >
                                {conditions_label}
                            </button>
                            if conditions_open {
                                render_panel_row("Mission", mission_brief["name"], True);
                                if mission_brief["objective"] {
                                    render_panel_row("Objective", mission_brief["objective"], True);
                                }
                                render_panel_row(
                                    "Physics",
                                    format_stressor(mission_brief["primary_stressor"] if mission_brief["primary_stressor"] else ""),
                                    True
                                );
                                failure_modes = mission_brief["failure_modes_under_test"] if mission_brief["failure_modes_under_test"] else [];
                                render_panel_row("Failure", ", ".join([str(x) for x in failure_modes]) if failure_modes and len(failure_modes as list) > 0 else "—", True);
                                render_panel_row("Waves", fmt_range(env["wave_height_m"] if env else None, "m"));
                                render_panel_row("Wind", mission_factor("—"));
                                render_panel_row("Slamming", mission_factor(env["slamming_probability"] if env and env["slamming_probability"] else "—"));
                                render_panel_row("Water", mission_factor(fmt_range(env["water_temp_c"] if env else None, "°C")));
                                render_panel_row("Ice", mission_factor(env["ice_accretion_risk"] if env and env["ice_accretion_risk"] else "—"));
                                render_panel_row("Salinity", mission_factor(f"{fmt_number(env['salinity_ppt'] if env else None)} ppt"));
                                render_panel_row("pH", mission_factor(fmt_number(env["ph"] if env else None, 2)));
                            }
                        </div>;
                    } else {
                        <div style={EMPTY_STATE}>
                            Pick a mission above to see its conditions.
                        </div>;
                    }}

                    <div style={({**SPINE_STEP_TITLE, **PANEL_SECTION_DIVIDER}) as dict[str, object]}>02 Optimize</div>
                    <div style={({"padding": "0 14px 14px", "display": "flex"} if running_gemini else {"padding": "0 14px 14px"}) as dict[str, object]}>
                        <button
                            type="button"
                            className={optimize_btn_class}
                            onClick={on_run_gemini}
                            disabled={running_gemini or not selected_mission}
                            style={({"width": "63%"} if running_gemini else {"width": "100%"}) as dict[str, object]}
                        >
                            {optimize_label}
                        </button>
                        {if running_gemini {
                            <button
                                type="button"
                                className="sf-btn-danger"
                                onClick={on_stop_gemini}
                                style={{
                                    "width": "37%",
                                    "marginLeft": -1
                                }}
                            >
                                Stop
                            </button>;
                        }}
                    </div>

                    {if has_results {
                        <div style={({**SPINE_STEP_TITLE, **PANEL_SECTION_DIVIDER}) as dict[str, object]}>03 Results</div>
                        <div style={PANEL_SECTION_TITLE}>Optimization Sessions</div>
                        <div className="no-scrollbar" style={{"maxHeight": 116, "overflowY": "auto"}}>
                            {for campaign in visible_campaigns {
                                is_selected = selected_campaign_id == campaign["id"];
                                campaign_label = campaign_display_label(
                                    campaign,
                                    simulations,
                                    mission_list,
                                    running_campaign_id
                                );
                                <div
                                    key={campaign["id"]}
                                    onClick={lambda (e: MouseEvent) -> None { select_campaign(campaign["id"]); }}
                                    style={{
                                        **list_item_style(is_selected),
                                        "display": "grid",
                                        "gridTemplateColumns": "1fr auto",
                                        "alignItems": "center",
                                        "gap": 10,
                                        "whiteSpace": "nowrap",
                                        "overflow": "hidden"
                                    }}
                                >
                                    <span style={{"overflow": "hidden", "textOverflow": "ellipsis"}}>
                                        {campaign_label}
                                    </span>
                                    <span style={{
                                        "color": "rgba(0,0,0,0.85)" if is_selected else "rgba(0,0,0,0.55)",
                                        "fontWeight": 700,
                                        "minWidth": 22,
                                        "textAlign": "right"
                                    }}>
                                        {campaign["count"]}
                                    </span>
                                </div>;
                            }}
                        </div>

                        {if selected_campaign {
                            <div style={PANEL_SECTION_TITLE}>Session Details</div>
                            render_panel_row("Session", selected_campaign["id"], True);
                            render_panel_row("Status", selected_campaign_status);
                            render_panel_row("Mission", campaign_mission["name"] if campaign_mission else "—", True);
                            render_panel_row("Runs", str(selected_campaign["count"]));
                            render_panel_row("Success", str(campaign_success_count));
                            render_panel_row("Failed", str(campaign_failure_count));
                            if best_simulation_label {
                                render_panel_row("Best", best_simulation_label, True);
                            }
                            if latest_campaign_simulation {
                                render_panel_row(
                                    "Latest",
                                    f"{pad2(int(latest_campaign_simulation['iteration']))} {display_status(latest_campaign_simulation['status'])}",
                                    True
                                );
                            }
                            render_panel_row("Leg", active_route_segment["label"] if active_route_segment and active_route_segment["label"] else "—", True);
                        }}

                        <div style={PANEL_SECTION_TITLE}>Design Runs</div>
                        <div className="no-scrollbar" style={{"maxHeight": 170, "overflowY": "auto", "paddingBottom": 14}}>
                            if len(visible_simulations) == 0 {
                                <div style={EMPTY_STATE}>
                                    Runs appear here after you optimize a design.
                                </div>;
                            } else {
                                for sim in visible_simulations {
                                    is_selected = selected_simulation_id == sim["id"];
                                    failure = run_display_status(sim);
                                    run_tone = status_color(sim["status"]);
                                    eval_score = (
                                        f"{sim['eval']['score_pct']}%"
                                        if sim["eval"] and Number.isFinite(sim["eval"]["score_pct"])
                                        else "—"
                                    );
                                    <div
                                        key={sim["id"]}
                                        onClick={lambda (e: MouseEvent) -> None { load_saved_simulation(str(sim["id"])); }}
                                        style={{
                                            **list_item_style(is_selected),
                                            "display": "grid",
                                            "gridTemplateColumns": "1fr auto",
                                            "alignItems": "center",
                                            "gap": 10,
                                            "whiteSpace": "nowrap",
                                            "overflow": "hidden"
                                        }}
                                    >
                                        <span style={{"overflow": "hidden", "textOverflow": "ellipsis"}}>
                                            <span style={{"color": "rgba(0,0,0,0.35)"}}>
                                                {pad2(int(sim["iteration"]))}
                                            </span>
                                            {" "}
                                            <span style={{"color": run_tone}}>
                                                {failure}
                                            </span>
                                        </span>
                                        <span style={{
                                            "color": run_tone if is_selected else "rgba(0,0,0,0.55)",
                                            "fontWeight": 700,
                                            "minWidth": 34,
                                            "textAlign": "right"
                                        }}>
                                            {eval_score}
                                        </span>
                                    </div>;
                                }
                            }
                        </div>
                    }}
                </div>
            </div>
        </div>

        {if sim_result {
            <div
                className="sf-inspector-enter"
                style={{
                    "position": "absolute",
                    "top": 0,
                    "right": 0,
                    "width": inspector_width if inspector_open else COLLAPSED_RAIL_WIDTH,
                    "height": "100vh",
                    "background": SF_BG,
                    "borderLeft": "1px solid rgba(0,0,0,0.13)",
                    "overflow": "hidden",
                    "zIndex": 10,
                    "transition": "width 220ms ease"
                }}
            >
                <button
                    type="button"
                    onClick={toggle_inspector}
                    aria-label={inspector_toggle_label}
                    style={{
                        "position": "absolute",
                        "top": 0,
                        "right": 0,
                        "width": COLLAPSED_RAIL_WIDTH,
                        "height": 28,
                        "display": "flex",
                        "alignItems": "center",
                        "justifyContent": "center",
                        "background": "transparent",
                        "border": "none",
                        "cursor": "pointer",
                        "zIndex": 3
                    }}
                >
                    {if inspector_open {
                        <span style={{
                            "fontFamily": "'Courier New', monospace",
                            "fontSize": 12,
                            "color": "rgba(0,0,0,0.55)"
                        }}>
                            {"❯"}
                        </span>;
                    } else {
                        <svg width="14" height="10" viewBox="0 0 14 10" fill="none">
                            <rect y="0" width="14" height="1.5" rx="0.75" fill="rgba(0,0,0,0.52)"/>
                            <rect y="4.25" width="14" height="1.5" rx="0.75" fill="rgba(0,0,0,0.52)"/>
                            <rect y="8.5" width="14" height="1.5" rx="0.75" fill="rgba(0,0,0,0.52)"/>
                        </svg>;
                    }}
                </button>

                <div
                    ref={inspector_scroll_ref}
                    className="no-scrollbar"
                    style={{
                        "height": "100%",
                        "overflowY": "auto",
                        "opacity": 1 if inspector_open else 0,
                        "pointerEvents": "auto" if inspector_open else "none",
                        "transition": "opacity 160ms ease"
                    }}
                >
                    <div className="sf-inspector-sticky">
                        <div className="sf-inspector-metric">
                            <span className="sf-inspector-metric-label">Status</span>
                            <span className={inspector_status_class}>
                                {inspector_status}
                            </span>
                        </div>
                        <div className="sf-inspector-metric">
                            <span className="sf-inspector-metric-label">Score</span>
                            <span className="sf-inspector-metric-value">{inspector_score}</span>
                        </div>
                        <div className="sf-inspector-metric">
                            <span className="sf-inspector-metric-label">Cost</span>
                            <span className="sf-inspector-metric-value">{inspector_cost}</span>
                        </div>
                    </div>

                    <div style={({"paddingRight": COLLAPSED_RAIL_WIDTH}) as dict[str, object]}>
                        <div style={PANEL_HEADER_STYLE}>Inspection</div>

                        <div style={({**PANEL_SECTION_TITLE, **PANEL_SECTION_DIVIDER, "marginTop": 8}) as dict[str, object]}>Analysis</div>
                        if selected_simulation or sim_result["failure"] {
                            if selected_simulation and selected_simulation["assessment"] and selected_simulation["assessment"]["model_used"] {
                                render_panel_row("Model", selected_simulation["assessment"]["model_used"], True);
                            }
                            if selected_simulation and selected_simulation["assessment"] and selected_simulation["assessment"]["assessment"] {
                                render_narrative("Thoughts", selected_simulation["assessment"]["assessment"]);
                            }
                            if selected_simulation and selected_simulation["assessment"] and selected_simulation["assessment"]["failed_part"] {
                                render_panel_row("Part", selected_simulation["assessment"]["failed_part"], True);
                            }
                            if selected_simulation and selected_simulation["assessment"] and selected_simulation["assessment"]["failed_metric"] {
                                render_panel_row("Metric", selected_simulation["assessment"]["failed_metric"], True);
                            }
                            if selected_simulation and selected_simulation["assessment"] and selected_simulation["assessment"]["root_cause"] {
                                render_narrative("Cause", selected_simulation["assessment"]["root_cause"]);
                            }
                            changes: list[any] = list(selected_simulation["assessment"]["changes"]) if selected_simulation and selected_simulation["assessment"] and selected_simulation["assessment"]["changes"] else [];
                            if len(changes) > 0 {
                                render_narrative("Solution", "; ".join([str(x) for x in changes]));
                            }
                            if sim_result["failure"] {
                                render_narrative("Failed", failure_detail);
                            }
                        } else {
                            <div style={EMPTY_STATE}>
                                Select a design run to read the analysis.
                            </div>;
                        }

                        <button
                            type="button"
                            className="sf-disclosure"
                            onClick={toggle_params}
                            style={({"marginTop": 8, **PANEL_SECTION_DIVIDER}) as dict[str, object]}
                        >
                            {params_label}
                        </button>
                        if params_open and config {
                            render_panel_row("Shell mass", f"{fmt_number(config['shell_mass_kg'], 0)} kg");
                            if config["propulsion"] {
                                render_panel_row("Fuel cap", f"{fmt_number(config['propulsion']['fuel_capacity_kg'], 0)} kg");
                                render_panel_row("Efficiency", fmt_number(config["propulsion"]["propulsive_efficiency"], 2));
                                render_panel_row("Drag coeff", fmt_number(config["propulsion"]["hull_drag_coeff"], 4));
                            }
                            for (index, zone_raw) in enumerate(displayed_zones) {
                                zone: any = zone_raw;
                                zone_key = zone["zone_key"] if zone["zone_key"] else (zone["zone"] if zone["zone"] else index);
                                <div
                                    key={f"{zone_key}-{index}"}
                                    style={{
                                        "padding": "6px 14px 7px",
                                        "fontFamily": "'Courier New', monospace",
                                        "fontSize": 13,
                                        "lineHeight": 1.35,
                                        "color": "rgba(0,0,0,0.85)"
                                    }}
                                >
                                    <div style={{
                                        "color": "rgba(0,0,0,0.85)",
                                        "marginBottom": 3,
                                        "whiteSpace": "nowrap",
                                        "overflow": "hidden",
                                        "textOverflow": "ellipsis"
                                    }}>
                                        {zone["zone"] if zone["zone"] else "Component"}
                                    </div>
                                    <div style={{
                                        "display": "grid",
                                        "gridTemplateColumns": "70px 1fr",
                                        "gap": 6,
                                        "color": "rgba(0,0,0,0.55)"
                                    }}>
                                        <span title="Material">MAT</span>
                                        <span>{zone["material_label"] if zone["material_label"] else (zone["material"] if zone["material"] else "—")}</span>
                                        <span title="Thickness">THK</span>
                                        <span>{fmt_number(zone["thickness_mm"])} mm</span>
                                        <span title="Weld quality">WLD</span>
                                        <span>{zone["weld_label"] if zone["weld_label"] else (zone["weld_quality"] if zone["weld_quality"] else "—")}</span>
                                        <span title="Seal quality">SEL</span>
                                        <span>{zone["seal_label"] if zone["seal_label"] else (zone["seal_quality"] if zone["seal_quality"] else "—")}</span>
                                    </div>
                                </div>;
                            }
                        }
                    </div>
                </div>
            </div>;
        }}

        <div style={{
            "position": "absolute",
            "bottom": 24,
            "left": playback_center,
            "transform": "translateX(-50%)",
            "display": "flex",
            "flexDirection": "column",
            "alignItems": "center",
            "userSelect": "none",
            "transition": "left 220ms ease"
        }}>
            <div style={({
                **cell,
                "width": 120,
                "height": 32,
                "marginBottom": -1,
                "fontSize": 10,
                "fontWeight": 700,
                "letterSpacing": "0.06em",
                "textTransform": "uppercase",
                "color": "rgba(0,0,0,0.38)"
            }) as dict[str, object]}>
                {active_day_label}
            </div>

            <div style={{"display": "flex", "width": 120}}>
                <button
                    onClick={step_back}
                    disabled={not can_step_back}
                    aria-label="Step back"
                    style={({
                        **cell,
                        "width": 40,
                        "marginRight": -1,
                        "fontSize": 13,
                        "fontWeight": 700,
                        "color": "rgba(0,0,0,0.76)",
                        "cursor": "pointer" if can_step_back else "default",
                        "opacity": 1 if can_step_back else 0.22
                    }) as dict[str, object]}
                >
                    {"❮"}
                </button>

                <div style={({
                    **cell,
                    "width": 40,
                    "fontSize": 10,
                    "fontWeight": 700,
                    "letterSpacing": "0.06em",
                    "color": "rgba(0,0,0,0.55)",
                    "textTransform": "uppercase"
                }) as dict[str, object]}>
                    {"×" + str(step_speed)}
                </div>

                <button
                    onClick={step_forward}
                    disabled={not can_step_forward}
                    aria-label="Step forward"
                    style={({
                        **cell,
                        "width": 40,
                        "marginLeft": -1,
                        "fontSize": 13,
                        "fontWeight": 700,
                        "color": "rgba(0,0,0,0.76)",
                        "cursor": "pointer" if can_step_forward else "default",
                        "opacity": 1 if can_step_forward else 0.22
                    }) as dict[str, object]}
                >
                    {"❯"}
                </button>
            </div>
            <div style={{
                "marginTop": 5,
                "fontFamily": "'Courier New', monospace",
                "fontSize": 8,
                "letterSpacing": "0.03em",
                "color": "rgba(0,0,0,0.32)",
                "textTransform": "uppercase"
            }}>
                arrows step · up/down speed
            </div>
        </div>

        {if error {
            <div style={{
                "position": "absolute",
                "bottom": 16,
                "left": effective_sidebar_w + 12,
                "maxWidth": 360,
                "padding": "10px 12px",
                "background": "rgba(180,35,24,0.10)",
                "border": "1px solid rgba(180,35,24,0.35)",
                "color": "#B42318",
                "fontFamily": "'Courier New', monospace",
                "fontSize": 11,
                "zIndex": 20,
                "whiteSpace": "pre-wrap"
            }}>
                {str(error)}
            </div>;
        }}
    </div>;
}
