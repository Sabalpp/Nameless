"""Structural fatigue and fracture physics — ported from src/physics/structural.rs.

CRITICAL: stirling_gamma and gamma_1_plus_m_half are ported VERBATIM from Rust.
Do NOT substitute math.gamma — that would silently shift every fatigue number.
"""

import from math { sqrt, pi, e, pow }
import from engine.types {
    HullGeometry,
    HullZone,
    MaterialSpec,
    ZoneSpec,
    OceanConditions,
    hull_zone_bending_factor,
    hull_zone_slam_factor
}
import from engine.materials { scf }
import from engine.hull { i_section_m4 }
import from engine.ocean {
    encounter_factor,
    zero_crossing_period_s,
    steepness
}

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

# Significant bending stress amplitude at a hull zone [MPa].
# Uses linear wave theory bending moment (Froude-Krylov) on the hull girder,
# divided by the hollow-box section modulus. Spectral approach: stress is
# scaled to the significant (1/3-highest) level — used downstream in the
# narrow-band Rayleigh fatigue integral.
def significant_stress_mpa(
    hull: HullGeometry,
    conditions: OceanConditions,
    zone: HullZone,
    zone_spec: ZoneSpec
) -> float {
    rho_water: float = 1025.0;
    g: float = 9.81;

    # Wave-induced pressure amplitude at hull surface
    p_sig = rho_water * g * conditions.hs_m * encounter_factor(conditions);

    # Global bending moment on hull girder (Ochi approximation for slender hulls)
    m_bending = p_sig * pow(hull.loa_m, 2.0) * hull.beam_m * hull.block_coeff * 0.5;

    # Effective plate thickness after any prior corrosion (starts at nominal)
    t_eff = zone_spec.thickness_m;

    # Hollow-box section modulus Z = I / (depth/2)
    i_sec = i_section_m4(hull, t_eff);
    z_sec = i_sec / max(hull.depth_m * 0.5, 0.01);

    # Nominal significant stress at midship reference point [Pa → MPa]
    sigma_nominal_mpa = (m_bending / max(z_sec, 1e-6)) / 1e6;

    # Apply zone-specific bending amplification and slam factor
    sigma_zone = (
        sigma_nominal_mpa
        * hull_zone_bending_factor(zone)
        * zone_slam_factor_for(zone, conditions)
    );

    # Apply weld stress concentration factor (multiplies effective stress at joint toe)
    return sigma_zone * scf(zone_spec.weld_quality);
}

# Cumulative Miner's fatigue damage for one route segment [dimensionless].
# Implements the narrow-band Rayleigh approximation for random sea fatigue:
#   D = N_peaks × (σ_sig)^m × Γ(1 + m/2) / (2^m × C_sn)
# where C_sn = σ_ref^m × N_ref is derived from the material S-N class.
# This is an analytical per-segment calculation — no Monte Carlo sampling.
def segment_fatigue_damage(
    hull: HullGeometry,
    conditions: OceanConditions,
    zone: HullZone,
    zone_spec: ZoneSpec,
    material: MaterialSpec,
    duration_s: float
) -> float {
    sigma_sig = significant_stress_mpa(hull, conditions, zone, zone_spec);

    # Below endurance limit for this material — no damage accumulates
    endurance = material.sn_ref_stress_mpa * 0.40;
    if sigma_sig < endurance {
        return 0.0;
    }

    # Zero-crossing period from spectral shape → number of stress peaks
    tz = zero_crossing_period_s(conditions);
    n_peaks = duration_s / max(tz, 0.5);

    # S-N capacity constant: C_sn = σ_ref^m × N_ref
    m = material.sn_slope;
    c_sn = pow(material.sn_ref_stress_mpa, m) * float(material.sn_ref_cycles);

    # Rayleigh distribution correction Γ(1 + m/2) / 2^m
    rayleigh_factor = gamma_1_plus_m_half(m) / pow(2.0, m);

    return n_peaks * pow(sigma_sig, m) * rayleigh_factor / c_sn;
}

# Stress intensity factor range [MPa·√m] for an edge crack in a plate.
# Uses the standard geometry factor F ≈ 1.12 for a surface crack under tension.
def stress_intensity_factor(stress_mpa: float, crack_half_length_m: float) -> float {
    f_geometry: float = 1.12;
    return stress_mpa * f_geometry * sqrt(pi * crack_half_length_m);
}

# Paris-law crack growth increment [m/cycle] given ΔK and material constants.
# Uses generic Paris exponents; C and n are embedded per material category.
def paris_crack_growth_per_cycle(delta_k_mpa_sqrtm: float, material: MaterialSpec) -> float {
    # Paris-law exponent and coefficient depend on material family
    (c_paris, n_paris) = paris_constants(material.e_gpa);
    if delta_k_mpa_sqrtm <= 0.0 {
        return 0.0;
    }
    return c_paris * pow(delta_k_mpa_sqrtm, n_paris);
}

# True if the crack has reached critical size for brittle fracture.
def is_critical_crack(crack_half_length_m: float, stress_mpa: float, k_ic: float) -> bool {
    return stress_intensity_factor(stress_mpa, crack_half_length_m) >= k_ic;
}

# ---------------------------------------------------------------------------
# Internal helpers (exported for parity / reuse)
# ---------------------------------------------------------------------------

# Γ(1 + m/2) for common S-N slope values m.
# Exact for integer and half-integer m; Stirling approximation otherwise.
# VERBATIM from Rust — do NOT replace with math.gamma.
def gamma_1_plus_m_half(m: float) -> float {
    x = 1.0 + m / 2.0;
    # Exact values for common cases
    match int(round(m * 2.0)) {
        case 6: return 1.3293;   # m=3:  Γ(2.5)
        case 8: return 2.0000;   # m=4:  Γ(3.0)
        case 10: return 3.3234;  # m=5:  Γ(3.5)
        case 12: return 6.0000;  # m=6:  Γ(4.0)
        case 20: return 120.00;  # m=10: Γ(6.0)
        case 24: return 720.00;  # m=12: Γ(7.0)
        case _: return stirling_gamma(x);
    }
}

# Stirling's approximation for Γ(x), accurate to ~1% for x ≥ 2.
# VERBATIM from Rust — do NOT replace with math.gamma.
def stirling_gamma(x: float) -> float {
    return sqrt(2.0 * pi / x) * pow(x / e, x);
}

# Paris law constants (C, n) keyed by Young's modulus [GPa].
# Returns (C, n) where da/dN = C × ΔK^n [m/cycle, MPa·√m].
def paris_constants(e_gpa: float) -> tuple[float, float] {
    if e_gpa > 150.0 {
        # Steel
        return (6.0e-12, 3.0);
    } elif e_gpa > 50.0 {
        # Aluminium or CFRP (high-modulus composite)
        return (1.4e-11, 3.5);
    } else {
        # GRP / low-modulus composite
        return (5.0e-10, 4.2);
    }
}

# Zone-aware slam factor scaled to sea state (from ZoneSlamFactor trait).
def zone_slam_factor_for(zone: HullZone, conditions: OceanConditions) -> float {
    base = hull_zone_slam_factor(zone);
    # Slam severity grows with wave steepness
    steep = steepness(conditions);
    steepness_boost = 1.0 + max(0.0, min(0.14, steep)) * 2.5;
    # Slamming events scale with declared probability
    slam_p = max(0.0, min(1.0, conditions.slam_probability));
    slam_active = 1.0 + slam_p * (base - 1.0);
    return slam_active * steepness_boost;
}
