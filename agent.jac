"""LLM-in-the-loop config optimizer — port of gemini_runner/run_gemini_simulations.js.

Deterministic search logic (escalation, exploration, scoring, memory) stays as
ordinary Jac. The Gemini prompt + JSON-repair layer collapses into one typed
`by llm()` call with ModelPool fallback.
"""

import json;
import os;
import from datetime { datetime, timezone }
import from pathlib { Path }

import from jaclang.byllm.lib { Model, ModelPool, MockLLM }

import from engine.types {
    BriefAssessment,
    FailedMetric,
    HullZone,
    MaterialGrade,
    MissionBrief,
    PropulsionSpec,
    SearchContext,
    SealQuality,
    WeldQuality,
    ZoneProposal,
    ZoneSpec,
    parse_hull_zone
}
import from engine.brief {
    run_brief,
    parse_mission_brief,
    default_sim_propulsion
}
import from engine.voyage { run_voyage }
import from engine.envelope { build_output }
import from engine.materials { parse_material, parse_weld, parse_seal }

# ---------------------------------------------------------------------------
# Constants (match gemini_runner)
# ---------------------------------------------------------------------------

glob MAX_ITERATIONS: int = 50;
glob MIN_THICKNESS_M: float = 0.003;
glob MAX_THICKNESS_M: float = 0.10;
glob ROOT: Path = Path(".").resolve();
glob MISSION_BRIEFS_DIR: Path = ROOT / "mission-briefs";
glob GLOBAL_DESIGN_MEMORY_FILE: Path = ROOT / "gemini_runner" / "design_memory.json";
glob SIM_DIR: Path = ROOT / "simulations";

glob HULL_ZONE_KEYS: list[str] = [
    "Keel",
    "BilgeStrake",
    "BottomPlating",
    "SidePlating",
    "BowFlare",
    "SternPlate",
    "TransomFrame",
    "WeatherDeck",
    "BulkheadFrame"
];

glob MATERIALS: list[str] = [
    "MildSteelA",
    "Eh36",
    "Aluminum5083",
    "GrpEGlass",
    "CfrpEpoxy",
    "TitaniumGrade5",
    "NickelAlloy625",
    "KevlarComposite",
    "TungstenCarbide"
];

glob WELD_QUALITIES: list[str] = ["Economy", "Standard", "Premium"];
glob SEAL_QUALITIES: list[str] = ["Economy", "Marine"];

glob DEFAULT_PROPULSION: dict[str, float] = {
    "max_power_kw": 300.0,
    "fuel_capacity_kg": 2000.0,
    "sfc_g_per_kwh": 220.0,
    "propulsive_efficiency": 0.72,
    "hull_drag_coeff": 0.007
};

glob EXPLORATION_STRATEGIES: list[str] = [
    "targeted_reinforcement",
    "weld_quality_path",
    "material_substitution",
    "lightweight_composite_path",
    "fuel_drag_tradeoff",
    "cost_cut_from_best"
];

# ---------------------------------------------------------------------------
# byLLM — ModelPool fallback (gemini chain) or MockLLM for tests
# ---------------------------------------------------------------------------

glob _MOCK_ASSESSMENT: str = json.dumps({
    "assessment": "Mock local repair: reinforce failed zone.",
    "failed_part": "Keel",
    "failed_metric": "fatigue",
    "root_cause": "MockLLM deterministic response for tests",
    "changes": ["Keel: Eh36, 8.0mm, Premium weld, Marine seal"],
    "zones": [
        {
            "zone": "Keel",
            "material": "Eh36",
            "thickness_m": 0.008,
            "weld_quality": "Premium",
            "seal_quality": "Marine"
        },
        {
            "zone": "BilgeStrake",
            "material": "MildSteelA",
            "thickness_m": 0.004,
            "weld_quality": "Economy",
            "seal_quality": "Economy"
        },
        {
            "zone": "BottomPlating",
            "material": "MildSteelA",
            "thickness_m": 0.004,
            "weld_quality": "Economy",
            "seal_quality": "Economy"
        },
        {
            "zone": "SidePlating",
            "material": "MildSteelA",
            "thickness_m": 0.004,
            "weld_quality": "Economy",
            "seal_quality": "Economy"
        },
        {
            "zone": "BowFlare",
            "material": "MildSteelA",
            "thickness_m": 0.004,
            "weld_quality": "Economy",
            "seal_quality": "Economy"
        },
        {
            "zone": "SternPlate",
            "material": "MildSteelA",
            "thickness_m": 0.004,
            "weld_quality": "Economy",
            "seal_quality": "Economy"
        },
        {
            "zone": "TransomFrame",
            "material": "MildSteelA",
            "thickness_m": 0.004,
            "weld_quality": "Economy",
            "seal_quality": "Economy"
        },
        {
            "zone": "WeatherDeck",
            "material": "MildSteelA",
            "thickness_m": 0.004,
            "weld_quality": "Economy",
            "seal_quality": "Economy"
        },
        {
            "zone": "BulkheadFrame",
            "material": "MildSteelA",
            "thickness_m": 0.004,
            "weld_quality": "Economy",
            "seal_quality": "Economy"
        }
    ],
    "propulsion": {
        "max_power_kw": 300.0,
        "fuel_capacity_kg": 2000.0,
        "sfc_g_per_kwh": 220.0,
        "propulsive_efficiency": 0.72,
        "hull_drag_coeff": 0.007
    }
});

def:priv _make_llm() -> any {
    if os.environ.get("JAC_AGENT_MOCK", "") == "1" {
        return MockLLM(
            model_name="mockllm",
            config={"outputs": [_MOCK_ASSESSMENT]}
        );
    }
    models_env = os.environ.get(
        "GEMINI_MODEL",
        "gemini/gemini-2.5-flash,gemini/gemini-1.5-flash,gemini/gemini-2.0-flash"
    );
    model_names: list[str] = [];
    for part in models_env.split(",") {
        name = part.strip();
        if name {
            if not name.startswith("gemini/") and name.startswith("gemini") {
                name = "gemini/" + name;
            }
            model_names.append(name);
        }
    }
    if len(model_names) == 0 {
        model_names = ["gemini/gemini-2.5-flash"];
    }
    pool_models: list = [];
    for name in model_names {
        pool_models.append(Model(model_name=name));
    }
    return ModelPool(models=pool_models, strategy="fallback");
}

glob llm = _make_llm();

# ---------------------------------------------------------------------------
# Semantic strings for byLLM (NOT docstrings — only sem reaches the model)
# ---------------------------------------------------------------------------

sem SearchContext = "Full search state for the next naval config proposal";
sem SearchContext.mission = "Mission identity and route context (id, name, distance, stressor)";
sem SearchContext.current_zones = "Complete 9-zone material configuration currently under test";
sem SearchContext.current_propulsion = "Current propulsion parameters";
sem SearchContext.latest_result = "Latest simulation envelope summary including status, failure, worst zones";
sem SearchContext.best_survivor = "Cheapest surviving candidate found so far, or null";
sem SearchContext.best_potential = "Highest-potential candidate (late failure / cheap / single fix), or null";
sem SearchContext.recent_history = "Compact recent iteration history for stagnation detection";
sem SearchContext.design_memory = "Learned lessons from global and campaign design memory";
sem SearchContext.search_directive = "Current search directive: repair locally or exploit for lower cost";
sem SearchContext.iteration = "Current iteration number (1-based)";
sem SearchContext.survived = "True when the latest run reached SUCCESS";

sem BriefAssessment = "Diagnosis plus next material/propulsion configuration to simulate";
sem BriefAssessment.assessment = "Exact diagnosis: failed part, failure cause, physical reason";
sem BriefAssessment.failed_part = "Failed component / hull zone name";
sem BriefAssessment.failed_metric = "fatigue|corrosion|crack|fuel|stability|seal|temperature";
sem BriefAssessment.root_cause = "Specific physical cause of the failure";
sem BriefAssessment.changes = "List of configuration changes made in this proposal";
sem BriefAssessment.zones = "Complete array of exactly 9 zone proposals covering every hull zone";
sem BriefAssessment.propulsion = "Next propulsion spec, or null to keep current";

sem ZoneProposal = "One hull-zone material configuration";
sem ZoneProposal.zone = "Hull zone enum (Keel, BilgeStrake, BottomPlating, ...)";
sem ZoneProposal.material = "Material grade string from ALLOWED materials (MildSteelA, Eh36, Aluminum5083, GrpEGlass, CfrpEpoxy, ...)";
sem ZoneProposal.thickness_m = "Plate thickness in meters, typically 0.003–0.10";
sem ZoneProposal.weld_quality = "Economy | Standard | Premium";
sem ZoneProposal.seal_quality = "Economy | Marine";

sem propose_next_config = """
You are controlling a naval simulation engine.
Given the search context, diagnose the latest failure exactly (or cost-optimize after SUCCESS)
and produce the next BriefAssessment with a complete 9-zone material configuration.

Rules:
- Return diagnosis, changes, zones (exactly 9), and propulsion. Do not invent new route/mission fields.
- Valid materials: MildSteelA, Eh36, Aluminum5083, GrpEGlass, CfrpEpoxy (EH40 is not an allowed upgrade path for search; prefer Eh36).
- Valid weld_quality: Economy, Standard, Premium. Valid seal_quality: Economy, Marine.
- thickness_m usually between 0.003 and 0.10. Never set every zone to max thickness or Premium in one step.
- On FAILURE: change at most two hull zones plus propulsion. Repair the failed component first; only escalate coupled zones after repeated completion plateaus.
- On SUCCESS: search for a cheaper viable config — reduce thickness, downgrade weld/seal, reduce fuel_capacity_kg / max_power_kw, or cheaper materials where margins allow. Change at most three hull zones plus propulsion.
- For fuel exhaustion, change propulsion (fuel_capacity_kg, propulsive_efficiency, hull_drag_coeff) instead of route.
- Objective order: survive the full voyage first, then minimize total_config_cost_usd.
- If stuck at the same completion percentage with no survivor, escalate gradually: failed zone first, coupled zones later.
- If recent history shows stagnation, try a different design family (weld-first, material substitution, lightweight composite, fuel/drag, targeted reinforcement).
- Prefer branching from best_survivor when the latest run is worse; explore best_potential when a failed candidate completed much more distance at lower cost with one fixable failure.
- Use design_memory as continuous learned experience, but override it when latest physics contradicts it.
- Obey search_directive.
""";

sem propose_next_config.ctx = "Full SearchContext with mission, zones, propulsion, result, memory, and directive";

def propose_next_config(ctx: SearchContext) -> BriefAssessment by llm();

# ---------------------------------------------------------------------------
# Small utilities
# ---------------------------------------------------------------------------



def:priv safe_float(value: any, fallback: float = 0.0) -> float {
    if value is None {
        return fallback;
    }
    try {
        return float(value);
    } except Exception {
        return fallback;
    }
}

def:priv zone_thickness(zone: dict, fallback: float = 0.004) -> float {
    return safe_float(zone.get("thickness_m", fallback), fallback);
}

def:priv coalesce(a: any, b: any) -> any {
    if a is None {
        return b;
    }
    return a;
}

