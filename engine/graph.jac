"""Campaign / Iteration / DesignMemory graph operations.

Replaces the simulations/ filesystem tree and SIGTERM process control from
ui/server.js with persistent nodes under root and in-process active-run state.
Node archetypes live in engine.types — this module only operates on them.
"""

import re;
import from datetime { datetime, timezone }
import from os { environ }

import from engine.types {
    Campaign,
    DesignMemory,
    Iteration
}

# Default max iterations — mirrors gemini_runner/config.js
glob MAX_ITERATIONS: int = 50;

# In-process active Gemini campaign (replaces child_process handle).
# Shape: {run_id, mission_id, started_at, max_iterations, campaign_jid} | None
glob ACTIVE_GEMINI_RUN: dict[str, any] | None = None;

# ---------------------------------------------------------------------------
# Time / clamp
# ---------------------------------------------------------------------------

def iso_now() -> str {
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z");
}

def clamp(value: float, lo: float, hi: float) -> float {
    if value < lo { return lo; }
    if value > hi { return hi; }
    return value;
}

# ---------------------------------------------------------------------------
# Score evaluation (port of ui/server.js::evaluateSimulation)
# ---------------------------------------------------------------------------

def:priv _as_dict(value: any) -> dict[str, any] {
    if isinstance(value, dict) {
        return value as dict[str, any];
    }
    return {};
}

def:priv _as_list(value: any) -> list[any] {
    if isinstance(value, list) {
        return value as list[any];
    }
    return [];
}

def:priv _num(value: any, fallback: float = 0.0) -> float {
    if value is None {
        return fallback;
    }
    try {
        return float(str(value));
    } except Exception {
        return fallback;
    }
}

