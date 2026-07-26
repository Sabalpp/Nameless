"""Persistent graph schema and typed API models for the SeaForge engine."""

# ---------------------------------------------------------------------------
# API input models
# ---------------------------------------------------------------------------

obj RoutePointInput {
    has name: str = "",
        lat_deg: float = 0.0,
        lon_deg: float = 0.0,
        hs_m: float = 2.5,
        tp_s: float = 9.0,
        jonswap_gamma: float = 3.3,
        encounter_angle_deg: float = 0.0,
        water_temp_c: float = 15.0,
        salinity_ppt: float = 35.0,
        ph: float = 8.1,
        wind_speed_ms: float = 10.0,
        slam_probability: float = 0.15,
        duration_scale: float = 1.0,
        wave_direction_deg: float = 0.0,
        condition_source: str = "provided",
        navigable: bool = True;
}

obj VesselInput {
    has loa_m: float = 7.3,
        beam_m: float = 2.4,
        depth_m: float = 1.1,
        draft_m: float = 0.32,
        block_coeff: float = 0.58,
        waterplane_coeff: float = 0.78,
        material: str = "MildSteelA",
        thickness_m: float = 0.004,
        weld: str = "Economy",
        seal: str = "Economy",
        max_power_kw: float = 300.0,
        fuel_capacity_kg: float = 2000.0,
        sfc_g_per_kwh: float = 220.0,
        propulsive_efficiency: float = 0.72,
        hull_drag_coeff: float = 0.007;
}

# ---------------------------------------------------------------------------
# Persistent graph nodes
# ---------------------------------------------------------------------------

node MissionNode {
    has name: str = "",
        total_distance_nm: float = 0.0,
        max_iterations: int = 20,
        attempts: int = 0,
        route_attempts: int = 0,
        best_route_id: int = 0,
        best_route_score: float = 0.0,
        route_locked: bool = False,
        solved: bool = False,
        best_cost_usd: float = 0.0,
        best_material: str = "",
        best_thickness_m: float = 0.0,
        best_weld: str = "",
        best_seal: str = "";
}

node VesselDesignNode {
    has loa_m: float = 7.3,
        beam_m: float = 2.4,
        depth_m: float = 1.1,
        draft_m: float = 0.32,
        block_coeff: float = 0.58,
        waterplane_coeff: float = 0.78,
        material: str = "MildSteelA",
        thickness_m: float = 0.004,
        weld: str = "Economy",
        seal: str = "Economy",
        max_power_kw: float = 300.0,
        fuel_capacity_kg: float = 2000.0,
        sfc_g_per_kwh: float = 220.0,
        propulsive_efficiency: float = 0.72,
        hull_drag_coeff: float = 0.007,
        revision: int = 0;
}

node WaypointNode {
    has route_id: int = 0,
        sequence: int = 0,
        name: str = "",
        lat_deg: float = 0.0,
        lon_deg: float = 0.0,
        is_origin: bool = False,
        is_destination: bool = False,
        hs_m: float = 2.5,
        tp_s: float = 9.0,
        jonswap_gamma: float = 3.3,
        encounter_angle_deg: float = 0.0,
        water_temp_c: float = 15.0,
        salinity_ppt: float = 35.0,
        ph: float = 8.1,
        wind_speed_ms: float = 10.0,
        slam_probability: float = 0.15,
        condition_source: str = "provided",
        navigable: bool = True,
        condition_score: float = 0.0;
}

node FailureTrace {
    has route_id: int = 0,
        attempt: int = 0,
        failure_mode: str = "",
        failure_zone: str = "",
        failure_reason: str = "",
        distance_completed_nm: float = 0.0,
        total_distance_nm: float = 0.0,
        elapsed_h: float = 0.0,
        fuel_remaining_kg: float = 0.0,
        gm_m: float = 0.0,
        ice_mass_kg: float = 0.0,
        material: str = "",
        thickness_m: float = 0.0,
        weld: str = "",
        seal: str = "",
        corrosion_m: list[float] = [],
        fatigue: list[float] = [],
        crack_m: list[float] = [];
}

node SuccessTrace {
    has route_id: int = 0,
        attempt: int = 0,
        cost_usd: float = 0.0,
        distance_completed_nm: float = 0.0,
        elapsed_h: float = 0.0,
        fuel_remaining_kg: float = 0.0,
        gm_m: float = 0.0,
        material: str = "",
        thickness_m: float = 0.0,
        weld: str = "",
        seal: str = "";
}

node RouteEvaluation {
    has route_id: int = 0,
        survived: bool = False,
        navigable: bool = True,
        condition_score: float = 0.0,
        distance_nm: float = 0.0,
        condition_source: str = "",
        reasoning: str = "",
        failure_reason: str = "",
        waypoint_names: list[str] = [];
}

# ---------------------------------------------------------------------------
# Typed graph relationships
# ---------------------------------------------------------------------------

edge HasDesign: MissionNode --> VesselDesignNode {}
edge StartsAt: MissionNode --> WaypointNode {}

edge RouteSegment: WaypointNode --> WaypointNode {
    has sequence: int = 0,
        distance_nm: float = 0.0,
        heading_deg: float = 0.0,
        duration_scale: float = 1.0,
        hs_m: float = 2.5,
        tp_s: float = 9.0,
        jonswap_gamma: float = 3.3,
        encounter_angle_deg: float = 0.0,
        water_temp_c: float = 15.0,
        salinity_ppt: float = 35.0,
        ph: float = 8.1,
        wind_speed_ms: float = 10.0,
        slam_probability: float = 0.15;
}

edge FailedHere: WaypointNode --> FailureTrace {}
edge CompletedHere: WaypointNode --> SuccessTrace {}
edge EvaluatedRoute: MissionNode --> RouteEvaluation {}

