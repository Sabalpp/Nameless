"""Frozen type contract for SeaForge Jac port.

Every engine module imports from here. Do not add runtime logic to this file.
"""

# ---------------------------------------------------------------------------
# Hull zones
# ---------------------------------------------------------------------------

enum HullZone {
    KEEL = "Keel",
    BILGE_STRAKE = "BilgeStrake",
    BOTTOM_PLATING = "BottomPlating",
    SIDE_PLATING = "SidePlating",
    BOW_FLARE = "BowFlare",
    STERN_PLATE = "SternPlate",
    TRANSOM_FRAME = "TransomFrame",
    WEATHER_DECK = "WeatherDeck",
    BULKHEAD_FRAME = "BulkheadFrame",
}

def all_hull_zones() -> list[HullZone] {
    return [
        HullZone.KEEL,
        HullZone.BILGE_STRAKE,
        HullZone.BOTTOM_PLATING,
        HullZone.SIDE_PLATING,
        HullZone.BOW_FLARE,
        HullZone.STERN_PLATE,
        HullZone.TRANSOM_FRAME,
        HullZone.WEATHER_DECK,
        HullZone.BULKHEAD_FRAME,
    ];
}

def hull_zone_label(zone: HullZone) -> str {
    match zone {
        case HullZone.KEEL: return "Keel";
        case HullZone.BILGE_STRAKE: return "Bilge Strake";
        case HullZone.BOTTOM_PLATING: return "Bottom Plating";
        case HullZone.SIDE_PLATING: return "Side Plating";
        case HullZone.BOW_FLARE: return "Bow Flare";
        case HullZone.STERN_PLATE: return "Stern Plate";
        case HullZone.TRANSOM_FRAME: return "Transom Frame";
        case HullZone.WEATHER_DECK: return "Weather Deck";
        case HullZone.BULKHEAD_FRAME: return "Bulkhead Frame";
        case _: return str(zone);
    }
}

def hull_zone_bending_factor(zone: HullZone) -> float {
    match zone {
        case HullZone.KEEL: return 1.35;
        case HullZone.BILGE_STRAKE: return 1.20;
        case HullZone.BOTTOM_PLATING: return 1.10;
        case HullZone.SIDE_PLATING: return 0.75;
        case HullZone.BOW_FLARE: return 1.05;
        case HullZone.STERN_PLATE: return 0.85;
        case HullZone.TRANSOM_FRAME: return 0.60;
        case HullZone.WEATHER_DECK: return 0.90;
        case HullZone.BULKHEAD_FRAME: return 0.70;
        case _: return 1.0;
    }
}

def hull_zone_slam_factor(zone: HullZone) -> float {
    match zone {
        case HullZone.BOW_FLARE: return 2.80;
        case HullZone.KEEL: return 1.80;
        case HullZone.BILGE_STRAKE: return 1.40;
        case HullZone.BOTTOM_PLATING: return 1.20;
        case _: return 1.00;
    }
}

def hull_zone_is_submerged(zone: HullZone) -> bool {
    return zone in [HullZone.KEEL, HullZone.BILGE_STRAKE, HullZone.BOTTOM_PLATING];
}

def parse_hull_zone(key: str) -> HullZone | None {
    normalized = "".join(c.lower() for c in key if c.isalnum());
    match normalized {
        case "keel": return HullZone.KEEL;
        case "bilgestrake" | "bilgestr": return HullZone.BILGE_STRAKE;
        case "bottomplating": return HullZone.BOTTOM_PLATING;
        case "sideplating": return HullZone.SIDE_PLATING;
        case "bowflare": return HullZone.BOW_FLARE;
        case "sternplate": return HullZone.STERN_PLATE;
        case "transomframe": return HullZone.TRANSOM_FRAME;
        case "weatherdeck": return HullZone.WEATHER_DECK;
        case "bulkheadframe": return HullZone.BULKHEAD_FRAME;
        case _: return None;
    }
}

# ---------------------------------------------------------------------------
# Materials
# ---------------------------------------------------------------------------

enum MaterialGrade {
    MILD_STEEL_A = "MildSteelA",
    MILD_STEEL_E = "MildSteelE",
    AH36 = "Ah36",
    DH36 = "Dh36",
    EH36 = "Eh36",
    EH40 = "Eh40",
    ALUMINUM_5083 = "Aluminum5083",
    GRP_E_GLASS = "GrpEGlass",
    CFRP_EPOXY = "CfrpEpoxy",
}

enum WeldQuality {
    PREMIUM = "Premium",
    STANDARD = "Standard",
    ECONOMY = "Economy",
}

enum SealQuality {
    MARINE = "Marine",
    COMMERCIAL = "Commercial",
    ECONOMY = "Economy",
}

obj MaterialSpec {
    has label: str,
        density_kg_m3: float,
        yield_mpa: float,
        uts_mpa: float,
        e_gpa: float,
        k_ic_mpa_sqrtm: float,
        min_temp_c: float,
        sn_slope: float,
        sn_ref_stress_mpa: float,
        sn_ref_cycles: int,
        cost_per_kg_usd: float,
        base_corrosion_rate_mm_yr: float;
}