"""Score a simulation envelope dict the same way the Express API did."""
def evaluate_simulation(result: dict[str, any]) -> dict[str, float | str | None] {
    result_block = _as_dict(result.get("result"));
    failure_block = _as_dict(result.get("failure"));
    voyage_block = _as_dict(result.get("voyage"));

    voyage_pct = clamp(_num(result_block.get("distance_completed_pct")), 0.0, 100.0);
    elapsed_h = _num(
        failure_block.get("elapsed_h", result_block.get("time_elapsed_h", 0))
    );

    route_segments = _as_list(voyage_block.get("route_segments"));
    distance_nm = _num(result_block.get("distance_completed_nm"));
    avg_speed_kts = (
        distance_nm / elapsed_h if elapsed_h > 0.0 and distance_nm > 0.0 else 58.0
    );
    total_distance_nm = (
        distance_nm / (voyage_pct / 100.0)
        if voyage_pct > 0.0 and distance_nm > 0.0
        else distance_nm
    );
    expected_h = (
        total_distance_nm / max(avg_speed_kts, 1.0)
        if total_distance_nm > 0.0
        else float(len(route_segments)) * 8.0
    );

    status = str(result.get("status", ""));
    if status == "survived" {
        time_score = 100.0;
    } else {
        time_score = clamp((elapsed_h / max(expected_h, 1.0)) * 100.0, 0.0, 100.0);
    }

    detail = _as_dict(failure_block.get("detail"));
    failed_part = str(detail.get("failed_zone", "") or "");

    component_penalty_map: dict[str, float] = {
        "Keel": 34.0,
        "Bottom Plating": 30.0,
        "Bilge Strake": 28.0,
        "Bow Flare": 24.0,
        "Side Plating": 20.0,
        "Stern Plate": 18.0,
        "Weather Deck": 16.0,
        "Transom Frame": 14.0,
        "Bulkhead Frame": 12.0,
        "Propulsion": 22.0
    };
    if failed_part in component_penalty_map {
        component_penalty = component_penalty_map[failed_part];
    } elif status == "survived" {
        component_penalty = 0.0;
    } else {
        component_penalty = 18.0;
    }
    component_score = clamp(100.0 - component_penalty, 0.0, 100.0);

    ticks = _as_list(result.get("ticks"));
    last_tick: dict[str, any] = {};
    if len(ticks) > 0 {
        last_tick = _as_dict(ticks[len(ticks) - 1]);
    }
    zones = _as_list(last_tick.get("zones"));

    max_fatigue = 0.0;
    max_crack_mm = 0.0;
    max_corrosion_mm = 0.0;
    for zone_any in zones {
        zone = _as_dict(zone_any);
        max_fatigue = max(max_fatigue, _num(zone.get("fatigue_consumed")));
        max_crack_mm = max(max_crack_mm, _num(zone.get("crack_half_length_mm")));
        max_corrosion_mm = max(max_corrosion_mm, _num(zone.get("corrosion_depth_mm")));
    }

    gm_m = _num(last_tick.get("gm_m", result_block.get("final_gm_m", 0)));
    fuel_remaining_kg = _num(
        last_tick.get("fuel_remaining_kg", result_block.get("fuel_remaining_kg", 0))
    );

    severity_penalty = (
        min(70.0, max_fatigue * 42.0)
        + min(15.0, max_crack_mm * 0.6)
        + min(10.0, max_corrosion_mm * 8.0)
        + (min(12.0, max(0.0, 0.8 - gm_m) * 15.0) if gm_m > 0.0 else 0.0)
        + (
            min(10.0, max(0.0, 250.0 - fuel_remaining_kg) / 25.0)
            if fuel_remaining_kg > 0.0
            else 10.0
        )
    );
    severity_score = clamp(100.0 - severity_penalty, 0.0, 100.0);

    cost_usd = _num(result_block.get("total_config_cost_usd"));
    cost_score = clamp(100.0 - ((cost_usd - 5000.0) / 15000.0) * 100.0, 0.0, 100.0);

    progress_gate = voyage_pct / 100.0;
    if status == "survived" {
        score = 100.0;
    } else {
        score = clamp(
            voyage_pct * 0.82
            + time_score * 0.10
            + (
                component_score * 0.03
                + severity_score * 0.03
                + cost_score * 0.02
            ) * progress_gate,
            0.0,
            100.0
        );
    }

    first_failed: str | None = failed_part if failed_part else None;
    time_out: float | None = float(int(elapsed_h * 10.0 + 0.5)) / 10.0;
    cost_out: float | None = float(int(cost_usd + 0.5));

    return {
        "score_pct": float(int(score + 0.5)),
        "distance_pct": float(int(voyage_pct + 0.5)),
        "time_to_failure_h": time_out,
        "first_failed_component": first_failed,
        "severity_score": float(int(severity_score + 0.5)),
        "material_cost_usd": cost_out
    };
}

# ---------------------------------------------------------------------------
# Active Gemini run (in-process)
# ---------------------------------------------------------------------------

def active_gemini_status() -> dict[str, any] {
    run = ACTIVE_GEMINI_RUN;
    inactive: dict[str, any] = {
        "active": False,
        "run_id": None,
        "mission_id": None,
        "started_at": None,
        "max_iterations": None
    };
    if run is None {
        return inactive;
    }

    # If the Campaign node was marked stopped/completed, clear the handle.
    jid_str = str(run.get("campaign_jid", "") or "");
    if jid_str {
        target = jobj(jid_str);
        if isinstance(target, Campaign) {
            if target.stopped or target.status in ["completed", "stopped", "error"] {
                ACTIVE_GEMINI_RUN = None;
                return inactive;
            }
        }
    }

    return {
        "active": True,
        "run_id": run.get("run_id", None),
        "mission_id": run.get("mission_id", None),
        "started_at": run.get("started_at", None),
        "max_iterations": run.get("max_iterations", None)
    };
}

def set_active_gemini_run(
    run_id: str,
    mission_id: str,
    started_at: str,
    max_iterations: int,
    campaign_jid: str
) {
    ACTIVE_GEMINI_RUN = {
        "run_id": run_id,
        "mission_id": mission_id,
        "started_at": started_at,
        "max_iterations": max_iterations,
        "campaign_jid": campaign_jid
    } as dict[str, any];
}

def clear_active_gemini_run() {
    ACTIVE_GEMINI_RUN = None;
}