def:priv clamp_number(value: float, lo: float, hi: float) -> float {
    if value < lo { return lo; }
    if value > hi { return hi; }
    return value;
}

def:priv round_number(value: float, digits: int = 6) -> float {
    factor: float = 10.0 ** float(digits);
    rounded: float = float(round(value * factor));
    return rounded / factor;
}

def:priv _json_default(value: any) -> str {
    return str(value);
}

def:priv clone_json(value: any) -> any {
    return json.loads(json.dumps(value, default=_json_default));
}

def:priv now_iso() -> str {
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z");
}

def:priv zone_key_str(zone: HullZone | str | None) -> str | None {
    if zone is None {
        return None;
    }
    if isinstance(zone, str) {
        return normalize_zone_key(zone);
    }
    match zone {
        case HullZone.KEEL: return "Keel";
        case HullZone.BILGE_STRAKE: return "BilgeStrake";
        case HullZone.BOTTOM_PLATING: return "BottomPlating";
        case HullZone.SIDE_PLATING: return "SidePlating";
        case HullZone.BOW_FLARE: return "BowFlare";
        case HullZone.STERN_PLATE: return "SternPlate";
        case HullZone.TRANSOM_FRAME: return "TransomFrame";
        case HullZone.WEATHER_DECK: return "WeatherDeck";
        case HullZone.BULKHEAD_FRAME: return "BulkheadFrame";
        case _: return None;
    }
}

def:priv weld_key(weld: WeldQuality | str) -> str {
    if isinstance(weld, str) {
        return coerce_enum(weld, WELD_QUALITIES, "Economy");
    }
    match weld {
        case WeldQuality.PREMIUM: return "Premium";
        case WeldQuality.STANDARD: return "Standard";
        case WeldQuality.ECONOMY: return "Economy";
        case _: return "Economy";
    }
}

def:priv seal_key(seal: SealQuality | str) -> str {
    if isinstance(seal, str) {
        return coerce_enum(seal, SEAL_QUALITIES, "Economy");
    }
    match seal {
        case SealQuality.MARINE: return "Marine";
        case SealQuality.COMMERCIAL: return "Marine";
        case SealQuality.ECONOMY: return "Economy";
        case _: return "Economy";
    }
}

def:priv material_str(value: any, fallback: str = "MildSteelA") -> str {
    if value is None {
        return coerce_enum(fallback, MATERIALS, "MildSteelA");
    }
    if isinstance(value, dict) {
        grade = value.get("grade", value.get("label", None));
        return coerce_enum(grade, MATERIALS, fallback);
    }
    return coerce_enum(str(value), MATERIALS, fallback);
}

def coerce_enum(value: any, allowed: list[str], fallback: str) -> str {
    target = str(coalesce(value, "")).lower();
    for item in allowed {
        if item.lower() == target {
            return item;
        }
    }
    fb = str(coalesce(fallback, "")).lower();
    for item in allowed {
        if item.lower() == fb {
            return item;
        }
    }
    return allowed[0];
}

def normalize_zone_key(value: any) -> str | None {
    if value is None {
        return None;
    }
    raw = str(value);
    if raw in HULL_ZONE_KEYS {
        return raw;
    }
    parsed = parse_hull_zone(raw);
    return zone_key_str(parsed);
}

# ---------------------------------------------------------------------------
# Zone / propulsion normalization
# ---------------------------------------------------------------------------

def normalize_zone_spec(zone: any, fallback: dict | None = None) -> dict | None {
    fb = fallback if fallback is not None else {};
    zone_key = normalize_zone_key(
        coalesce(zone.get("zone") if isinstance(zone, dict) else None, fb.get("zone"))
    );
    if zone_key is None {
        return None;
    }
    thickness = fb.get("thickness_m", 0.004);
    if isinstance(zone, dict) and "thickness_m" in zone {
        try {
            t = safe_float(zone["thickness_m"], float(thickness));
            if t == t {
                thickness = clamp_number(t, MIN_THICKNESS_M, MAX_THICKNESS_M);
            }
        } except Exception {
            thickness = fb.get("thickness_m", 0.004);
        }
    }
    mat_src = None;
    weld_src = None;
    seal_src = None;
    if isinstance(zone, dict) {
        mat_src = zone.get("material", None);
        weld_src = zone.get("weld_quality", None);
        seal_src = zone.get("seal_quality", None);
    }
    return {
        "zone": zone_key,
        "material": material_str(mat_src, fb.get("material", "MildSteelA")),
        "thickness_m": float(thickness),
        "weld_quality": coerce_enum(weld_src, WELD_QUALITIES, fb.get("weld_quality", "Economy")),
        "seal_quality": coerce_enum(seal_src, SEAL_QUALITIES, fb.get("seal_quality", "Economy"))
    };
}

"Normalize a list of zone dicts into a complete ordered 9-zone configuration."
def normalize_zones(zones: list | None) -> list[dict] {
    by_key: dict[str, dict] = {};
    if zones is not None {
        for zone in zones {
            normalized = normalize_zone_spec(zone);
            if normalized is not None {
                by_key[normalized["zone"]] = normalized;
            }
        }
    }
    out: list[dict] = [];
    for key in HULL_ZONE_KEYS {
        if key in by_key {
            out.append(by_key[key]);
        } else {
            out.append({
                "zone": key,
                "material": "MildSteelA",
                "thickness_m": 0.004,
                "weld_quality": "Economy",
                "seal_quality": "Economy"
            });
        }
    }
    return out;
}

def effective_zones_from_result(result: dict) -> list[dict] {
    config = result.get("configuration", {}) if isinstance(result, dict) else {};
    zones = config.get("zones", []) if isinstance(config, dict) else [];
    if not isinstance(zones, list) {
        return [];
    }
    out: list[dict] = [];
    for zone in zones {
        if not isinstance(zone, dict) {
            continue;
        }
        out.append({
            "zone": zone.get("zone_key", zone.get("zone")),
            "material": zone.get("material"),
            "thickness_m": zone.get("thickness_m"),
            "weld_quality": zone.get("weld_quality"),
            "seal_quality": zone.get("seal_quality")
        });
    }
    return out;
}

def complete_zones_from_result(result: dict, candidate_zones: list | None = None) -> list[dict] {
    by_key: dict[str, dict] = {};
    for zone in effective_zones_from_result(result) {
        normalized = normalize_zone_spec(zone);
        if normalized is not None {
            by_key[normalized["zone"]] = normalized;
        }
    }
    cands = candidate_zones if candidate_zones is not None else [];
    for zone in cands {
        key = None;
        if isinstance(zone, dict) {
            key = normalize_zone_key(zone.get("zone"));
        }
        fb = by_key.get(key) if key is not None else None;
        normalized = normalize_zone_spec(zone, fb);
        if normalized is not None {
            by_key[normalized["zone"]] = normalized;
        }
    }
    out: list[dict] = [];
    for key in HULL_ZONE_KEYS {
        if key in by_key {
            out.append(by_key[key]);
        } else {
            out.append({
                "zone": key,
                "material": "MildSteelA",
                "thickness_m": 0.004,
                "weld_quality": "Economy",
                "seal_quality": "Economy"
            });
        }
    }
    return out;
}

def normalize_propulsion(propulsion: any, fallback: dict | None = None) -> dict[str, float] {
    fb = fallback if fallback is not None else DEFAULT_PROPULSION;
    src = propulsion if isinstance(propulsion, dict) else {};
    if isinstance(propulsion, PropulsionSpec) {
        src = {
            "max_power_kw": propulsion.max_power_kw,
            "fuel_capacity_kg": propulsion.fuel_capacity_kg,
            "sfc_g_per_kwh": propulsion.sfc_g_per_kwh,
            "propulsive_efficiency": propulsion.propulsive_efficiency,
            "hull_drag_coeff": propulsion.hull_drag_coeff
        };
    }
    return {
        "max_power_kw": max(1.0, safe_float(src.get("max_power_kw", fb.get("max_power_kw", 300.0)), 300.0)),
        "fuel_capacity_kg": max(1.0, safe_float(src.get("fuel_capacity_kg", fb.get("fuel_capacity_kg", 2000.0)), 2000.0)),
        "sfc_g_per_kwh": max(1.0, safe_float(src.get("sfc_g_per_kwh", fb.get("sfc_g_per_kwh", 220.0)), 220.0)),
        "propulsive_efficiency": clamp_number(
            safe_float(src.get("propulsive_efficiency", fb.get("propulsive_efficiency", 0.72)), 0.72),
            0.1,
            1.0
        ),
        "hull_drag_coeff": max(0.001, safe_float(src.get("hull_drag_coeff", fb.get("hull_drag_coeff", 0.007)), 0.007))
    };
}

def effective_propulsion_from_result(result: dict, document: dict | None = None) -> dict[str, float] {
    from_result = {};
    if isinstance(result, dict) {
        cfg = result.get("configuration", {});
        if isinstance(cfg, dict) {
            from_result = cfg.get("propulsion", {}) if isinstance(cfg.get("propulsion", {}), dict) else {};
        }
    }
    from_document = {};
    if isinstance(document, dict) {
        p = document.get("propulsion", {});
        if isinstance(p, dict) {
            from_document = p;
        }
    }
    return {
        "max_power_kw": safe_float(
            from_document.get("max_power_kw", from_result.get("max_power_kw", DEFAULT_PROPULSION["max_power_kw"])),
            DEFAULT_PROPULSION["max_power_kw"]
        ),
        "fuel_capacity_kg": safe_float(
            from_document.get(
                "fuel_capacity_kg",
                from_result.get("fuel_capacity_kg", DEFAULT_PROPULSION["fuel_capacity_kg"])
            ),
            DEFAULT_PROPULSION["fuel_capacity_kg"]
        ),
        "sfc_g_per_kwh": safe_float(
            from_document.get("sfc_g_per_kwh", from_result.get("sfc_g_per_kwh", DEFAULT_PROPULSION["sfc_g_per_kwh"])),
            DEFAULT_PROPULSION["sfc_g_per_kwh"]
        ),
        "propulsive_efficiency": safe_float(
            from_document.get(
                "propulsive_efficiency",
                from_result.get("propulsive_efficiency", DEFAULT_PROPULSION["propulsive_efficiency"])
            ),
            DEFAULT_PROPULSION["propulsive_efficiency"]
        ),
        "hull_drag_coeff": safe_float(
            from_document.get(
                "hull_drag_coeff",
                from_result.get("hull_drag_coeff", DEFAULT_PROPULSION["hull_drag_coeff"])
            ),
            DEFAULT_PROPULSION["hull_drag_coeff"]
        )
    };
}

def propulsion_to_spec(prop: dict) -> PropulsionSpec {
    n = normalize_propulsion(prop);
    return PropulsionSpec(
        max_power_kw=n["max_power_kw"],
        fuel_capacity_kg=n["fuel_capacity_kg"],
        sfc_g_per_kwh=n["sfc_g_per_kwh"],
        propulsive_efficiency=n["propulsive_efficiency"],
        hull_drag_coeff=n["hull_drag_coeff"]
    );
}