obj MaterialConfig {
    has grade: str | None = None,
        label: str | None = None,
        strength_index: float | None = None,
        cost: float | None = None,
        cost_unit: str | None = None,
        heat_threshold_c: float | None = None,
        cold_threshold_c: float | None = None,
        dust_coeff: float | None = None,
        humidity_coeff: float | None = None,
        salinity_coeff: float | None = None,
        uv_coeff: float | None = None,
        density_kg_m3: float | None = None,
        yield_mpa: float | None = None,
        uts_mpa: float | None = None,
        e_gpa: float | None = None,
        k_ic_mpa_sqrtm: float | None = None,
        min_temp_c: float | None = None,
        sn_slope: float | None = None,
        sn_ref_stress_mpa: float | None = None,
        sn_ref_cycles: int | None = None,
        cost_per_kg_usd: float | None = None,
        base_corrosion_rate_mm_yr: float | None = None;
}

# MaterialModel is either a grade string key or a full MaterialConfig object.
# Runtime code in materials.jac resolves this union.
type MaterialModel = MaterialGrade | MaterialConfig | str;

# ---------------------------------------------------------------------------
# Hull geometry & propulsion
# ---------------------------------------------------------------------------

obj HullGeometry {
    has loa_m: float,
        beam_m: float,
        depth_m: float,
        draft_m: float,
        block_coeff: float,
        waterplane_coeff: float;
}

obj PropulsionSpec {
    has max_power_kw: float,
        fuel_capacity_kg: float,
        sfc_g_per_kwh: float,
        propulsive_efficiency: float,
        hull_drag_coeff: float;
}

obj ZoneSpec {
    has zone: HullZone,
        material: MaterialModel,
        thickness_m: float,
        weld_quality: WeldQuality,
        seal_quality: SealQuality;
}

obj VesselConfig {
    has hull: HullGeometry,
        zones: list[ZoneSpec],
        propulsion: PropulsionSpec;
}

# ---------------------------------------------------------------------------
# Runtime state
# ---------------------------------------------------------------------------

obj ZoneState {
    has zone: HullZone,
        fatigue_consumed: float = 0.0,
        corrosion_depth_m: float = 0.0,
        crack_half_length_m: float = 0.0;
}

obj VesselState {
    has distance_nm: float = 0.0,
        elapsed_h: float = 0.0,
        fuel_kg: float = 0.0,
        gm_m: float = 0.0,
        speed_kts: float = 0.0,
        zones: list[ZoneState] = [],
        ice_mass_kg: float = 0.0;
}

# ---------------------------------------------------------------------------
# Environment & route
# ---------------------------------------------------------------------------

obj GeoPoint {
    has lat_deg: float,
        lon_deg: float;
}

obj OceanConditions {
    has hs_m: float,
        tp_s: float,
        jonswap_gamma: float,
        encounter_angle_deg: float,
        water_temp_c: float,
        salinity_ppt: float,
        ph: float,
        wind_speed_ms: float,
        slam_probability: float;
}

obj RouteSegment {
    has from_pt: GeoPoint,
        to_pt: GeoPoint,
        distance_nm: float,
        heading_deg: float,
        conditions: OceanConditions,
        label: str,
        duration_scale: float = 1.0;
}

obj VoyageRoute {
    has origin: GeoPoint,
        destination: GeoPoint,
        segments: list[RouteSegment];
}

# ---------------------------------------------------------------------------
# Failure modes (tagged union via kind + payload fields)
# ---------------------------------------------------------------------------

enum FailureModeKind {
    CAPSIZE = "Capsize",
    FATIGUE_FAILURE = "FatigueFailure",
    BRITTLE_FRACTURE = "BrittleFracture",
    FUEL_EXHAUSTION = "FuelExhaustion",
    SEAL_BREACH_FLOODING = "SealBreachFlooding",
    COLD_TEMPERATURE_BRITTLENESS = "ColdTemperatureBrittleness",
}

obj FailureMode {
    has kind: FailureModeKind,
        gm_m: float = 0.0,
        gm_required_m: float = 0.0,
        zone: HullZone | None = None,
        damage_accumulated: float = 0.0,
        crack_half_length_m: float = 0.0,
        k_applied_mpa_sqrtm: float = 0.0,
        k_ic_mpa_sqrtm: float = 0.0,
        distance_remaining_nm: float = 0.0,
        elapsed_h: float = 0.0,
        water_temp_c: float = 0.0,
        min_rated_temp_c: float = 0.0;
}

obj FailureDiagnosis {
    has mode: FailureMode,
        distance_completed_nm: float,
        total_distance_nm: float,
        segment_index: int,
        segment_label: str,
        elapsed_h: float;
}

obj ZoneSummary {
    has zone: HullZone,
        fatigue_consumed: float,
        corrosion_depth_mm: float,
        crack_half_length_mm: float,
        peak_stress_mpa: float;
}