"""Cooperative stop: flip Campaign.stopped and clear the in-process handle.

Returns True if an active run was signalled to stop.
"""
def stop_active_gemini_run() -> bool {
    status = active_gemini_status();
    if not status["active"] {
        return False;
    }
    run = ACTIVE_GEMINI_RUN;
    if run is None {
        return False;
    }
    jid_str = str(run.get("campaign_jid", "") or "");
    if jid_str {
        target = jobj(jid_str);
        if isinstance(target, Campaign) {
            target.stopped = True;
            target.status = "stopped";
            target.completed_at = iso_now();
        }
    }
    ACTIVE_GEMINI_RUN = None;
    return True;
}

def gemini_api_key_present() -> bool {
    key = environ.get("GEMINI_API_KEY") or environ.get("GOOGLE_API_KEY") or "";
    return bool(key);
}

# ---------------------------------------------------------------------------
# Campaign / Iteration / DesignMemory CRUD
# ---------------------------------------------------------------------------

"""Create a Campaign (+ empty DesignMemory) under root. Returns the Campaign."""
def create_campaign(
    mission_id: str,
    tier: str,
    model: str,
    max_iterations: int,
    run_id: str
) -> Campaign {
    started = iso_now();
    created = root ++> Campaign(
        mission_id=mission_id,
        tier=tier,
        model=model,
        status="running",
        started_at=started,
        completed_at=None,
        max_iterations=max_iterations,
        stopped=False
    );
    campaign = created[0] as Campaign;

    # Persist logical run_id on DesignMemory.campaign_id (types.jac has no run_id field).
    mem_list = root ++> DesignMemory(lessons=[], campaign_id=run_id);
    memory = mem_list[0] as DesignMemory;
    campaign ++> memory;

    return campaign;
}

def campaign_run_id(campaign: Campaign) -> str {
    memories = [campaign -->][?:DesignMemory];
    if len(memories) > 0 and memories[0].campaign_id {
        return memories[0].campaign_id;
    }
    # Fallback: stable graph id
    return jid(campaign);
}

def get_design_memory(campaign: Campaign) -> DesignMemory | None {
    memories = [campaign -->][?:DesignMemory];
    if len(memories) > 0 {
        return memories[0];
    }
    return None;
}

def append_design_lesson(campaign: Campaign, lesson: str) {
    memory = get_design_memory(campaign);
    if memory is None {
        run_id = jid(campaign);
        mem_list = campaign ++> DesignMemory(lessons=[lesson], campaign_id=run_id);
        _ = mem_list;
        return;
    }
    memory.lessons = memory.lessons + [lesson];
}

"""Attach a completed iteration under a Campaign and return it."""
def store_iteration(
    campaign: Campaign,
    index: int,
    status: str,
    params: dict,
    result: dict | None,
    assessment: dict | None
) -> Iteration {
    eval_data: dict | None = None;
    if result is not None {
        eval_data = evaluate_simulation(result);
    }
    created = campaign ++> Iteration(
        index=index,
        status=status,
        params=params,
        result=result,
        assessment=assessment,
        eval_data=eval_data,
        created_at=iso_now()
    );
    return created[0] as Iteration;
}

def complete_campaign(campaign: Campaign, status: str = "completed") {
    campaign.status = status;
    campaign.completed_at = iso_now();
    if status == "stopped" {
        campaign.stopped = True;
    }
}

def find_campaign_by_run_id(run_id: str) -> Campaign | None {
    for campaign in [root -->][?:Campaign] {
        if campaign_run_id(campaign) == run_id {
            return campaign;
        }
    }
    # Also accept raw jid
    target = jobj(run_id) if run_id else None;
    if isinstance(target, Campaign) {
        return target;
    }
    return None;
}

def find_iteration(campaign: Campaign, index: int) -> Iteration | None {
    for it in [campaign -->][?:Iteration] {
        if it.index == index {
            return it;
        }
    }
    return None;
}

# ---------------------------------------------------------------------------
# Listing / lookup (replaces simulationEntries / GET /api/simulation)
# ---------------------------------------------------------------------------