def zones_to_specs(zones: list[dict]) -> list[ZoneSpec] {
    specs: list[ZoneSpec] = [];
    for z in normalize_zones(zones) {
        hz = parse_hull_zone(z["zone"]);
        if hz is None {
            continue;
        }
        mat = parse_material(z["material"]);
        if mat is None {
            mat = MaterialGrade.MILD_STEEL_A;
        }
        weld = parse_weld(z["weld_quality"]);
        if weld is None {
            weld = WeldQuality.ECONOMY;
        }
        seal = parse_seal(z["seal_quality"]);
        if seal is None {
            seal = SealQuality.ECONOMY;
        }
        specs.append(ZoneSpec(
            zone=hz,
            material=mat,
            thickness_m=safe_float(z["thickness_m"], 0.004),
            weld_quality=weld,
            seal_quality=seal
        ));
    }
    return specs;
}

def zones_to_proposals(zones: list[dict]) -> list[ZoneProposal] {
    props: list[ZoneProposal] = [];
    for z in normalize_zones(zones) {
        hz = parse_hull_zone(z["zone"]);
        if hz is None {
            continue;
        }
        weld = parse_weld(z["weld_quality"]);
        if weld is None {
            weld = WeldQuality.ECONOMY;
        }
        seal = parse_seal(z["seal_quality"]);
        if seal is None {
            seal = SealQuality.ECONOMY;
        }
        props.append(ZoneProposal(
            zone=hz,
            material=str(z["material"]),
            thickness_m=safe_float(z["thickness_m"], 0.004),
            weld_quality=weld,
            seal_quality=seal
        ));
    }
    return props;
}

def proposals_to_zones(proposals: list[ZoneProposal]) -> list[dict] {
    raw: list[dict] = [];
    for p in proposals {
        raw.append({
            "zone": zone_key_str(p.zone),
            "material": material_str(p.material),
            "thickness_m": safe_float(p.thickness_m, 0.004),
            "weld_quality": weld_key(p.weld_quality),
            "seal_quality": seal_key(p.seal_quality)
        });
    }
    return normalize_zones(raw);
}

# ---------------------------------------------------------------------------
# Material / weld rank helpers
# ---------------------------------------------------------------------------

def material_rank(material: any) -> int {
    current = material_str(material, "MildSteelA");
    for (i, item) in enumerate(MATERIALS) {
        if item == current {
            return i;
        }
    }
    return 0;
}

def cheaper_material(material: any) -> str {
    current = material_str(material, "MildSteelA");
    rank = material_rank(current);
    idx = max(0, rank - 1);
    return MATERIALS[idx];
}

def stronger_material(material: any) -> str {
    current = material_str(material, "MildSteelA");
    rank = material_rank(current);
    idx = min(len(MATERIALS) - 1, rank + 1);
    return MATERIALS[idx];
}

def downgrade_weld(weld: str) -> str {
    if weld == "Premium" { return "Standard"; }
    if weld == "Standard" { return "Economy"; }
    return "Economy";
}

def upgrade_weld(weld: str) -> str {
    if weld == "Economy" { return "Standard"; }
    if weld == "Standard" { return "Premium"; }
    return "Premium";
}

def stronger_repair_material(material: any, metric: str) -> str {
    normalized = str(coalesce(material, "")).lower();
    if metric == "corrosion" or metric == "crack" {
        if "mild" in normalized or "steel" in normalized or "eh36" in normalized {
            return "Aluminum5083";
        }
        if "grp" in normalized or "aluminum" in normalized {
            return "CfrpEpoxy";
        }
        return material_str(material, "Aluminum5083");
    }
    if "mild" in normalized or "ah36" in normalized or "dh36" in normalized {
        return "Eh36";
    }
    if "grp" in normalized or "aluminum" in normalized {
        return "CfrpEpoxy";
    }
    return material_str(material, "Eh36");
}

# ---------------------------------------------------------------------------
# Result analysis / scoring
# ---------------------------------------------------------------------------

def result_cost_usd(result: dict) -> float {
    res_block: any = result.get("result", {});
    if not isinstance(res_block, dict) {
        return float("inf");
    }
    value = safe_float(res_block.get("total_config_cost_usd"), float("inf"));
    if value != value {
        return float("inf");
    }
    return value;
}

def potential_score(result: dict) -> float {
    failure = result.get("failure", {}) if isinstance(result, dict) else {};
    res = result.get("result", {}) if isinstance(result, dict) else {};
    completion = 0.0;
    if isinstance(failure, dict) and failure.get("completion_pct") is not None {
        completion = safe_float(failure["completion_pct"], 0.0);
    } elif isinstance(res, dict) and res.get("distance_completed_pct") is not None {
        completion = safe_float(res["distance_completed_pct"], 0.0);
    }
    cost = result_cost_usd(result);
    if cost < float("inf") {
        cost_score = max(0.0, 100.0 - ((cost - 5000.0) / 25000.0) * 100.0);
    } else {
        cost_score = 0.0;
    }
    single_fix_bonus = 0.0;
    if isinstance(failure, dict) {
        detail = failure.get("detail", {});
        if isinstance(detail, dict) and detail.get("failed_zone") {
            single_fix_bonus = 12.0;
        }
    }
    survived_bonus = 40.0 if result.get("status") == "survived" else 0.0;
    raw_score: float = completion * 0.72 + cost_score * 0.18 + single_fix_bonus + survived_bonus;
    return float(round(raw_score * 10.0)) / 10.0;
}

def failure_analysis_from_result(result: dict) -> dict {
    failure = result.get("failure", None) if isinstance(result, dict) else None;
    detail = {};
    if isinstance(failure, dict) {
        detail = failure.get("detail", {}) if isinstance(failure.get("detail", {}), dict) else {};
    }
    failed_zone = detail.get("failed_zone", None);
    ticks = result.get("ticks", []) if isinstance(result, dict) else [];
    final_tick = ticks[len(ticks) - 1] if isinstance(ticks, list) and len(ticks) > 0 else None;
    failed_zone_tick = None;
    if failed_zone and isinstance(final_tick, dict) {
        tick_zones_any: any = final_tick.get("zones", []);
        if isinstance(tick_zones_any, list) {
            for zone in tick_zones_any {
                if isinstance(zone, dict) and zone.get("zone") == failed_zone {
                    failed_zone_tick = zone;
                    break;
                }
            }
        }
    }
    res = result.get("result", {}) if isinstance(result, dict) else {};
    return {
        "status": result.get("status") if isinstance(result, dict) else None,
        "failed_part": detail.get("failed_zone", failure.get("mode") if isinstance(failure, dict) else None),
        "failed_metric": detail.get("failed_metric", failure.get("mode") if isinstance(failure, dict) else None),
        "failed_value": detail.get("failed_value", None),
        "failure_mode": failure.get("mode") if isinstance(failure, dict) else None,
        "segment_index": failure.get("segment_index") if isinstance(failure, dict) else None,
        "segment_label": failure.get("segment_label") if isinstance(failure, dict) else None,
        "distance_completed_nm": coalesce(
            failure.get("distance_completed_nm") if isinstance(failure, dict) else None,
            res.get("distance_completed_nm") if isinstance(res, dict) else None
        ),
        "completion_pct": coalesce(
            failure.get("completion_pct") if isinstance(failure, dict) else None,
            res.get("distance_completed_pct") if isinstance(res, dict) else None
        ),
        "elapsed_h": coalesce(
            failure.get("elapsed_h") if isinstance(failure, dict) else None,
            res.get("time_elapsed_h") if isinstance(res, dict) else None
        ),
        "cause": failure.get("why") if isinstance(failure, dict) else None,
        "suggested_fix": failure.get("suggested_fix") if isinstance(failure, dict) else None,
        "failed_zone_tick": failed_zone_tick
    };
}


def:priv fatigue_sort_key(z: any) -> float {
    if isinstance(z, dict) {
        return safe_float(z.get("fatigue_consumed", 0.0), 0.0);
    }
    return 0.0;
}

def:priv score_tuple_key(item: any) -> float {
    return safe_float(item[1], 0.0);
}

def:priv strategy_potential_key(kv: any) -> float {
    stats_any: any = kv[1] or {};
    if isinstance(stats_any, dict) {
        return safe_float(stats_any.get("best_potential_score", 0.0), 0.0);
    }
    return 0.0;
}

def summarize_result(result: dict) -> dict {
    ticks = result.get("ticks", []) if isinstance(result, dict) else [];
    final_tick = ticks[len(ticks) - 1] if isinstance(ticks, list) and len(ticks) > 0 else None;
    final_zones = [];
    if isinstance(final_tick, dict) {
        final_zones = final_tick.get("zones", []) if isinstance(final_tick.get("zones", []), list) else [];
    }
    ranked = sorted(
        final_zones,
        key=fatigue_sort_key,
        reverse=True
    );
    worst: list[dict] = [];
    for zone_any in ranked[:5] {
        if not isinstance(zone_any, dict) {
            continue;
        }
        zone: dict = zone_any;
        worst.append({
            "zone": zone.get("zone"),
            "fatigue_pct": float(round(safe_float(zone.get("fatigue_consumed", 0.0), 0.0) * 1000.0)) / 10.0,
            "corrosion_depth_mm": zone.get("corrosion_depth_mm"),
            "crack_half_length_mm": zone.get("crack_half_length_mm"),
            "peak_stress_mpa": zone.get("peak_stress_mpa")
        });
    }
    return {
        "status": result.get("status"),
        "failure": result.get("failure"),
        "result": result.get("result"),
        "worst_zones": worst
    };
}

def zones_by_risk(result: dict) -> list[str] {
    analysis_fail = None;
    failure = result.get("failure", None);
    if isinstance(failure, dict) {
        detail = failure.get("detail", {});
        if isinstance(detail, dict) {
            analysis_fail = normalize_zone_key(detail.get("failed_zone"));
        }
    }
    ticks = result.get("ticks", []);
    final_tick = ticks[len(ticks) - 1] if isinstance(ticks, list) and len(ticks) > 0 else None;
    tick_zones = [];
    if isinstance(final_tick, dict) {
        tick_zones = final_tick.get("zones", []) if isinstance(final_tick.get("zones", []), list) else [];
    }
    scored: list[tuple] = [];
    for zone_any in tick_zones {
        if not isinstance(zone_any, dict) {
            continue;
        }
        zone: dict = zone_any;
        key = normalize_zone_key(zone.get("zone"));
        if key is None {
            continue;
        }
        score: float = (
            safe_float(zone.get("fatigue_consumed", 0.0), 0.0) * 100.0
            + safe_float(zone.get("crack_half_length_mm", 0.0), 0.0) * 2.0
            + safe_float(zone.get("corrosion_depth_mm", 0.0), 0.0) * 10.0
            + safe_float(zone.get("peak_stress_mpa", 0.0), 0.0) / 1000.0
        );
        scored.append((key, score));
    }
    scored.sort(key=score_tuple_key, reverse=True);
    ranked = [item[0] for item in scored];
    ordered: list[str] = [];
    seen: set = set();
    for key in [analysis_fail] + ranked {
        if key and key not in seen {
            seen.add(key);
            ordered.append(key);
        }
    }
    return ordered;
}