obj SegmentSnapshot {
    has segment_index: int,
        segment_label: str,
        distance_completed_nm: float,
        elapsed_h: float,
        speed_kts: float,
        fuel_remaining_kg: float,
        gm_m: float,
        zones: list[ZoneSummary],
        failure: str | None = None;
}

obj SimOutcome {
    has failure: FailureDiagnosis | None = None,
        distance_completed_nm: float = 0.0,
        total_distance_nm: float = 0.0,
        time_elapsed_h: float = 0.0,
        fuel_remaining_kg: float = 0.0,
        final_gm_m: float = 0.0,
        zone_summaries: list[ZoneSummary] = [],
        total_config_cost_usd: float = 0.0,
        ticks: list[SegmentSnapshot] = [];
}

# ---------------------------------------------------------------------------
# Optimizer & search
# ---------------------------------------------------------------------------

obj SearchSpace {
    has hull: HullGeometry,
        propulsion: PropulsionSpec,
        materials: list[str],
        weld_qualities: list[str],
        seal_qualities: list[str],
        thicknesses_m: list[float];
}

obj SurvivorEntry {
    has material: str,
        thickness_mm: float,
        weld_quality: str,
        seal_quality: str,
        cost_usd: float,
        fuel_remaining_kg: float,
        final_gm_m: float,
        worst_zone_fatigue: float;
}

obj OptimizerResult {
    has configs_tested: int,
        survivors_found: int,
        cheapest_survivor: SurvivorEntry | None = None,
        all_survivors: list[SurvivorEntry] = [],
        failure_summary: dict[str, int] = {};
}

# ---------------------------------------------------------------------------
# Mission brief
# ---------------------------------------------------------------------------

obj MissionBrief {
    has id: str,
        name: str,
        origin: dict,
        destination: dict,
        waypoints: list[dict] = [],
        distance_nm: float = 0.0,
        expected_duration_days: float = 0.0,
        primary_stressor: str = "",
        environmental_profile: dict = {},
        zones: list[ZoneSpec] | None = None,
        propulsion: PropulsionSpec | None = None;
}

# ---------------------------------------------------------------------------
# Simulation params (partial overrides for simulate-params command)
# ---------------------------------------------------------------------------

obj SimulationParams {
    has hull: HullGeometry | None = None,
        propulsion: PropulsionSpec | None = None,
        construction: dict | None = None,
        zones: list[ZoneSpec] | None = None,
        route: dict | None = None,
        conditions: OceanConditions | None = None;
}

# ---------------------------------------------------------------------------
# Cost breakdown
# ---------------------------------------------------------------------------

obj CostBreakdown {
    has material_usd: float,
        weld_usd: float,
        seal_usd: float,
        fuel_capacity_usd: float = 0.0;
}

# ---------------------------------------------------------------------------
# LLM agent types
# ---------------------------------------------------------------------------

enum FailedMetric {
    FATIGUE = "fatigue",
    CORROSION = "corrosion",
    CRACK = "crack",
    FUEL = "fuel",
    STABILITY = "stability",
    SEAL = "seal",
    TEMPERATURE = "temperature",
}

obj ZoneProposal {
    has zone: HullZone,
        material: str,
        thickness_m: float,
        weld_quality: WeldQuality,
        seal_quality: SealQuality;
}

obj BriefAssessment {
    has assessment: str,
        failed_part: str = "",
        failed_metric: FailedMetric | None = None,
        root_cause: str = "",
        changes: list[str] = [],
        zones: list[ZoneProposal] = [],
        propulsion: PropulsionSpec | None = None;
}

obj SearchContext {
    has mission: MissionBrief | None = None,
        current_zones: list[ZoneSpec] = [],
        current_propulsion: PropulsionSpec | None = None,
        latest_result: dict = {},
        best_survivor: dict | None = None,
        best_potential: dict | None = None,
        recent_history: list[dict] = [],
        design_memory: dict = {},
        search_directive: str = "",
        iteration: int = 0,
        survived: bool = False;
}

# ---------------------------------------------------------------------------
# Graph persistence nodes
# ---------------------------------------------------------------------------

node Campaign {
    has mission_id: str,
        tier: str,
        model: str,
        status: str,
        started_at: str,
        completed_at: str | None = None,
        max_iterations: int = 50,
        stopped: bool = False;
}

node Iteration {
    has index: int,
        status: str,
        params: dict = {},
        result: dict | None = None,
        assessment: dict | None = None,
        eval_data: dict | None = None,
        created_at: str = "";
}

node DesignMemory {
    has lessons: list[str] = [],
        campaign_id: str = "";
}

# Simulation tuning constants (must match Rust voyage.rs exactly)
glob SIM_STEP_H: float = 1.0;
glob SIM_TIME_MULTIPLIER: float = 100.0;
glob DAMAGE_RATE_MULTIPLIER: float = 3.4;
glob CRACK_GROWTH_MULTIPLIER: float = 0.12;
glob CORROSION_RATE_MULTIPLIER: float = 5.0;
glob FATIGUE_THRESHOLD: float = 0.75;
glob NET_THICKNESS_FLOOR: float = 0.35;
