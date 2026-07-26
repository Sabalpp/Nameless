def run_codex_route_planner(
    prompt: str,
    model: str = ...,
    timeout_s: int = ...,
) -> str: ...

def enrich_route_points(
    points_json: str,
    use_live_conditions: bool = ...,
    timeout_s: int = ...,
) -> str: ...

def save_simulation_trace(trace_json: str) -> str: ...