def high_risk_zones_from_result(result: dict) -> list[str] {
    ticks = result.get("ticks", []);
    final_tick = ticks[len(ticks) - 1] if isinstance(ticks, list) and len(ticks) > 0 else None;
    zones = [];
    if isinstance(final_tick, dict) {
        zones = final_tick.get("zones", []) if isinstance(final_tick.get("zones", []), list) else [];
    }
    out: list[str] = [];
    for zone in zones {
        if not isinstance(zone, dict) {
            continue;
        }
        if (
            safe_float(zone.get("fatigue_consumed", 0.0), 0.0) >= 0.55
            or safe_float(zone.get("crack_half_length_mm", 0.0), 0.0) >= 3.0
            or safe_float(zone.get("peak_stress_mpa", 0.0), 0.0) >= 500.0
        ) {
            key = normalize_zone_key(zone.get("zone"));
            if key {
                out.append(key);
            }
        }
    }
    return out;
}

def candidate_signature(document: dict, mode: str = "brief") -> str {
    if mode == "brief" {
        zones = [];
        for zone in document.get("zones", []) if isinstance(document.get("zones", []), list) else [] {
            n = normalize_zone_spec(zone);
            if n is not None {
                zones.append(n);
            }
        }
        return json.dumps({
            "zones": zones,
            "propulsion": normalize_propulsion(document.get("propulsion"), DEFAULT_PROPULSION)
        }, sort_keys=True);
    }
    return json.dumps(document, sort_keys=True, default=_json_default);
}

# ---------------------------------------------------------------------------
# Exploratory mutation (ordinary Jac — not LLM)
# ---------------------------------------------------------------------------

def mutate_exploratory_document(
    current_document: dict,
    result: dict,
    best_document: dict | None,
    mode: str,
    iteration: int
) -> dict | None {
    if mode != "brief" {
        return None;
    }
    strategy = EXPLORATION_STRATEGIES[(iteration - 1) % len(EXPLORATION_STRATEGIES)];
    seed = best_document if best_document is not None else current_document;
    next_doc = clone_json(seed);
    result_zones = complete_zones_from_result(result, next_doc.get("zones", []));
    risky = zones_by_risk(result);
    primary = risky[0] if len(risky) > 0 else (
        result_zones[iteration % len(result_zones)]["zone"] if len(result_zones) > 0 else "Keel"
    );
    secondary = risky[1] if len(risky) > 1 else (
        result_zones[(iteration + 3) % len(result_zones)]["zone"]
        if len(result_zones) > 0
        else "BottomPlating"
    );
    target_set = {primary, secondary};

    mutated_zones: list[dict] = [];
    for (index, zone) in enumerate(result_zones) {
        mutated = dict(zone);
        is_target = zone["zone"] in target_set;

        if strategy == "targeted_reinforcement" and is_target {
            mutated["material"] = stronger_material(mutated["material"]);
            mutated["thickness_m"] = round_number(
                clamp_number(zone_thickness(mutated) * 1.22, MIN_THICKNESS_M, MAX_THICKNESS_M)
            );
            mutated["weld_quality"] = upgrade_weld(str(mutated["weld_quality"]));
        } elif strategy == "weld_quality_path" {
            if is_target {
                mutated["weld_quality"] = upgrade_weld(str(mutated["weld_quality"]));
                mutated["thickness_m"] = round_number(
                    clamp_number(zone_thickness(mutated) * 1.08, MIN_THICKNESS_M, MAX_THICKNESS_M)
                );
            } elif (index + iteration) % 4 == 0 {
                mutated["thickness_m"] = round_number(
                    clamp_number(zone_thickness(mutated) * 0.92, MIN_THICKNESS_M, MAX_THICKNESS_M)
                );
            }
        } elif strategy == "material_substitution" and is_target {
            if mutated["material"] == "Eh36" {
                mutated["material"] = "Aluminum5083";
            } else {
                mutated["material"] = stronger_material(mutated["material"]);
            }
            mutated["thickness_m"] = round_number(
                clamp_number(zone_thickness(mutated) * 1.12, MIN_THICKNESS_M, MAX_THICKNESS_M)
            );
        } elif strategy == "lightweight_composite_path" {
            if is_target {
                if zone["zone"] == "Keel" or zone["zone"] == "BilgeStrake" {
                    mutated["material"] = "CfrpEpoxy";
                } else {
                    mutated["material"] = "GrpEGlass";
                }
                mutated["thickness_m"] = round_number(
                    clamp_number(zone_thickness(mutated) * 1.18, 0.004, MAX_THICKNESS_M)
                );
                mutated["weld_quality"] = upgrade_weld(str(mutated["weld_quality"]));
                mutated["seal_quality"] = "Marine";
            } elif (index + iteration) % 3 == 0 {
                mutated["material"] = cheaper_material(mutated["material"]);
            }
        } elif strategy == "cost_cut_from_best" {
            if (not is_target) and (index + iteration) % 2 == 0 {
                mutated["material"] = cheaper_material(mutated["material"]);
                mutated["thickness_m"] = round_number(
                    clamp_number(zone_thickness(mutated) * 0.84, MIN_THICKNESS_M, MAX_THICKNESS_M)
                );
                mutated["weld_quality"] = downgrade_weld(str(mutated["weld_quality"]));
            }
        }
        mutated_zones.append(mutated);
    }
    next_doc["zones"] = mutated_zones;

    propulsion = normalize_propulsion(
        next_doc.get("propulsion"),
        effective_propulsion_from_result(result, seed)
    );
    if strategy == "fuel_drag_tradeoff" {
        next_doc["propulsion"] = normalize_propulsion({
            "max_power_kw": propulsion["max_power_kw"] * 0.95,
            "fuel_capacity_kg": propulsion["fuel_capacity_kg"] * 1.18,
            "sfc_g_per_kwh": propulsion["sfc_g_per_kwh"],
            "propulsive_efficiency": min(propulsion["propulsive_efficiency"] + 0.03, 0.86),
            "hull_drag_coeff": propulsion["hull_drag_coeff"] * 0.9
        }, propulsion);
    } elif strategy == "cost_cut_from_best" {
        next_doc["propulsion"] = normalize_propulsion({
            "max_power_kw": propulsion["max_power_kw"] * 0.92,
            "fuel_capacity_kg": propulsion["fuel_capacity_kg"] * 0.86,
            "sfc_g_per_kwh": propulsion["sfc_g_per_kwh"],
            "propulsive_efficiency": propulsion["propulsive_efficiency"],
            "hull_drag_coeff": propulsion["hull_drag_coeff"]
        }, propulsion);
    } else {
        next_doc["propulsion"] = propulsion;
    }

    return {
        "document": next_doc,
        "strategy": strategy,
        "targets": list(target_set)
    };
}

# ---------------------------------------------------------------------------
# Emergency survival escalation (ordinary Jac — not LLM)
# ---------------------------------------------------------------------------

def plateau_count(history: list[dict], completion: float) -> int {
    if not isinstance(history, list) {
        return 0;
    }
    count = 0;
    recent = history[-6:] if len(history) >= 6 else history;
    for entry in recent {
        if not isinstance(entry, dict) {
            continue;
        }
        failure = entry.get("failure", {});
        res = entry.get("result", {});
        pct = None;
        if isinstance(failure, dict) and failure.get("completion_pct") is not None {
            pct = safe_float(failure["completion_pct"], 0.0);
        } elif isinstance(res, dict) and res.get("distance_completed_pct") is not None {
            pct = safe_float(res["distance_completed_pct"], 0.0);
        }
        if pct is not None and abs(pct - completion) < 0.75 {
            count += 1;
        }
    }
    return count;
}

def survival_escalation_plan(history: list[dict], completion: float) -> dict | None {
    plateau = plateau_count(history, completion);
    if plateau < 4 {
        return None;
    }
    if plateau >= 8 {
        return {
            "stage": 5, "plateau": plateau,
            "failed_thickness_m": 0.045, "coupled_thickness_m": 0.032, "multiplier": 1.18
        };
    }
    if plateau >= 7 {
        return {
            "stage": 4, "plateau": plateau,
            "failed_thickness_m": 0.036, "coupled_thickness_m": 0.026, "multiplier": 1.16
        };
    }
    if plateau >= 6 {
        return {
            "stage": 3, "plateau": plateau,
            "failed_thickness_m": 0.028, "coupled_thickness_m": 0.020, "multiplier": 1.14
        };
    }
    if plateau >= 5 {
        return {
            "stage": 2, "plateau": plateau,
            "failed_thickness_m": 0.022, "coupled_thickness_m": 0.016, "multiplier": 1.12
        };
    }
    return {
        "stage": 1, "plateau": plateau,
        "failed_thickness_m": 0.016, "coupled_thickness_m": 0.012, "multiplier": 1.1
    };
}

def emergency_survival_escalation(
    document: dict,
    result: dict,
    history: list[dict] | None = None
) -> dict | None {
    hist: list[dict] = history if history is not None else [];
    if not isinstance(document, dict) or document.get("zones") is None {
        return None;
    }
    if result.get("status") == "survived" {
        return None;
    }
    failure = result.get("failure", {});
    res = result.get("result", {});
    completion = 0.0;
    if isinstance(failure, dict) and failure.get("completion_pct") is not None {
        completion = safe_float(failure["completion_pct"], 0.0);
    } elif isinstance(res, dict) and res.get("distance_completed_pct") is not None {
        completion = safe_float(res["distance_completed_pct"], 0.0);
    }
    plan = survival_escalation_plan(hist, completion);
    if plan is None {
        return None;
    }
    analysis = failure_analysis_from_result(result);
    failed_key = normalize_zone_key(analysis.get("failed_part"));
    if failed_key is None {
        return None;
    }
    coupled_by_failure = {
        "Keel": ["Keel", "BilgeStrake", "BottomPlating"],
        "BowFlare": ["BowFlare", "BottomPlating", "SidePlating", "WeatherDeck"],
        "BilgeStrake": ["BilgeStrake", "Keel", "BottomPlating", "SidePlating"],
        "BottomPlating": ["BottomPlating", "Keel", "BilgeStrake"],
        "WeatherDeck": ["WeatherDeck", "BowFlare", "BulkheadFrame"],
        "SidePlating": ["SidePlating", "BowFlare", "BilgeStrake"],
        "SternPlate": ["SternPlate", "TransomFrame", "BottomPlating"],
        "TransomFrame": ["TransomFrame", "SternPlate", "BulkheadFrame"],
        "BulkheadFrame": ["BulkheadFrame", "WeatherDeck", "TransomFrame"]
    };
    targets = {failed_key};
    if plan["stage"] >= 3 {
        for zone in coupled_by_failure.get(failed_key, []) {
            targets.add(zone);
        }
    }
    if plan["stage"] >= 4 {
        for zone in high_risk_zones_from_result(result) {
            targets.add(zone);
        }
    }
    next_doc = clone_json(document);
    next_zones: list[dict] = [];
    for zone in complete_zones_from_result(result, document.get("zones", [])) {
        if zone["zone"] not in targets {
            next_zones.append(zone);
            continue;
        }
        is_failed = zone["zone"] == failed_key;
        base_target = plan["failed_thickness_m"] if is_failed else plan["coupled_thickness_m"];
        metric = "crack" if analysis.get("failed_metric") == "crack" else "fatigue";
        next_zones.append({
            "zone": zone["zone"],
            "material": stronger_repair_material(zone["material"], metric),
            "thickness_m": round_number(clamp_number(
                max(zone["thickness_m"] * plan["multiplier"], base_target),
                MIN_THICKNESS_M,
                MAX_THICKNESS_M
            )),
            "weld_quality": "Premium",
            "seal_quality": "Marine"
        });
    }
    next_doc["zones"] = next_zones;
    return {
        "document": next_doc,
        "targets": list(targets),
        "completion": completion,
        "plateau": plan["plateau"],
        "stage": plan["stage"],
        "failed_thickness_m": plan["failed_thickness_m"],
        "coupled_thickness_m": plan["coupled_thickness_m"]
    };
}

