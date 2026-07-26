"""Hull materials, weld/seal quality tables, and LandForge compat layer.

Ports src/vessel/materials.rs. Types are imported from the frozen contract
in engine/types.jac — methods are free functions (same pattern as hull_zone_*).
"""

import from engine.types {
    MaterialGrade, MaterialSpec, MaterialConfig, MaterialModel, WeldQuality, SealQuality
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def normalize_material_key(key: str) -> str {
    return "".join(c.lower() for c in key if c.isalnum());
}

def _clamp(value: float, lo: float, hi: float) -> float {
    if value < lo { return lo; }
    if value > hi { return hi; }
    return value;
}

# ---------------------------------------------------------------------------
# MaterialGrade
# ---------------------------------------------------------------------------

def all_material_grades() -> list[MaterialGrade] {
    return [
        MaterialGrade.MILD_STEEL_A,
        MaterialGrade.MILD_STEEL_E,
        MaterialGrade.AH36,
        MaterialGrade.DH36,
        MaterialGrade.EH36,
        MaterialGrade.EH40,
        MaterialGrade.ALUMINUM_5083,
        MaterialGrade.GRP_E_GLASS,
        MaterialGrade.CFRP_EPOXY,
    ];
}

def material_grade_spec(grade: MaterialGrade) -> MaterialSpec {
    match grade {
        case MaterialGrade.MILD_STEEL_A: return MaterialSpec(
            label="Mild Steel A",
            density_kg_m3=7850.0,
            yield_mpa=235.0,
            uts_mpa=400.0,
            e_gpa=206.0,
            k_ic_mpa_sqrtm=80.0,
            min_temp_c=0.0,
            sn_slope=3.0,
            sn_ref_stress_mpa=71.0,
            sn_ref_cycles=2000000,
            cost_per_kg_usd=0.85,
            base_corrosion_rate_mm_yr=0.18,
        );
        case MaterialGrade.MILD_STEEL_E: return MaterialSpec(
            label="Mild Steel E (cold-grade)",
            density_kg_m3=7850.0,
            yield_mpa=235.0,
            uts_mpa=400.0,
            e_gpa=206.0,
            k_ic_mpa_sqrtm=95.0,
            min_temp_c=-40.0,
            sn_slope=3.0,
            sn_ref_stress_mpa=71.0,
            sn_ref_cycles=2000000,
            cost_per_kg_usd=1.10,
            base_corrosion_rate_mm_yr=0.17,
        );
        case MaterialGrade.AH36: return MaterialSpec(
            label="AH36 High-Strength Steel",
            density_kg_m3=7850.0,
            yield_mpa=355.0,
            uts_mpa=490.0,
            e_gpa=206.0,
            k_ic_mpa_sqrtm=105.0,
            min_temp_c=0.0,
            sn_slope=3.0,
            sn_ref_stress_mpa=80.0,
            sn_ref_cycles=2000000,
            cost_per_kg_usd=1.25,
            base_corrosion_rate_mm_yr=0.14,
        );
        case MaterialGrade.DH36: return MaterialSpec(
            label="DH36 High-Strength Steel",
            density_kg_m3=7850.0,
            yield_mpa=355.0,
            uts_mpa=490.0,
            e_gpa=206.0,
            k_ic_mpa_sqrtm=115.0,
            min_temp_c=-20.0,
            sn_slope=3.0,
            sn_ref_stress_mpa=80.0,
            sn_ref_cycles=2000000,
            cost_per_kg_usd=1.40,
            base_corrosion_rate_mm_yr=0.13,
        );
        case MaterialGrade.EH36: return MaterialSpec(
            label="EH36 High-Strength Steel",
            density_kg_m3=7850.0,
            yield_mpa=355.0,
            uts_mpa=490.0,
            e_gpa=206.0,
            k_ic_mpa_sqrtm=130.0,
            min_temp_c=-40.0,
            sn_slope=3.0,
            sn_ref_stress_mpa=80.0,
            sn_ref_cycles=2000000,
            cost_per_kg_usd=1.60,
            base_corrosion_rate_mm_yr=0.12,
        );
        case MaterialGrade.EH40: return MaterialSpec(
            label="EH40 Ultra-High-Strength Steel",
            density_kg_m3=7850.0,
            yield_mpa=390.0,
            uts_mpa=510.0,
            e_gpa=206.0,
            k_ic_mpa_sqrtm=140.0,
            min_temp_c=-40.0,
            sn_slope=3.0,
            sn_ref_stress_mpa=92.0,
            sn_ref_cycles=2000000,
            cost_per_kg_usd=1.85,
            base_corrosion_rate_mm_yr=0.09,
        );
        case MaterialGrade.ALUMINUM_5083: return MaterialSpec(
            label="Aluminium 5083-H116",
            density_kg_m3=2660.0,
            yield_mpa=215.0,
            uts_mpa=305.0,
            e_gpa=70.3,
            k_ic_mpa_sqrtm=35.0,
            min_temp_c=-65.0,
            sn_slope=5.0,
            sn_ref_stress_mpa=40.0,
            sn_ref_cycles=2000000,
            cost_per_kg_usd=4.20,
            base_corrosion_rate_mm_yr=0.015,
        );
        case MaterialGrade.GRP_E_GLASS: return MaterialSpec(
            label="E-glass / Polyester GRP",
            density_kg_m3=1680.0,
            yield_mpa=90.0,
            uts_mpa=220.0,
            e_gpa=14.0,
            k_ic_mpa_sqrtm=8.0,
            min_temp_c=-30.0,
            sn_slope=10.0,
            sn_ref_stress_mpa=35.0,
            sn_ref_cycles=2000000,
            cost_per_kg_usd=6.50,
            base_corrosion_rate_mm_yr=0.002,
        );
        case MaterialGrade.CFRP_EPOXY: return MaterialSpec(
            label="CFRP Epoxy Laminate",
            density_kg_m3=1550.0,
            yield_mpa=300.0,
            uts_mpa=600.0,
            e_gpa=70.0,
            k_ic_mpa_sqrtm=30.0,
            min_temp_c=-55.0,
            sn_slope=12.0,
            sn_ref_stress_mpa=150.0,
            sn_ref_cycles=2000000,
            cost_per_kg_usd=85.0,
            base_corrosion_rate_mm_yr=0.0,
        );
    }
}

def material_grade_corrodes(grade: MaterialGrade) -> bool {
    return grade in [
        MaterialGrade.MILD_STEEL_A,
        MaterialGrade.MILD_STEEL_E,
        MaterialGrade.AH36,
        MaterialGrade.DH36,
        MaterialGrade.EH36,
        MaterialGrade.EH40,
    ];
}

def material_grade_from_key(key: str) -> MaterialGrade | None {
    normalized = normalize_material_key(key);
    match normalized {
        case "mildsteela" | "mildsteeltemperate" | "mildsteel":
            return MaterialGrade.MILD_STEEL_A;
        case "mildsteele" | "mildsteelcoldweather" | "mildsteelcoldgrade":
            return MaterialGrade.MILD_STEEL_E;
        case "ah36" | "ah36steel" | "highstrengthah36":
            return MaterialGrade.AH36;
        case "dh36" | "dh36steel" | "highstrengthdh36":
            return MaterialGrade.DH36;
        case "eh36" | "eh36steel" | "highstrengtheh36":
            return MaterialGrade.EH36;
        case "eh40" | "eh40steel" | "ultrahighstrengtheh40":
            return MaterialGrade.EH40;
        case "aluminum5083" | "aluminium5083" | "al5083":
            return MaterialGrade.ALUMINUM_5083;
        case "grp" | "grpeglass" | "grpfiberglass" | "fiberglass":
            return MaterialGrade.GRP_E_GLASS;
        case "cfrp" | "cfrpepoxy" | "cfrpcarbonfiber" | "carbonfiber":
            return MaterialGrade.CFRP_EPOXY;
        case _:
            return None;
    }
}

# ---------------------------------------------------------------------------
# LandForge extra grades
# ---------------------------------------------------------------------------

def landforge_grade_spec(key: str) -> MaterialSpec | None {
    normalized = normalize_material_key(key);
    match normalized {
        case "al5086" | "aluminum5086" | "aluminium5086":
            return MaterialSpec(
                label="Aluminum 5086",
                density_kg_m3=2660.0,
                yield_mpa=195.0,
                uts_mpa=290.0,
                e_gpa=70.3,
                k_ic_mpa_sqrtm=35.0,
                min_temp_c=-65.0,
                sn_slope=5.0,
                sn_ref_stress_mpa=38.0,
                sn_ref_cycles=2000000,
                cost_per_kg_usd=4.0,
                base_corrosion_rate_mm_yr=0.018,
            );
        case "tigrade5" | "titaniumgrade5":
            return MaterialSpec(
                label="Titanium Grade 5",
                density_kg_m3=4430.0,
                yield_mpa=880.0,
                uts_mpa=950.0,
                e_gpa=114.0,
                k_ic_mpa_sqrtm=75.0,
                min_temp_c=-200.0,
                sn_slope=5.0,
                sn_ref_stress_mpa=240.0,
                sn_ref_cycles=2000000,
                cost_per_kg_usd=112.5,
                base_corrosion_rate_mm_yr=0.001,
            );
        case "stainlesssteel" | "stainlesssteel316":
            return MaterialSpec(
                label="Stainless Steel 316",
                density_kg_m3=8000.0,
                yield_mpa=290.0,
                uts_mpa=580.0,
                e_gpa=193.0,
                k_ic_mpa_sqrtm=120.0,
                min_temp_c=-196.0,
                sn_slope=3.0,
                sn_ref_stress_mpa=75.0,
                sn_ref_cycles=2000000,
                cost_per_kg_usd=5.0,
                base_corrosion_rate_mm_yr=0.015,
            );
        case "stainlesssteel304":
            return MaterialSpec(
                label="Stainless Steel 304",
                density_kg_m3=8000.0,
                yield_mpa=215.0,
                uts_mpa=515.0,
                e_gpa=193.0,
                k_ic_mpa_sqrtm=120.0,
                min_temp_c=-196.0,
                sn_slope=3.0,
                sn_ref_stress_mpa=70.0,
                sn_ref_cycles=2000000,
                cost_per_kg_usd=4.0,
                base_corrosion_rate_mm_yr=0.025,
            );
        case "nickelalloy" | "nickelalloy625" | "nickelsuperalloy":
            return MaterialSpec(
                label="Nickel Alloy 625",
                density_kg_m3=8440.0,
                yield_mpa=460.0,
                uts_mpa=880.0,
                e_gpa=207.0,
                k_ic_mpa_sqrtm=150.0,
                min_temp_c=-196.0,
                sn_slope=3.0,
                sn_ref_stress_mpa=115.0,
                sn_ref_cycles=2000000,
                cost_per_kg_usd=42.5,
                base_corrosion_rate_mm_yr=0.003,
            );
        case "chromolysteel":
            return MaterialSpec(
                label="Chromoly Steel",
                density_kg_m3=7850.0,
                yield_mpa=435.0,
                uts_mpa=670.0,
                e_gpa=205.0,
                k_ic_mpa_sqrtm=80.0,
                min_temp_c=-20.0,
                sn_slope=3.0,
                sn_ref_stress_mpa=90.0,
                sn_ref_cycles=2000000,
                cost_per_kg_usd=3.0,
                base_corrosion_rate_mm_yr=0.16,
            );
        case "castiron":
            return MaterialSpec(
                label="Cast Iron",
                density_kg_m3=7200.0,
                yield_mpa=130.0,
                uts_mpa=200.0,
                e_gpa=110.0,
                k_ic_mpa_sqrtm=20.0,
                min_temp_c=0.0,
                sn_slope=3.0,
                sn_ref_stress_mpa=35.0,
                sn_ref_cycles=2000000,
                cost_per_kg_usd=1.25,
                base_corrosion_rate_mm_yr=0.22,
            );
        case "kevlarcomposite":
            return MaterialSpec(
                label="Kevlar Composite",
                density_kg_m3=1440.0,
                yield_mpa=220.0,
                uts_mpa=360.0,
                e_gpa=70.0,
                k_ic_mpa_sqrtm=25.0,
                min_temp_c=-196.0,
                sn_slope=10.0,
                sn_ref_stress_mpa=85.0,
                sn_ref_cycles=2000000,
                cost_per_kg_usd=45.0,
                base_corrosion_rate_mm_yr=0.0,
            );
        case "ceramiccomposite" | "tungstencarbide":
            cost = 66.5 if normalized == "tungstencarbide" else 85.0;
            return MaterialSpec(
                label=key,
                density_kg_m3=3900.0,
                yield_mpa=500.0,
                uts_mpa=700.0,
                e_gpa=300.0,
                k_ic_mpa_sqrtm=8.0,
                min_temp_c=0.0,
                sn_slope=8.0,
                sn_ref_stress_mpa=130.0,
                sn_ref_cycles=2000000,
                cost_per_kg_usd=cost,
                base_corrosion_rate_mm_yr=0.0,
            );
        case _:
            return None;
    }
}

# ---------------------------------------------------------------------------
# MaterialConfig.spec() — LandForge / override layer
# ---------------------------------------------------------------------------

def _cost_as_usd_per_kg(config: MaterialConfig, density_kg_m3: float) -> float | None {
    if config.cost is None {
        return None;
    }
    cost = config.cost;
    unit = (config.cost_unit if config.cost_unit is not None else "USD/kg").lower();
    if "/kg" in unit {
        return cost;
    } elif "/l" in unit or "per l" in unit {
        kg_per_l = density_kg_m3 / 1000.0;
        if kg_per_l > 0.0 {
            return cost / kg_per_l;
        }
        return cost;
    } else {
        return cost;
    }
}

def _material_config_base_spec(config: MaterialConfig) -> MaterialSpec {
    if config.grade is not None {
        material_grade = material_grade_from_key(config.grade);
        if material_grade is not None {
            return material_grade_spec(material_grade);
        }
        lf = landforge_grade_spec(config.grade);
        if lf is not None {
            return lf;
        }
    }

    strength = 0.52;
    if config.strength_index is not None {
        strength = config.strength_index;
    }
    strength = _clamp(strength, 0.05, 1.0);

    label = "Custom Material";
    if config.label is not None {
        label = config.label;
    } elif config.grade is not None {
        label = config.grade;
    }

    corrosion = 0.10;
    if config.salinity_coeff is not None {
        corrosion = _clamp(config.salinity_coeff * 0.95, 0.0, 0.35);
    }

    min_temp = 0.0;
    if config.cold_threshold_c is not None {
        min_temp = config.cold_threshold_c;
    }

    sn_slope = 4.0 if strength > 0.75 else 3.0;

    return MaterialSpec(
        label=label,
        density_kg_m3=7850.0,
        yield_mpa=90.0 + 760.0 * strength,
        uts_mpa=160.0 + 900.0 * strength,
        e_gpa=70.0 + 150.0 * strength,
        k_ic_mpa_sqrtm=20.0 + 115.0 * strength,
        min_temp_c=min_temp,
        sn_slope=sn_slope,
        sn_ref_stress_mpa=35.0 + 115.0 * strength,
        sn_ref_cycles=2000000,
        cost_per_kg_usd=1.25,
        base_corrosion_rate_mm_yr=corrosion,
    );
}

"""MaterialConfig.spec() - apply explicit field overrides on top of base_spec."""
def material_config_spec(config: MaterialConfig) -> MaterialSpec {
    spec = _material_config_base_spec(config);

    if config.label is not None {
        spec.label = config.label;
    }
    if config.density_kg_m3 is not None {
        spec.density_kg_m3 = config.density_kg_m3;
    }
    if config.yield_mpa is not None {
        spec.yield_mpa = config.yield_mpa;
    }
    if config.uts_mpa is not None {
        spec.uts_mpa = config.uts_mpa;
    }
    if config.e_gpa is not None {
        spec.e_gpa = config.e_gpa;
    }
    if config.k_ic_mpa_sqrtm is not None {
        spec.k_ic_mpa_sqrtm = config.k_ic_mpa_sqrtm;
    }

    min_temp = config.min_temp_c;
    if min_temp is None {
        min_temp = config.cold_threshold_c;
    }
    if min_temp is not None {
        spec.min_temp_c = min_temp;
    }

    if config.sn_slope is not None {
        spec.sn_slope = config.sn_slope;
    }
    if config.sn_ref_stress_mpa is not None {
        spec.sn_ref_stress_mpa = config.sn_ref_stress_mpa;
    }
    if config.sn_ref_cycles is not None {
        spec.sn_ref_cycles = config.sn_ref_cycles;
    }

    if config.base_corrosion_rate_mm_yr is not None {
        spec.base_corrosion_rate_mm_yr = config.base_corrosion_rate_mm_yr;
    } elif config.salinity_coeff is not None {
        spec.base_corrosion_rate_mm_yr = _clamp(config.salinity_coeff * 0.95, 0.0, 0.35);
    }

    if config.cost_per_kg_usd is not None {
        spec.cost_per_kg_usd = config.cost_per_kg_usd;
    } else {
        converted = _cost_as_usd_per_kg(config, spec.density_kg_m3);
        if converted is not None {
            spec.cost_per_kg_usd = converted;
        }
    }

    return spec;
}

# ---------------------------------------------------------------------------
# MaterialModel resolution (string | MaterialGrade | MaterialConfig)
# ---------------------------------------------------------------------------

"""Mirror MaterialModel deserialize: string -> Grade or Config(grade=key)."""
def resolve_material_model(value: MaterialModel) -> MaterialModel {
    if isinstance(value, MaterialConfig) {
        return value;
    }
    if isinstance(value, MaterialGrade) {
        return value;
    }
    # str key
    grade = material_grade_from_key(value);
    if grade is not None {
        return grade;
    }
    if landforge_grade_spec(value) is not None {
        return MaterialConfig(grade=value);
    }
    raise ValueError(f"unknown material grade '{value}'");
}

"""MaterialModel.spec() - resolve string/grade/config to MaterialSpec."""
def material_spec(model: MaterialModel) -> MaterialSpec {
    if isinstance(model, MaterialConfig) {
        return material_config_spec(model);
    }
    if isinstance(model, MaterialGrade) {
        return material_grade_spec(model);
    }
    # str — same path as resolve then spec
    grade = material_grade_from_key(model);
    if grade is not None {
        return material_grade_spec(grade);
    }
    if landforge_grade_spec(model) is not None {
        return material_config_spec(MaterialConfig(grade=model));
    }
    raise ValueError(f"unknown material grade '{model}'");
}

"""MaterialModel.corrodes() - true when base_corrosion_rate_mm_yr > 0."""
def material_corrodes(model: MaterialModel) -> bool {
    return material_spec(model).base_corrosion_rate_mm_yr > 0.0;
}

# ---------------------------------------------------------------------------
# WeldQuality
# ---------------------------------------------------------------------------

def all_weld_qualities() -> list[WeldQuality] {
    return [WeldQuality.PREMIUM, WeldQuality.STANDARD, WeldQuality.ECONOMY];
}

"""Stress concentration factor at weld toe."""
def scf(weld: WeldQuality) -> float {
    match weld {
        case WeldQuality.PREMIUM: return 1.50;
        case WeldQuality.STANDARD: return 2.00;
        case WeldQuality.ECONOMY: return 2.65;
    }
}

"""Initial defect half-length [m] introduced by the weld process."""
def initial_crack_m(weld: WeldQuality) -> float {
    match weld {
        case WeldQuality.PREMIUM: return 0.05e-3;
        case WeldQuality.STANDARD: return 0.20e-3;
        case WeldQuality.ECONOMY: return 0.50e-3;
    }
}

"""Weld cost multiplier relative to Economy."""
def weld_cost_factor(weld: WeldQuality) -> float {
    match weld {
        case WeldQuality.PREMIUM: return 3.0;
        case WeldQuality.STANDARD: return 1.6;
        case WeldQuality.ECONOMY: return 1.0;
    }
}

def weld_label(weld: WeldQuality) -> str {
    match weld {
        case WeldQuality.PREMIUM: return "Premium (Class B+)";
        case WeldQuality.STANDARD: return "Standard (Class C)";
        case WeldQuality.ECONOMY: return "Economy (Class D)";
    }
}

# ---------------------------------------------------------------------------
# SealQuality
# ---------------------------------------------------------------------------

def all_seal_qualities() -> list[SealQuality] {
    return [SealQuality.MARINE, SealQuality.COMMERCIAL, SealQuality.ECONOMY];
}

"""Probability of maintaining integrity per hour of open-ocean operation."""
def hourly_survival_prob(seal: SealQuality) -> float {
    match seal {
        case SealQuality.MARINE: return 0.99990;
        case SealQuality.COMMERCIAL: return 0.99960;
        case SealQuality.ECONOMY: return 0.99850;
    }
}

def seal_cost_factor(seal: SealQuality) -> float {
    match seal {
        case SealQuality.MARINE: return 2.5;
        case SealQuality.COMMERCIAL: return 1.4;
        case SealQuality.ECONOMY: return 1.0;
    }
}

def seal_label(seal: SealQuality) -> str {
    match seal {
        case SealQuality.MARINE: return "Marine-grade EPDM";
        case SealQuality.COMMERCIAL: return "Commercial EPDM";
        case SealQuality.ECONOMY: return "Economy neoprene";
    }
}

# Shared names matching Rust WeldQuality/SealQuality::{cost_factor, label}.
def cost_factor(quality: WeldQuality | SealQuality) -> float {
    if isinstance(quality, WeldQuality) {
        return weld_cost_factor(quality);
    }
    return seal_cost_factor(quality);
}

def label(quality: WeldQuality | SealQuality) -> str {
    if isinstance(quality, WeldQuality) {
        return weld_label(quality);
    }
    return seal_label(quality);
}

# ---------------------------------------------------------------------------
# Optimizer string parsers (from main.rs)
# ---------------------------------------------------------------------------

def parse_material(s: str) -> MaterialGrade | None {
    return material_grade_from_key(s);
}

def parse_weld(s: str) -> WeldQuality | None {
    match s {
        case "Premium": return WeldQuality.PREMIUM;
        case "Standard": return WeldQuality.STANDARD;
        case "Economy": return WeldQuality.ECONOMY;
        case _: return None;
    }
}

def parse_seal(s: str) -> SealQuality | None {
    match s {
        case "Marine": return SealQuality.MARINE;
        case "Commercial": return SealQuality.COMMERCIAL;
        case "Economy": return SealQuality.ECONOMY;
        case _: return None;
    }
}