def:priv _assessment_view(assessment: dict[str, any] | None) -> dict[str, any] {
    if assessment is None {
        return {};
    }
    return {
        "assessment": assessment.get("assessment"),
        "failed_part": assessment.get("failed_part", None),
        "failed_metric": assessment.get("failed_metric", None),
        "root_cause": assessment.get("root_cause", None),
        "model_used": assessment.get("model_used", None),
        "changes": assessment.get("changes", [])
    };
}

"""List every stored iteration across all Campaigns (newest id first)."""
def list_simulation_entries() -> list[dict[str, any]] {
    entries: list[dict[str, any]] = [];
    for campaign in [root -->][?:Campaign] {
        run_id = campaign_run_id(campaign);
        for it in [campaign -->][?:Iteration] {
            if it.result is None or it.assessment is None {
                continue;
            }
            result = it.result;
            eval_data = (
                it.eval_data
                if it.eval_data is not None
                else evaluate_simulation(result)
            );
            entries.append({
                "id": f"{run_id}/iteration-{it.index}",
                "run_id": run_id,
                "iteration": it.index,
                "status": result.get("status", it.status),
                "failure": result.get("failure", None),
                "result": result.get("result", None),
                "eval": eval_data,
                "assessment": _assessment_view(it.assessment),
                "params": it.params,
                "created_at": campaign.started_at if campaign.started_at else run_id
            });
        }
    }
    entries.sort(key=_entry_id_key, reverse=True);
    return entries;
}

def:priv _entry_id_key(e: dict[str, any]) -> str {
    return str(e.get("id", ""));
}

def:priv _entry_iter_key(e: dict[str, any]) -> int {
    return int(e.get("iteration", 0));
}

"""Parse id like '<run_id>/iteration-12' → (run_id, index) or None."""
def parse_simulation_id(sim_id: str) -> tuple[str, int] | None {
    matched = re.match(r"^(.+)/iteration-(\d+)$", sim_id);
    if matched is None {
        return None;
    }
    return (str(matched.group(1)), int(matched.group(2)));
}

"""Load one saved simulation by '<run_id>/iteration-N'."""
def get_simulation(sim_id: str) -> dict[str, any] | None {
    parsed = parse_simulation_id(sim_id);
    if parsed is None {
        return None;
    }
    (run_id, index) = parsed;
    campaign = find_campaign_by_run_id(run_id);
    if campaign is None {
        return None;
    }
    it = find_iteration(campaign, index);
    if it is None {
        return None;
    }
    if it.result is None {
        return None;
    }
    if it.assessment is None {
        return {"error": "simulation is still running analysis", "pending": True};
    }
    return {
        "id": sim_id,
        "result": it.result,
        "assessment": it.assessment,
        "params": it.params
    };
}

"""Build a manifest dict shaped like the Node gemini_runner stdout."""
def campaign_manifest(campaign: Campaign) -> dict[str, any] {
    run_id = campaign_run_id(campaign);
    iterations: list[dict[str, any]] = [];
    for it in [campaign -->][?:Iteration] {
        result: dict[str, any] = it.result if it.result is not None else {};
        result_inner = _as_dict(result.get("result"));
        iterations.append({
            "id": f"{run_id}/iteration-{it.index}",
            "run_id": run_id,
            "iteration": it.index,
            "status": result.get("status", it.status),
            "failure": result.get("failure", None),
            "result": result.get("result", None),
            "total_config_cost_usd": result_inner.get("total_config_cost_usd"),
            "assessment": it.assessment,
            "params": it.params
        });
    }
    iterations.sort(key=_entry_iter_key);
    return {
        "run_id": run_id,
        "mission_id": campaign.mission_id,
        "tier": campaign.tier,
        "model": campaign.model,
        "status": campaign.status,
        "started_at": campaign.started_at,
        "completed_at": campaign.completed_at,
        "max_iterations": campaign.max_iterations,
        "stopped": campaign.stopped,
        "iterations": iterations
    };
}