def apply_emergency_assessment(assessment: dict, emergency: dict) -> dict {
    out = dict(assessment);
    out["search_strategy"] = "emergency-survival-escalation";
    out["exploration_targets"] = emergency["targets"];
    changes = list(assessment.get("changes", [])) if isinstance(assessment.get("changes", []), list) else [];
    changes.append(
        f"Stage {emergency['stage']} gradual survival escalation after "
        + f"{emergency['completion']:.1f}% completion with {emergency['plateau']} recent plateau runs: "
        + f"reinforce {', '.join(emergency['targets'])} toward "
        + f"{emergency['failed_thickness_m'] * 1000.0:.0f}mm failed-zone / "
        + f"{emergency['coupled_thickness_m'] * 1000.0:.0f}mm coupled-zone targets."
    );
    out["changes"] = changes;
    return out;
}

# ---------------------------------------------------------------------------
# Local repair fallback (when LLM fails)
# ---------------------------------------------------------------------------

def local_repair_assessment(document: dict, result: dict) -> dict {
    analysis = failure_analysis_from_result(result);
    zones = complete_zones_from_result(result, document.get("zones", []));
    propulsion = effective_propulsion_from_result(result, document);

    if analysis.get("failure_mode") == "Fuel Exhaustion" or analysis.get("failed_metric") == "fuel" {
        repaired_prop = normalize_propulsion({
            "max_power_kw": propulsion["max_power_kw"],
            "fuel_capacity_kg": min(
                max(propulsion["fuel_capacity_kg"] * 1.45, propulsion["fuel_capacity_kg"] + 500.0),
                8000.0
            ),
            "sfc_g_per_kwh": propulsion["sfc_g_per_kwh"],
            "propulsive_efficiency": min(propulsion["propulsive_efficiency"] + 0.04, 0.82),
            "hull_drag_coeff": max(propulsion["hull_drag_coeff"] * 0.92, 0.004)
        }, propulsion);
        brief = dict(document);
        brief["zones"] = zones;
        brief["propulsion"] = repaired_prop;
        return {
            "assessment": (
                "Propulsion failed by fuel exhaustion: "
                + str(coalesce(analysis.get("cause"), "fuel reserve reached zero before destination"))
            ),
            "failed_part": "Propulsion",
            "failed_metric": "fuel",
            "root_cause": analysis.get("cause"),
            "changes": [
                f"Propulsion: fuel_capacity_kg {propulsion['fuel_capacity_kg']:.0f} -> {repaired_prop['fuel_capacity_kg']:.0f}",
                f"Propulsion: propulsive_efficiency {propulsion['propulsive_efficiency']:.2f} -> {repaired_prop['propulsive_efficiency']:.2f}",
                f"Propulsion: hull_drag_coeff {propulsion['hull_drag_coeff']:.4f} -> {repaired_prop['hull_drag_coeff']:.4f}"
            ],
            "zones": zones,
            "propulsion": repaired_prop,
            "brief": brief,
            "model_used": "local-propulsion-repair-fallback"
        };
    }

    failed_key = normalize_zone_key(analysis.get("failed_part"));
    coupled_by_failure = {
        "Keel": ["Keel", "BilgeStrake", "BottomPlating"],
        "BowFlare": ["BowFlare", "BottomPlating"],
        "BilgeStrake": ["BilgeStrake", "Keel", "BottomPlating"],
        "BottomPlating": ["BottomPlating", "Keel", "BilgeStrake"]
    };
    targets: set = set();
    if failed_key {
        targets.add(failed_key);
        for zname in coupled_by_failure.get(failed_key, []) {
            targets.add(zname);
        }
    }

    repaired_zones: list[dict] = [];
    for zone in zones {
        if zone["zone"] not in targets {
            repaired_zones.append(zone);
            continue;
        }
        if analysis.get("failed_metric") == "fatigue" or analysis.get("failure_mode") == "Fatigue Failure" {
            repaired_zones.append({
                "zone": zone["zone"],
                "material": stronger_repair_material(zone["material"], "fatigue"),
                "thickness_m": min(max(zone_thickness(zone) * 1.75, 0.008), MAX_THICKNESS_M),
                "weld_quality": "Premium",
                "seal_quality": "Marine" if zone["seal_quality"] == "Economy" else zone["seal_quality"]
            });
        } elif analysis.get("failed_metric") == "corrosion" or analysis.get("failed_metric") == "crack" {
            repaired_zones.append({
                "zone": zone["zone"],
                "material": stronger_repair_material(zone["material"], str(analysis.get("failed_metric"))),
                "thickness_m": min(max(zone_thickness(zone) * 1.5, 0.007), MAX_THICKNESS_M),
                "weld_quality": "Standard" if zone["weld_quality"] == "Economy" else zone["weld_quality"],
                "seal_quality": "Marine"
            });
        } else {
            repaired_zones.append({
                "zone": zone["zone"],
                "material": zone["material"],
                "thickness_m": min(max(zone_thickness(zone) * 1.25, 0.006), MAX_THICKNESS_M),
                "weld_quality": "Standard" if zone["weld_quality"] == "Economy" else zone["weld_quality"],
                "seal_quality": "Marine" if zone["seal_quality"] == "Economy" else zone["seal_quality"]
            });
        }
    }

    changes: list[str] = [];
    for (i, zone) in enumerate(repaired_zones) {
        if json.dumps(zone, sort_keys=True) != json.dumps(zones[i], sort_keys=True) {
            changes.append(
                f"{zone['zone']}: {zone['material']}, "
                + f"{zone['thickness_m'] * 1000.0:.1f}mm, "
                + f"{zone['weld_quality']} weld, {zone['seal_quality']} seal"
            );
        }
    }
    brief = dict(document);
    brief["zones"] = repaired_zones;
    return {
        "assessment": (
            f"{coalesce(analysis.get('failed_part'), 'Component')} failed by "
            + f"{coalesce(coalesce(analysis.get('failed_metric'), analysis.get('failure_mode')), 'unknown metric')}: "
            + f"{coalesce(analysis.get('cause'), 'no simulator cause provided')}"
        ),
        "failed_part": analysis.get("failed_part"),
        "failed_metric": analysis.get("failed_metric"),
        "root_cause": analysis.get("cause"),
        "changes": changes,
        "zones": repaired_zones,
        "brief": brief,
        "model_used": "local-material-repair-fallback"
    };
}

# ---------------------------------------------------------------------------
# Design memory
# ---------------------------------------------------------------------------

def empty_design_memory(scope: str = "campaign") -> dict {
    return {
        "schema_version": 1,
        "scope": scope,
        "updated_at": None,
        "missions": {}
    };
}

def mission_memory(memory: dict, mission_id: str | None) -> dict {
    key = mission_id if mission_id else "unknown";
    if "missions" not in memory or memory["missions"] is None {
        memory["missions"] = {};
    }
    if key not in memory["missions"] {
        memory["missions"][key] = {
            "runs_seen": 0,
            "successes_seen": 0,
            "failures_seen": 0,
            "best_survivor_cost_usd": None,
            "best_survivor_summary": None,
            "best_potential_score": None,
            "lessons": [],
            "component_lessons": {},
            "strategy_stats": {}
        };
    }
    return memory["missions"][key] as dict;
}

def compact_zone_config(document: dict) -> list[dict] {
    out: list[dict] = [];
    for zone in document.get("zones", []) if isinstance(document.get("zones", []), list) else [] {
        if not isinstance(zone, dict) {
            continue;
        }
        thickness_mm = None;
        try {
            thickness_mm = float(round(safe_float(zone["thickness_m"], 0.0) * 100000.0)) / 100.0;
        } except Exception {
            thickness_mm = None;
        }
        out.append({
            "zone": zone.get("zone"),
            "material": zone.get("material"),
            "thickness_mm": thickness_mm,
            "weld_quality": zone.get("weld_quality"),
            "seal_quality": zone.get("seal_quality")
        });
    }
    return out;
}

def push_bounded(lst: list[any], item: any, limit: int = 18) {
    lst.insert(0, item);
    seen: set = set();
    unique: list = [];
    for entry in lst {
        signature = json.dumps(entry, sort_keys=True, default=_json_default);
        if signature in seen {
            continue;
        }
        seen.add(signature);
        unique.append(entry);
        if len(unique) >= limit {
            break;
        }
    }
    lst.clear();
    lst.extend(unique);
}