# ---------------------------------------------------------------------------
# Typed report/view models
# ---------------------------------------------------------------------------

obj SetupMissionResult {
    has status: str = "",
        mission_id: str = "",
        mission: str = "",
        waypoints: int = 0,
        segments: int = 0,
        total_distance_nm: float = 0.0,
        message: str = "";
}

obj VoyageResult {
    has survived: bool = False,
        route_id: int = 0,
        attempt: int = 0,
        cost_usd: float = 0.0,
        distance_nm: float = 0.0,
        total_distance_nm: float = 0.0,
        elapsed_h: float = 0.0,
        fuel_remaining_kg: float = 0.0,
        gm_m: float = 0.0,
        material: str = "",
        thickness_mm: float = 0.0,
        weld: str = "",
        seal: str = "",
        failure_mode: str = "",
        failure_zone: str = "",
        failure_reason: str = "",
        terminal_waypoint: str = "";
}

obj AttemptSummary {
    has attempt: int = 0,
        survived: bool = False,
        cost_usd: float = 0.0,
        material: str = "",
        thickness_m: float = 0.0,
        weld: str = "",
        seal: str = "",
        failure_mode: str = "",
        failure_zone: str = "",
        failure_reason: str = "",
        distance_pct: float = 0.0;
}
sem AttemptSummary = "The outcome of one vessel configuration attempting the mission";
sem AttemptSummary.attempt = "Sequential attempt number";
sem AttemptSummary.survived = "Whether the vessel walker reached the destination";
sem AttemptSummary.cost_usd = "Construction cost of the attempted configuration";
sem AttemptSummary.failure_mode = "The terminal physical failure, empty for survivors";
sem AttemptSummary.failure_zone = "The hull zone or subsystem that failed";
sem AttemptSummary.failure_reason = "Detailed physical diagnosis persisted by the graph";
sem AttemptSummary.distance_pct = "Percentage of the route completed";

obj ConfigRevision {
    has material: str = "MildSteelA",
        thickness_m: float = 0.004,
        weld: str = "Economy",
        seal: str = "Economy",
        reasoning: str = "";
}
sem ConfigRevision = "The next candidate vessel design to test";
sem ConfigRevision.material = "One of MildSteelA, MildSteelE, Ah36, Dh36, Eh36, Eh40, Aluminum5083";
sem ConfigRevision.thickness_m = "Hull plate thickness from 0.003 through 0.015 meters";
sem ConfigRevision.weld = "One of Economy, Standard, Premium";
sem ConfigRevision.seal = "One of Economy, Commercial, Marine";
sem ConfigRevision.reasoning = "A concise explanation grounded in the graph's prior attempt traces";

obj OptimizerResult {
    has status: str = "",
        mission: str = "",
        agent_backend: str = "",
        codex_model: str = "",
        fallbacks_used: int = 0,
        attempts_run: int = 0,
        survivors_found: int = 0,
        best_cost_usd: float = 0.0,
        best_material: str = "",
        best_thickness_mm: float = 0.0,
        best_weld: str = "",
        best_seal: str = "",
        history: list[AttemptSummary] = [],
        message: str = "";
}

obj RouteRevision {
    has waypoints: list[dict[str, any]] = [],
        reasoning: str = "";
}

obj RouteSummary {
    has route_id: int = 0,
        survived: bool = False,
        navigable: bool = True,
        condition_score: float = 0.0,
        distance_nm: float = 0.0,
        condition_source: str = "",
        failure_reason: str = "",
        waypoint_names: list[str] = [];
}

obj PointOptimizationResult {
    has status: str = "",
        mission_id: str = "",
        mission: str = "",
        agent_backend: str = "",
        codex_model: str = "",
        route_attempts: int = 0,
        material_attempts: int = 0,
        fallbacks_used: int = 0,
        best_route_id: int = 0,
        best_route_score: float = 0.0,
        best_route_distance_nm: float = 0.0,
        best_route_waypoints: list[str] = [],
        best_cost_usd: float = 0.0,
        best_material: str = "",
        best_thickness_mm: float = 0.0,
        best_weld: str = "",
        best_seal: str = "",
        routes: list[RouteSummary] = [],
        material_history: list[AttemptSummary] = [],
        simulation_file: str = "",
        simulation_error: str = "",
        message: str = "";
}

obj FailureView {
    has attempt: int = 0,
        waypoint: str = "",
        mode: str = "",
        zone: str = "",
        reason: str = "",
        distance_pct: float = 0.0,
        material: str = "",
        thickness_mm: float = 0.0,
        weld: str = "",
        seal: str = "";
}

obj WaypointView {
    has id: str = "",
        route_id: int = 0,
        sequence: int = 0,
        name: str = "",
        lat_deg: float = 0.0,
        lon_deg: float = 0.0,
        is_origin: bool = False,
        is_destination: bool = False,
        failures: int = 0,
        successes: int = 0,
        hs_m: float = 0.0,
        tp_s: float = 0.0,
        wind_speed_ms: float = 0.0,
        water_temp_c: float = 0.0,
        condition_source: str = "",
        condition_score: float = 0.0;
}

obj MissionView {
    has found: bool = False,
        mission_id: str = "",
        name: str = "",
        total_distance_nm: float = 0.0,
        attempts: int = 0,
        solved: bool = False,
        best_cost_usd: float = 0.0,
        best_route_id: int = 0,
        best_route_score: float = 0.0,
        current_material: str = "",
        current_thickness_mm: float = 0.0,
        current_weld: str = "",
        current_seal: str = "",
        waypoints: list[WaypointView] = [],
        failures: list[FailureView] = [],
        message: str = "";
}