def record_design_memory(
    memory: dict,
    document: dict,
    result: dict,
    assessment: dict,
    iteration: int,
    strategy: str,
    potential: float
) {
    mission_id = document.get("id", "params");
    mission = mission_memory(memory, mission_id);
    cost = result_cost_usd(result);
    failure = result.get("failure", None);
    failed_part = None;
    failed_metric = None;
    if isinstance(failure, dict) {
        detail = failure.get("detail", {});
        if isinstance(detail, dict) {
            failed_part = detail.get("failed_zone");
            failed_metric = detail.get("failed_metric");
        }
        if failed_metric is None {
            failed_metric = failure.get("mode");
        }
    }
    if failed_part is None {
        failed_part = assessment.get("failed_part");
    }
    if failed_metric is None {
        failed_metric = assessment.get("failed_metric");
    }
    status = result.get("status", "unknown");
    completion = 0.0;
    if isinstance(failure, dict) and failure.get("completion_pct") is not None {
        completion = safe_float(failure["completion_pct"], 0.0);
    } elif isinstance(result.get("result"), dict) and result["result"].get("distance_completed_pct") is not None {
        completion = safe_float(result["result"]["distance_completed_pct"], 0.0);
    }

    memory["updated_at"] = now_iso();
    mission["runs_seen"] += 1;
    if status == "survived" {
        mission["successes_seen"] += 1;
    }
    if status == "failed" {
        mission["failures_seen"] += 1;
    }

    strategy_key = strategy if strategy else "unknown";
    if strategy_key not in mission["strategy_stats"] {
        mission["strategy_stats"][strategy_key] = {
            "runs": 0,
            "successes": 0,
            "best_cost_usd": None,
            "best_potential_score": None
        };
    }
    stat = mission["strategy_stats"][strategy_key];
    stat["runs"] += 1;
    if status == "survived" {
        stat["successes"] += 1;
    }
    if cost < float("inf") and (stat["best_cost_usd"] is None or cost < stat["best_cost_usd"]) {
        stat["best_cost_usd"] = round(cost);
    }
    if stat["best_potential_score"] is None or potential > stat["best_potential_score"] {
        stat["best_potential_score"] = potential;
    }

    if status == "survived" and cost < float("inf") {
        if mission["best_survivor_cost_usd"] is None or cost < mission["best_survivor_cost_usd"] {
            mission["best_survivor_cost_usd"] = round(cost);
            mission["best_survivor_summary"] = {
                "iteration": iteration,
                "strategy": strategy_key,
                "cost_usd": round(cost),
                "propulsion": normalize_propulsion(document.get("propulsion"), DEFAULT_PROPULSION),
                "zones": compact_zone_config(document)
            };
        }
    }

    if mission["best_potential_score"] is None or potential > mission["best_potential_score"] {
        mission["best_potential_score"] = potential;
    }

    lesson = {
        "iteration": iteration,
        "status": status,
        "strategy": strategy_key,
        "cost_usd": round(cost) if cost < float("inf") else None,
        "completion_pct": float(round(completion * 10.0)) / 10.0,
        "failed_part": failed_part,
        "failed_metric": failed_metric,
        "root_cause": coalesce(assessment.get("root_cause"), failure.get("why") if isinstance(failure, dict) else None),
        "takeaway": (
            f"Configuration survived at ${round(cost) if cost < float('inf') else 'unknown'}; use it as a cost ceiling."
            if status == "survived"
            else (
                f"{coalesce(failed_part, 'Unknown component')} failed by "
                + f"{coalesce(failed_metric, 'unknown mode')} at {round(completion)}% completion."
            )
        )
    };
    lessons_list: list[any] = mission["lessons"] as list[any];
    push_bounded(lessons_list, lesson, 24);
    mission["lessons"] = lessons_list;

    if failed_part {
        component_lessons: dict = mission["component_lessons"] as dict;
        if failed_part not in component_lessons {
            component_lessons[failed_part] = [];
        }
        zone_cfg = None;
        failed_zone_key = normalize_zone_key(failed_part);
        for z in compact_zone_config(document) {
            if z.get("zone") == failed_zone_key {
                zone_cfg = z;
                break;
            }
        }
        lesson_list: list[any] = component_lessons[failed_part] as list[any];
        push_bounded(lesson_list, {
            "iteration": iteration,
            "status": status,
            "metric": failed_metric,
            "strategy": strategy_key,
            "completion_pct": lesson["completion_pct"],
            "root_cause": lesson["root_cause"],
            "zone_config": zone_cfg
        }, 8);
        component_lessons[failed_part] = lesson_list;
        mission["component_lessons"] = component_lessons;
    }
}

def compact_design_memory(memory: dict, mission_id: str) -> dict | None {
    missions: dict = memory.get("missions", {}) as dict if isinstance(memory.get("missions", {}), dict) else {};
    mission_any: any = missions.get(mission_id);
    if mission_any is None or not isinstance(mission_any, dict) {
        return None;
    }
    mission: dict = mission_any;
    stats_any: any = mission.get("strategy_stats", {});
    stats: dict = stats_any if isinstance(stats_any, dict) else {};
    ranked = sorted(
        list(stats.items()),
        key=strategy_potential_key,
        reverse=True
    );
    strategy_stats: dict = {};
    for (k, v) in ranked[:8] {
        strategy_stats[k] = v;
    }
    lessons_any: any = mission.get("lessons") or [];
    lessons: list = lessons_any if isinstance(lessons_any, list) else [];
    return {
        "runs_seen": mission.get("runs_seen"),
        "successes_seen": mission.get("successes_seen"),
        "failures_seen": mission.get("failures_seen"),
        "best_survivor_cost_usd": mission.get("best_survivor_cost_usd"),
        "best_survivor_summary": mission.get("best_survivor_summary"),
        "best_potential_score": mission.get("best_potential_score"),
        "lessons": lessons[:10],
        "component_lessons": mission.get("component_lessons") or {},
        "strategy_stats": strategy_stats
    };
}

def compact_history(history: list) -> list[dict] {
    out: list[dict] = [];
    for entry in history[-8:] {
        if not isinstance(entry, dict) {
            continue;
        }
        failure = entry.get("failure", {});
        res = entry.get("result", {});
        out.append({
            "iteration": entry.get("iteration"),
            "status": entry.get("status"),
            "cost_usd": entry.get("total_config_cost_usd"),
            "failure_mode": failure.get("mode") if isinstance(failure, dict) else None,
            "failed_part": (
                (failure.get("detail") or {}).get("failed_zone")
                if isinstance(failure, dict)
                else None
            ),
            "failed_metric": (
                (failure.get("detail") or {}).get("failed_metric")
                if isinstance(failure, dict)
                else None
            ),
            "completion_pct": (
                failure.get("completion_pct")
                if isinstance(failure, dict) and failure.get("completion_pct") is not None
                else (res.get("distance_completed_pct") if isinstance(res, dict) else None)
            ),
            "strategy": entry.get("strategy")
        });
    }
    return out;
}

# ---------------------------------------------------------------------------
# Assessment ↔ document bridging
# ---------------------------------------------------------------------------

def assessment_to_dict(assessment: BriefAssessment | dict) -> dict {
    if isinstance(assessment, dict) {
        return assessment;
    }
    failed_metric = None;
    if assessment.failed_metric is not None {
        failed_metric = str(assessment.failed_metric);
    }
    zones = proposals_to_zones(assessment.zones) if assessment.zones else [];
    prop = None;
    if assessment.propulsion is not None {
        prop = normalize_propulsion(assessment.propulsion);
    }
    return {
        "assessment": assessment.assessment,
        "failed_part": assessment.failed_part,
        "failed_metric": failed_metric,
        "root_cause": assessment.root_cause,
        "changes": list(assessment.changes) if assessment.changes else [],
        "zones": zones,
        "propulsion": prop,
        "brief": None
    };
}

def next_document_from_assessment(
    assessment: dict,
    current_document: dict,
    result: dict | None = None
) -> dict {
    next_brief = None;
    if isinstance(assessment.get("brief"), dict) {
        next_brief = dict(assessment["brief"]);
    } elif isinstance(assessment.get("params"), dict) {
        next_brief = dict(assessment["params"]);
    } else {
        next_brief = dict(current_document);
    }

    if isinstance(assessment.get("zones"), list) {
        next_brief["zones"] = assessment["zones"];
    }
    if isinstance(assessment.get("propulsion"), dict) {
        next_brief["propulsion"] = assessment["propulsion"];
    }
    if not isinstance(next_brief.get("zones"), list) {
        raise ValueError("assessment did not include zones for the repaired material configuration");
    }

    complete = complete_zones_from_result(result if result is not None else {}, next_brief["zones"]);
    propulsion = normalize_propulsion(
        next_brief.get("propulsion"),
        effective_propulsion_from_result(result if result is not None else {}, current_document)
    );
    out = dict(current_document);
    out.update(next_brief);
    # Preserve immutable mission fields
    out["id"] = current_document.get("id");
    out["name"] = current_document.get("name");
    out["origin"] = current_document.get("origin");
    out["waypoints"] = current_document.get("waypoints", []);
    out["destination"] = current_document.get("destination");
    out["distance_nm"] = current_document.get("distance_nm");
    out["primary_stressor"] = current_document.get("primary_stressor");
    out["failure_modes_under_test"] = current_document.get("failure_modes_under_test", []);
    out["environmental_profile"] = current_document.get("environmental_profile");
    out["zones"] = complete;
    out["propulsion"] = propulsion;
    return out;
}

def build_search_context(
    document: dict,
    result: dict,
    iteration: int,
    max_iterations: int,
    best_survivor: dict | None,
    best_potential: dict | None,
    history: list,
    design_memory: dict
) -> SearchContext {
    zones = complete_zones_from_result(result, document.get("zones", []));
    propulsion = effective_propulsion_from_result(result, document);
    mission = parse_mission_brief(document);
    survived = result.get("status") == "survived";
    directive = (
        "exploit the best survivor for lower cost, but branch into a different design family if recent trials are stuck"
        if survived
        else "repair the failure locally, or branch if this failure suggests a more promising architecture"
    );
    return SearchContext(
        mission=mission,
        current_zones=zones_to_specs(zones),
        current_propulsion=propulsion_to_spec(propulsion),
        latest_result=summarize_result(result),
        best_survivor=best_survivor,
        best_potential=best_potential,
        recent_history=compact_history(history),
        design_memory=design_memory,
        search_directive=directive,
        iteration=iteration,
        survived=survived
    );
}

# ---------------------------------------------------------------------------
# I/O helpers
# ---------------------------------------------------------------------------

def read_json(path: Path | str) -> any {
    return json.loads(Path(path).read_text(encoding="utf-8"));
}

def read_json_if_exists(path: Path | str, fallback: any = None) -> any {
    p = Path(path);
    if not p.exists() {
        return fallback;
    }
    try {
        return read_json(p);
    } except Exception {
        return fallback;
    }
}

def write_json(path: Path | str, value: any) {
    p = Path(path);
    p.parent.mkdir(parents=True, exist_ok=True);
    p.write_text(json.dumps(value, indent=2, default=_json_default) + "\n", encoding="utf-8");
}

def mission_brief_file_by_id(mission_id: str) -> Path | None {
    import re;
    if not mission_id or not re.fullmatch(r"[A-Za-z0-9_-]+", mission_id) {
        return None;
    }
    if not MISSION_BRIEFS_DIR.exists() {
        return None;
    }
    for file in MISSION_BRIEFS_DIR.iterdir() {
        if file.suffix != ".json" {
            continue;
        }
        brief = read_json(file);
        if isinstance(brief, dict) and brief.get("id") == mission_id {
            return file;
        }
    }
    return None;
}

def ensure_document_zones(document: dict, tier: str = "lowest") -> dict {
    doc = clone_json(document);
    if isinstance(doc.get("zones"), list) and len(doc["zones"]) > 0 {
        doc["zones"] = normalize_zones(doc["zones"]);
        if not isinstance(doc.get("propulsion"), dict) {
            doc["propulsion"] = dict(DEFAULT_PROPULSION);
        } else {
            doc["propulsion"] = normalize_propulsion(doc["propulsion"]);
        }
        return doc;
    }
    # First simulation will use tier defaults inside run_brief; seed empty zones
    # so later iterations always carry an explicit config.
    if not isinstance(doc.get("propulsion"), dict) {
        base = default_sim_propulsion();
        doc["propulsion"] = {
            "max_power_kw": base.max_power_kw,
            "fuel_capacity_kg": base.fuel_capacity_kg,
            "sfc_g_per_kwh": base.sfc_g_per_kwh,
            "propulsive_efficiency": base.propulsive_efficiency,
            "hull_drag_coeff": base.hull_drag_coeff
        };
    }
    return doc;
}

def simulate_document(document: dict, tier: str = "lowest") -> dict {
    return run_brief(document, tier);
}

# ---------------------------------------------------------------------------
# Main campaign loop: simulate → assess → propose → repeat
# ---------------------------------------------------------------------------

def run_campaign(
    document_in: dict,
    tier: str = "lowest",
    max_iterations: int = MAX_ITERATIONS,
    run_id: str | None = None,
    mode: str = "brief"
) -> dict {
    document = ensure_document_zones(clone_json(document_in), tier);
    rid = run_id if run_id else now_iso().replace(":", "-").replace(".", "-");
    run_dir = SIM_DIR / rid;
    campaign_memory_file = run_dir / "design_memory.json";
    run_dir.mkdir(parents=True, exist_ok=True);

    global_design_memory = read_json_if_exists(
        GLOBAL_DESIGN_MEMORY_FILE,
        empty_design_memory("global")
    );
    campaign_design_memory = read_json_if_exists(
        campaign_memory_file,
        empty_design_memory("campaign")
    );
    global_design_memory["scope"] = "global";
    campaign_design_memory["scope"] = "campaign";

    iterations: list[dict] = [];
    manifest: dict[str, any] = {
        "run_id": rid,
        "model": "model-pool",
        "mode": mode,
        "tier": tier if mode == "brief" else None,
        "mission_id": document.get("id") if mode == "brief" else None,
        "mission_name": document.get("name") if mode == "brief" else None,
        "started_at": now_iso(),
        "iterations": iterations,
        "best_survivor": None,
        "best_potential": None,
        "search": {
            "strategy": "sequential adaptive exploration",
            "exploration_strategies": EXPLORATION_STRATEGIES
        },
        "memory": {
            "enabled": True,
            "type": "persistent design memory",
            "global_file": str(GLOBAL_DESIGN_MEMORY_FILE.relative_to(ROOT)),
            "campaign_file": str(campaign_memory_file.relative_to(ROOT))
        }
    };

    best_survivor_document: dict | None = None;
    best_potential_document: dict = clone_json(document);
    visited: set = {candidate_signature(document, mode)};

    for i in range(1, max_iterations + 1) {
        stop_after = False;
        iteration_strategy = "gemini";
        iteration_id = f"iteration-{str(i).zfill(2)}";
        iteration_dir = run_dir / iteration_id;
        iteration_dir.mkdir(parents=True, exist_ok=True);
        params_file = iteration_dir / "params.json";
        result_file = iteration_dir / "result.json";
        assessment_file = iteration_dir / "assessment.json";

        run_document = clone_json(document);
        write_json(params_file, run_document);

        # simulate
        if mode == "brief" {
            # Once zones are present, run_brief uses custom config (tier ignored).
            result = simulate_document(run_document, tier);
        } else {
            raise ValueError("params mode is not supported in the Jac agent; use mission briefs");
        }
        write_json(result_file, result);

        # After the first tiered run, capture effective zones into the document
        # so subsequent iterations always mutate an explicit configuration.
        if not isinstance(document.get("zones"), list) or len(document.get("zones", [])) == 0 {
            document["zones"] = complete_zones_from_result(result, []);
            document["propulsion"] = effective_propulsion_from_result(result, document);
            run_document = clone_json(document);
            write_json(params_file, run_document);
        }

        cost_usd = result_cost_usd(result);
        candidate_potential = potential_score(result);

        assessment: dict = {
            "assessment": (
                "Simulation reached SUCCESS. Continuing search for a cheaper viable configuration."
                if result.get("status") == "survived"
                else "Simulation failed before LLM assessment completed."
            ),
            "changes": [],
            "brief": document
        };

        # Track best survivor / best potential
        if result.get("status") == "survived" {
            candidate_best = {
                "id": f"{rid}/{iteration_id}",
                "run_id": rid,
                "iteration": i,
                "total_config_cost_usd": cost_usd if cost_usd < float("inf") else None,
                "result_file": str(result_file.relative_to(ROOT)),
                "params_file": str(params_file.relative_to(ROOT))
            };
            if (
                manifest["best_survivor"] is None
                or (
                    cost_usd < float("inf")
                    and cost_usd < float(
                        coalesce(
                            (manifest["best_survivor"] as dict).get("total_config_cost_usd", float("inf"))
                            if isinstance(manifest["best_survivor"], dict)
                            else float("inf"),
                            float("inf")
                        )
                    )
                )
            ) {
                manifest["best_survivor"] = candidate_best;
                best_survivor_document = clone_json(run_document);
            }
        }

        best_pot_score = -float("inf");
        if isinstance(manifest["best_potential"], dict) {
            bp: dict = manifest["best_potential"];
            best_pot_score = safe_float(bp.get("score", -float("inf")), -float("inf"));
        }
        best_pot_cost = float("inf");
        if isinstance(manifest["best_potential"], dict) {
            bp2: dict = manifest["best_potential"];
            best_pot_cost = safe_float(
                coalesce(bp2.get("total_config_cost_usd", float("inf")), float("inf")),
                float("inf")
            );
        }
        if (
            manifest["best_potential"] is None
            or candidate_potential > best_pot_score
            or (
                candidate_potential == best_pot_score
                and cost_usd < float("inf")
                and cost_usd < best_pot_cost
            )
        ) {
            manifest["best_potential"] = {
                "id": f"{rid}/{iteration_id}",
                "run_id": rid,
                "iteration": i,
                "score": candidate_potential,
                "status": result.get("status"),
                "failure": result.get("failure"),
                "total_config_cost_usd": cost_usd if cost_usd < float("inf") else None,
                "result_file": str(result_file.relative_to(ROOT)),
                "params_file": str(params_file.relative_to(ROOT))
            };
            best_potential_document = clone_json(run_document);
        }

        # assess → propose (skip on final iteration)
        if i < max_iterations {
            try {
                pre_emergency = None;
                if (
                    manifest["best_survivor"] is None
                    and mode == "brief"
                    and result.get("status") != "survived"
                ) {
                    pre_emergency = emergency_survival_escalation(
                        document, result, iterations
                    );
                }
                if pre_emergency is not None {
                    document = pre_emergency["document"];
                    visited.add(candidate_signature(document, mode));
                    iteration_strategy = "emergency-survival-escalation";
                    assessment = apply_emergency_assessment({
                        "assessment": (
                            "No survivor exists yet. Applying staged survival plateau repair "
                            + "before asking the LLM for cost optimization."
                        ),
                        "changes": [],
                        "zones": document["zones"],
                        "propulsion": document.get("propulsion"),
                        "brief": document,
                        "model_used": "local-survival-first"
                    }, pre_emergency);
                    assessment["repaired_zones"] = document["zones"];
                    raise RuntimeError("__SURVIVAL_FIRST_APPLIED__");
                }

                best_survivor_ctx = None;
                if manifest["best_survivor"] is not None {
                    best_survivor_ctx = dict(manifest["best_survivor"]);
                    best_survivor_ctx["zones"] = (
                        best_survivor_document.get("zones") if best_survivor_document else None
                    );
                    best_survivor_ctx["propulsion"] = (
                        best_survivor_document.get("propulsion") if best_survivor_document else None
                    );
                }
                best_potential_ctx = None;
                if manifest["best_potential"] is not None {
                    best_potential_ctx = dict(manifest["best_potential"]);
                    best_potential_ctx["zones"] = best_potential_document.get("zones");
                    best_potential_ctx["propulsion"] = best_potential_document.get("propulsion");
                }

                ctx = build_search_context(
                    document=document,
                    result=result,
                    iteration=i,
                    max_iterations=max_iterations,
                    best_survivor=best_survivor_ctx,
                    best_potential=best_potential_ctx,
                    history=iterations,
                    design_memory={
                        "global": compact_design_memory(
                            global_design_memory, document.get("id", "params")
                        ),
                        "campaign": compact_design_memory(
                            campaign_design_memory, document.get("id", "params")
                        )
                    }
                );
                llm_assessment = propose_next_config(ctx);
                assessment = assessment_to_dict(llm_assessment);
                assessment["model_used"] = "model-pool";
                next_document = next_document_from_assessment(assessment, document, result);
                next_signature = candidate_signature(next_document, mode);

                should_force_explore = (
                    result.get("status") == "survived"
                    and (
                        next_signature == candidate_signature(document, mode)
                        or next_signature in visited
                        or i % 3 == 0
                    )
                );

                if should_force_explore {
                    exploration = mutate_exploratory_document(
                        document, result, best_survivor_document, mode, i
                    );
                    if exploration is not None {
                        next_document = exploration["document"];
                        next_signature = candidate_signature(next_document, mode);
                        iteration_strategy = f"explore:{exploration['strategy']}";
                        assessment["search_strategy"] = iteration_strategy;
                        assessment["exploration_targets"] = exploration["targets"];
                        assessment["assessment"] = (
                            f"{coalesce(assessment.get('assessment'), 'LLM candidate reviewed.')} "
                            + f"Branching into {exploration['strategy']} to test another design path."
                        );
                    }
                }

                # Duplicate detection — replace with exploratory branch
                if next_signature in visited {
                    exploration = mutate_exploratory_document(
                        document, result, best_survivor_document, mode, i + 1
                    );
                    if exploration is not None {
                        next_document = exploration["document"];
                        next_signature = candidate_signature(next_document, mode);
                        iteration_strategy = f"explore:{exploration['strategy']}";
                        assessment["search_strategy"] = iteration_strategy;
                        assessment["exploration_targets"] = exploration["targets"];
                        assessment["assessment"] = (
                            f"{coalesce(assessment.get('assessment'), 'Duplicate candidate avoided.')} "
                            + f"Replaced duplicate with {exploration['strategy']}."
                        );
                    }
                }

                if mode == "brief" and result.get("status") != "survived" {
                    emergency = emergency_survival_escalation(
                        next_document, result, iterations
                    );
                    if emergency is not None {
                        next_document = emergency["document"];
                        next_signature = candidate_signature(next_document, mode);
                        iteration_strategy = "emergency-survival-escalation";
                        assessment = apply_emergency_assessment(assessment, emergency);
                    }
                }

                visited.add(next_signature);
                document = next_document;
                if mode == "brief" {
                    assessment["repaired_zones"] = document["zones"];
                }
            } except Exception as error {
                msg = str(error);
                if msg == "__SURVIVAL_FIRST_APPLIED__" {
                    # Deterministic survival-first branch already prepared next document.
                } elif mode == "brief" and result.get("status") == "survived" {
                    exploration = mutate_exploratory_document(
                        document, result, best_survivor_document, mode, i
                    );
                    if exploration is not None {
                        document = exploration["document"];
                        visited.add(candidate_signature(document, mode));
                        iteration_strategy = f"explore:{exploration['strategy']}";
                        assessment = {
                            "assessment": (
                                f"LLM could not produce the next candidate ({msg}). "
                                + f"Continuing with {exploration['strategy']}."
                            ),
                            "changes": [f"Local exploratory branch: {exploration['strategy']}"],
                            "zones": document["zones"],
                            "propulsion": document.get("propulsion"),
                            "brief": document,
                            "model_used": "local-exploration-fallback",
                            "search_strategy": iteration_strategy,
                            "exploration_targets": exploration["targets"],
                            "error": msg
                        };
                    } else {
                        assessment = {
                            "assessment": (
                                "Simulation reached SUCCESS, but no exploratory candidate "
                                + f"could be produced: {msg}"
                            ),
                            "changes": [],
                            "brief": document,
                            "error": msg
                        };
                        stop_after = True;
                    }
                } elif mode == "brief" {
                    assessment = local_repair_assessment(document, result);
                    assessment["gemini_error"] = msg;
                    document = next_document_from_assessment(assessment, document, result);
                    visited.add(candidate_signature(document, mode));
                    iteration_strategy = assessment.get("model_used", "local-repair");
                    assessment["repaired_zones"] = document["zones"];
                } else {
                    assessment = {
                        "assessment": f"LLM assessment failed: {msg}",
                        "changes": [],
                        "params": document,
                        "error": msg
                    };
                    stop_after = True;
                }
            }
        }

        strategy_for_memory = assessment.get("search_strategy", iteration_strategy);
        record_design_memory(
            global_design_memory,
            run_document,
            result,
            assessment,
            i,
            strategy_for_memory,
            candidate_potential
        );
        record_design_memory(
            campaign_design_memory,
            run_document,
            result,
            assessment,
            i,
            strategy_for_memory,
            candidate_potential
        );
        write_json(GLOBAL_DESIGN_MEMORY_FILE, global_design_memory);
        write_json(campaign_memory_file, campaign_design_memory);
        write_json(assessment_file, assessment);

        iterations.append({
            "id": f"{rid}/{iteration_id}",
            "run_id": rid,
            "iteration": i,
            "status": result.get("status"),
            "failure": result.get("failure"),
            "result": result.get("result"),
            "total_config_cost_usd": cost_usd if cost_usd < float("inf") else None,
            "strategy": assessment.get("search_strategy", iteration_strategy),
            "params_file": str(params_file.relative_to(ROOT)),
            "result_file": str(result_file.relative_to(ROOT)),
            "assessment_file": str(assessment_file.relative_to(ROOT))
        });
        manifest["iterations"] = iterations;
        write_json(run_dir / "manifest.json", manifest);

        if stop_after {
            break;
        }
    }

    manifest["completed_at"] = now_iso();
    write_json(run_dir / "manifest.json", manifest);
    return manifest;
}

# ---------------------------------------------------------------------------
# CLI entry
# ---------------------------------------------------------------------------

def:priv _arg_value(argv: list[str], name: str, fallback: str | None = None) -> str | None {
    prefix = f"--{name}=";
    for arg in argv {
        if arg.startswith(prefix) {
            return arg[len(prefix):];
        }
    }
    flag = f"--{name}";
    if flag in argv {
        idx = argv.index(flag);
        if idx + 1 < len(argv) {
            return argv[idx + 1];
        }
    }
    return fallback;
}

def:priv _has_flag(argv: list[str], name: str) -> bool {
    return f"--{name}" in argv;
}

def main(argv: list[str] | None = None) -> dict {
    import sys;
    args = list(argv) if argv is not None else list(sys.argv[1:]);

    # Load .env if present (do not overwrite existing env)
    env_path = ROOT / ".env";
    if env_path.exists() {
        for line in env_path.read_text(encoding="utf-8").splitlines() {
            trimmed = line.strip();
            if not trimmed or trimmed.startswith("#") {
                continue;
            }
            if "=" not in trimmed {
                continue;
            }
            (key, value) = trimmed.split("=", 1);
            key = key.strip();
            value = value.strip().strip("'").strip('"');
            if key and key not in os.environ {
                os.environ[key] = value;
            }
        }
    }

    if os.environ.get("JAC_AGENT_MOCK", "") != "1" and not os.environ.get("GEMINI_API_KEY") {
        print("Warning: GEMINI_API_KEY not set — live LLM calls will fail; set JAC_AGENT_MOCK=1 for tests.");
    }

    mission_id = _arg_value(args, "mission-id", None);
    brief_arg = _arg_value(args, "brief", None);
    mission_file = mission_brief_file_by_id(mission_id) if mission_id else None;
    if mission_id and mission_file is None {
        raise ValueError(
            f"Unknown mission id '{mission_id}'. Expected one of mission-briefs/*.json id values."
        );
    }

    if mission_file is not None {
        input_file = mission_file;
    } elif brief_arg {
        input_file = (ROOT / brief_arg).resolve();
    } else {
        input_file = (ROOT / coalesce(_arg_value(args, "input", "examples/simulation_params.json"), "examples/simulation_params.json")).resolve();
    }

    tier = coalesce(_arg_value(args, "tier", "lowest"), "lowest");
    max_iter = int(coalesce(_arg_value(args, "max-iterations", str(MAX_ITERATIONS)), str(MAX_ITERATIONS)));
    run_id = _arg_value(args, "run-id", None);

    if _has_flag(args, "clear-simulations") {
        SIM_DIR.mkdir(parents=True, exist_ok=True);
        for entry in SIM_DIR.iterdir() {
            if entry.name == ".gitkeep" {
                continue;
            }
            if entry.is_dir() {
                import shutil;
                shutil.rmtree(entry, ignore_errors=True);
            } else {
                entry.unlink(missing_ok=True);
            }
        }
    }

    document = read_json(input_file);
    if not isinstance(document, dict) {
        raise ValueError("input must be a JSON object");
    }
    mode = "brief";
    manifest = run_campaign(
        document_in=document,
        tier=tier,
        max_iterations=max_iter,
        run_id=run_id,
        mode=mode
    );
    print(json.dumps(manifest, indent=2, default=_json_default));
    return manifest;
}

# ---------------------------------------------------------------------------
# Tests — ordinary Jac logic + MockLLM path
# ---------------------------------------------------------------------------

test "normalize_zones completes nine hull zones" {
    zones = normalize_zones([{"zone": "keel", "material": "Eh36", "thickness_m": 0.01}]);
    assert len(zones) == 9;
    assert zones[0]["zone"] == "Keel";
    assert zones[0]["material"] == "Eh36";
    assert zones[0]["thickness_m"] == 0.01;
    assert zones[1]["zone"] == "BilgeStrake";
}

test "complete_zones_from_result merges result and candidate" {
    result = {
        "configuration": {
            "zones": [
                {
                    "zone_key": "Keel",
                    "material": "MildSteelA",
                    "thickness_m": 0.004,
                    "weld_quality": "Economy",
                    "seal_quality": "Economy"
                }
            ]
        }
    };
    complete = complete_zones_from_result(
        result,
        [{"zone": "Keel", "material": "Eh36", "thickness_m": 0.008, "weld_quality": "Premium"}]
    );
    assert len(complete) == 9;
    assert complete[0]["material"] == "Eh36";
    assert complete[0]["weld_quality"] == "Premium";
}

test "potential_score rewards survival and late failures" {
    failed = {
        "status": "failed",
        "failure": {"completion_pct": 80.0, "detail": {"failed_zone": "Keel"}},
        "result": {"total_config_cost_usd": 10000.0}
    };
    survived = {
        "status": "survived",
        "failure": None,
        "result": {"distance_completed_pct": 100.0, "total_config_cost_usd": 10000.0}
    };
    assert potential_score(survived) > potential_score(failed);
}

test "emergency_survival_escalation triggers after plateau" {
    document = {
        "id": "test",
        "zones": normalize_zones([]),
        "propulsion": dict(DEFAULT_PROPULSION)
    };
    result = {
        "status": "failed",
        "failure": {
            "completion_pct": 42.0,
            "detail": {"failed_zone": "Keel", "failed_metric": "fatigue"},
            "mode": "Fatigue Failure",
            "why": "fatigue"
        },
        "ticks": [{"zones": [{"zone": "Keel", "fatigue_consumed": 0.9, "crack_half_length_mm": 1.0, "peak_stress_mpa": 100.0, "corrosion_depth_mm": 0.0}]}]
    };
    history = [];
    for _ in range(5) {
        history.append({"failure": {"completion_pct": 42.0}, "result": {}});
    }
    emergency = emergency_survival_escalation(document, result, history);
    assert emergency is not None;
    assert emergency["stage"] >= 1;
    keel = None;
    for z in emergency["document"]["zones"] {
        if z["zone"] == "Keel" {
            keel = z;
            break;
        }
    }
    assert keel is not None;
    assert keel["weld_quality"] == "Premium";
    assert keel["thickness_m"] >= 0.016;
}

test "mutate_exploratory_document rotates strategies" {
    document = {
        "id": "test",
        "zones": normalize_zones([]),
        "propulsion": dict(DEFAULT_PROPULSION)
    };
    result = {
        "status": "survived",
        "configuration": {"zones": [], "propulsion": dict(DEFAULT_PROPULSION)},
        "ticks": [{"zones": []}],
        "result": {"total_config_cost_usd": 12000.0, "distance_completed_pct": 100.0}
    };
    exploration = mutate_exploratory_document(document, result, document, "brief", 1);
    assert exploration is not None;
    assert exploration["strategy"] == "targeted_reinforcement";
    assert candidate_signature(exploration["document"], "brief") != candidate_signature(document, "brief");
}

test "duplicate detection signature ignores mission metadata" {
    a = {
        "id": "x",
        "name": "A",
        "zones": normalize_zones([{"zone": "Keel", "thickness_m": 0.005}]),
        "propulsion": dict(DEFAULT_PROPULSION)
    };
    b = {
        "id": "y",
        "name": "B",
        "zones": normalize_zones([{"zone": "Keel", "thickness_m": 0.005}]),
        "propulsion": dict(DEFAULT_PROPULSION)
    };
    assert candidate_signature(a, "brief") == candidate_signature(b, "brief");
}

test "MockLLM is wired when JAC_AGENT_MOCK=1" {
    # Module llm is constructed at import time from JAC_AGENT_MOCK.
    assert isinstance(llm, MockLLM);
    assert "outputs" in llm.config;
    assert len(llm.config["outputs"]) >= 1;
}

test "assessment_to_dict roundtrips BriefAssessment" {
    zones = zones_to_proposals(normalize_zones([
        {"zone": "Keel", "material": "Eh36", "thickness_m": 0.008, "weld_quality": "Premium", "seal_quality": "Marine"}
    ]));
    assessment = BriefAssessment(
        assessment="Keel fatigue failure",
        failed_part="Keel",
        failed_metric=FailedMetric.FATIGUE,
        root_cause="weld toe crack",
        changes=["Keel reinforced"],
        zones=zones,
        propulsion=propulsion_to_spec(DEFAULT_PROPULSION)
    );
    as_dict = assessment_to_dict(assessment);
    assert as_dict["assessment"] == "Keel fatigue failure";
    assert as_dict["failed_part"] == "Keel";
    assert len(as_dict["zones"]) == 9;
    assert as_dict["zones"][0]["material"] == "Eh36";
}

with entry {
    import sys;
    # jac run agent.jac -- --mission-id=01_north_atlantic_sprint --max-iterations=3
    if len(sys.argv) > 1 {
        main(sys.argv[1:]);
    }
}
