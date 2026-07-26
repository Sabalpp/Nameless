"""SeaForge v3 physics engine ported from v2 Rust."""

import math;

def _sqrt(x: float) -> float { return float(math.sqrt(x)); }
def _cos(x: float) -> float { return float(math.cos(x)); }
def _sin(x: float) -> float { return float(math.sin(x)); }
def _atan2(y: float, x: float) -> float { return float(math.atan2(y, x)); }
def _abs_f(x: float) -> float { return float(abs(x)); }
def _pow_f(x: float, n: float) -> float { return float(x ** n); }

glob _PI: float = float(math.pi);
glob _E: float = float(math.e);

glob ALL_ZONES: list[str] = [
    "Keel", "BilgeStrake", "BottomPlating", "SidePlating", "BowFlare",
    "SternPlate", "TransomFrame", "WeatherDeck", "BulkheadFrame"
];
glob STEP_H: float = 1.0;
glob SIM_TIME_MULT: float = 100.0;
glob DAMAGE_MULT: float = 3.4;
glob CRACK_MULT: float = 0.12;
glob CORR_MULT: float = 5.0;

# ---------------------------------------------------------------------------
# Material spec
# ---------------------------------------------------------------------------

obj MaterialSpec {
    has label: str = "",
        density_kg_m3: float = 7850.0,
        yield_mpa: float = 235.0,
        uts_mpa: float = 400.0,
        e_gpa: float = 206.0,
        k_ic_mpa_sqrtm: float = 80.0,
        min_temp_c: float = 0.0,
        sn_slope: float = 3.0,
        sn_ref_stress_mpa: float = 71.0,
        sn_ref_cycles: int = 2000000,
        cost_per_kg_usd: float = 0.85,
        base_corrosion_rate_mm_yr: float = 0.18,
        corrodes: bool = True;
}

def get_material_spec(grade: str) -> MaterialSpec {
    if grade == "MildSteelE" {
        return MaterialSpec(label="Mild Steel E", density_kg_m3=7850.0, yield_mpa=235.0, uts_mpa=400.0, e_gpa=206.0, k_ic_mpa_sqrtm=95.0, min_temp_c=-40.0, sn_slope=3.0, sn_ref_stress_mpa=71.0, sn_ref_cycles=2000000, cost_per_kg_usd=1.10, base_corrosion_rate_mm_yr=0.17, corrodes=True);
    } elif grade == "Ah36" {
        return MaterialSpec(label="AH36 High-Strength Steel", density_kg_m3=7850.0, yield_mpa=355.0, uts_mpa=490.0, e_gpa=206.0, k_ic_mpa_sqrtm=105.0, min_temp_c=0.0, sn_slope=3.0, sn_ref_stress_mpa=80.0, sn_ref_cycles=2000000, cost_per_kg_usd=1.25, base_corrosion_rate_mm_yr=0.14, corrodes=True);
    } elif grade == "Dh36" {
        return MaterialSpec(label="DH36 High-Strength Steel", density_kg_m3=7850.0, yield_mpa=355.0, uts_mpa=490.0, e_gpa=206.0, k_ic_mpa_sqrtm=115.0, min_temp_c=-20.0, sn_slope=3.0, sn_ref_stress_mpa=80.0, sn_ref_cycles=2000000, cost_per_kg_usd=1.40, base_corrosion_rate_mm_yr=0.13, corrodes=True);
    } elif grade == "Eh36" {
        return MaterialSpec(label="EH36 High-Strength Steel", density_kg_m3=7850.0, yield_mpa=355.0, uts_mpa=490.0, e_gpa=206.0, k_ic_mpa_sqrtm=130.0, min_temp_c=-40.0, sn_slope=3.0, sn_ref_stress_mpa=80.0, sn_ref_cycles=2000000, cost_per_kg_usd=1.60, base_corrosion_rate_mm_yr=0.12, corrodes=True);
    } elif grade == "Eh40" {
        return MaterialSpec(label="EH40 Ultra-High-Strength Steel", density_kg_m3=7850.0, yield_mpa=390.0, uts_mpa=510.0, e_gpa=206.0, k_ic_mpa_sqrtm=140.0, min_temp_c=-40.0, sn_slope=3.0, sn_ref_stress_mpa=92.0, sn_ref_cycles=2000000, cost_per_kg_usd=1.85, base_corrosion_rate_mm_yr=0.09, corrodes=True);
    } elif grade == "Aluminum5083" {
        return MaterialSpec(label="Aluminium 5083-H116", density_kg_m3=2660.0, yield_mpa=215.0, uts_mpa=305.0, e_gpa=70.3, k_ic_mpa_sqrtm=35.0, min_temp_c=-65.0, sn_slope=5.0, sn_ref_stress_mpa=40.0, sn_ref_cycles=2000000, cost_per_kg_usd=4.20, base_corrosion_rate_mm_yr=0.015, corrodes=False);
    }
    return MaterialSpec(label="Mild Steel A", density_kg_m3=7850.0, yield_mpa=235.0, uts_mpa=400.0, e_gpa=206.0, k_ic_mpa_sqrtm=80.0, min_temp_c=0.0, sn_slope=3.0, sn_ref_stress_mpa=71.0, sn_ref_cycles=2000000, cost_per_kg_usd=0.85, base_corrosion_rate_mm_yr=0.18, corrodes=True);
}

def weld_scf(weld: str) -> float {
    if weld == "Premium" { return 1.50; }
    elif weld == "Standard" { return 2.00; }
    return 2.65;
}

def weld_initial_crack_m(weld: str) -> float {
    if weld == "Premium" { return 0.05e-3; }
    elif weld == "Standard" { return 0.20e-3; }
    return 0.50e-3;
}

def weld_cost_factor(weld: str) -> float {
    if weld == "Premium" { return 3.0; }
    elif weld == "Standard" { return 1.6; }
    return 1.0;
}

def seal_hourly_survival(seal: str) -> float {
    if seal == "Marine" { return 0.99990; }
    elif seal == "Commercial" { return 0.99960; }
    return 0.99850;
}

def seal_cost_factor(seal: str) -> float {
    if seal == "Marine" { return 2.5; }
    elif seal == "Commercial" { return 1.4; }
    return 1.0;
}

# ---------------------------------------------------------------------------
# Hull zone properties
# ---------------------------------------------------------------------------

def zone_bending_factor(zone: str) -> float {
    if zone == "Keel" { return 1.35; }
    elif zone == "BilgeStrake" { return 1.20; }
    elif zone == "BottomPlating" { return 1.10; }
    elif zone == "SidePlating" { return 0.75; }
    elif zone == "BowFlare" { return 1.05; }
    elif zone == "SternPlate" { return 0.85; }
    elif zone == "TransomFrame" { return 0.60; }
    elif zone == "WeatherDeck" { return 0.90; }
    return 0.70;
}

def zone_slam_factor(zone: str) -> float {
    if zone == "BowFlare" { return 2.80; }
    elif zone == "Keel" { return 1.80; }
    elif zone == "BilgeStrake" { return 1.40; }
    elif zone == "BottomPlating" { return 1.20; }
    return 1.00;
}

def zone_is_submerged(zone: str) -> bool {
    return zone in ["Keel", "BilgeStrake", "BottomPlating"];
}

# ---------------------------------------------------------------------------
# Ocean conditions helpers
# ---------------------------------------------------------------------------

def zero_crossing_period_s(tp_s: float, jonswap_gamma: float) -> float {
    inner = max(jonswap_gamma - 1.0, 0.0);
    correction = 1.0 - 0.132 * _sqrt(inner);
    return tp_s * max(0.68, min(0.78, correction));
}

def encounter_factor(encounter_angle_deg: float) -> float {
    angle_rad = encounter_angle_deg * _PI / 180.0;
    cos_val: float = _cos(angle_rad);
    return max(0.35, min(1.0, _abs_f(cos_val) * 0.65 + 0.35));
}

def wave_steepness(hs_m: float, tp_s: float) -> float {
    lambda_p = 9.81 * tp_s ** 2 / (2.0 * _PI);
    if lambda_p > 0.0 { return hs_m / lambda_p; }
    return 0.0;
}

# ---------------------------------------------------------------------------
# Hull geometry helpers
# ---------------------------------------------------------------------------

def draft_at_mass(loa_m: float, beam_m: float, block_coeff: float, mass_kg: float) -> float {
    denom = 1025.0 * loa_m * beam_m * block_coeff;
    if denom <= 0.0 { return 0.01; }
    return mass_kg / denom;
}

def wetted_area_m2(loa_m: float, beam_m: float, draft_m: float, block_coeff: float) -> float {
    return loa_m * (1.7 * draft_m + beam_m * block_coeff);
}

def i_section_m4(beam_m: float, depth_m: float, plate_t_m: float) -> float {
    t = max(0.001, plate_t_m);
    b_inner = max(0.0, beam_m - 2.0 * t);
    d_inner = max(0.0, depth_m - 2.0 * t);
    return (beam_m * depth_m ** 3 - b_inner * d_inner ** 3) / 12.0;
}

def i_waterplane_m4(loa_m: float, beam_m: float, wpc: float) -> float {
    return loa_m * beam_m ** 3 * wpc / 12.0;
}

# ---------------------------------------------------------------------------
# Corrosion
# ---------------------------------------------------------------------------

def corrosion_rate_mm_yr(base_rate: float, salinity_ppt: float, water_temp_c: float,
                          ph: float, submerged: bool) -> float {
    if base_rate <= 0.0 { return 0.0; }
    salinity_factor = max(0.3, min(1.4, salinity_ppt / 35.0));
    temp_delta = water_temp_c - 10.0;
    temp_factor = max(0.4, min(3.5, _pow_f(2.0, temp_delta / 10.0)));
    ph_diff = max(0.0, 8.1 - ph);
    ph_factor = max(1.0, min(2.2, 1.0 + 0.18 * ph_diff));
    immersion: float = 1.40 if submerged else 1.00;
    return base_rate * salinity_factor * temp_factor * ph_factor * immersion;
}

def thickness_loss_m(base_rate: float, salinity_ppt: float, water_temp_c: float,
                      ph: float, submerged: bool, duration_h: float) -> float {
    rate = corrosion_rate_mm_yr(base_rate, salinity_ppt, water_temp_c, ph, submerged);
    return rate * duration_h / (8760.0 * 1000.0);
}

def corrosion_fatigue_multiplier(corrodes: bool, base_rate: float,
                                  salinity_ppt: float, water_temp_c: float,
                                  ph: float, elapsed_h: float) -> float {
    if not corrodes { return 1.0; }
    rate = corrosion_rate_mm_yr(base_rate, salinity_ppt, water_temp_c, ph, True);
    pit_depth_mm = rate * _sqrt(elapsed_h / 8760.0);
    pit_scf = 1.0 + 8.0 * _sqrt(pit_depth_mm);
    return max(1.0, min(4.0, pit_scf));
}

# ---------------------------------------------------------------------------
# Structural: stress, fatigue, crack growth
# ---------------------------------------------------------------------------

def significant_stress_mpa(loa_m: float, beam_m: float, depth_m: float,
                             block_coeff: float, thickness_m: float,
                             hs_m: float, encounter_angle_deg: float,
                             slam_probability: float, jonswap_gamma: float,
                             tp_s: float, zone: str, scf: float) -> float {
    enc = encounter_factor(encounter_angle_deg);
    p_sig = 1025.0 * 9.81 * hs_m * enc;
    m_bending = p_sig * loa_m ** 2 * beam_m * block_coeff * 0.5;
    i_sec = i_section_m4(beam_m, depth_m, thickness_m);
    z_sec = max(1e-6, i_sec / max(0.01, depth_m * 0.5));
    sigma_nom = (m_bending / z_sec) / 1e6;
    bf = zone_bending_factor(zone);
    sf_base = zone_slam_factor(zone);
    steep = wave_steepness(hs_m, tp_s);
    steepness_boost = 1.0 + min(0.14, steep) * 2.5;
    slam_active = 1.0 + min(1.0, slam_probability) * (sf_base - 1.0);
    return sigma_nom * bf * slam_active * steepness_boost * scf;
}

def _gamma_approx(m: float) -> float {
    m2 = round(m * 2.0);
    if m2 == 6 { return 1.3293; }
    elif m2 == 8 { return 2.0000; }
    elif m2 == 10 { return 3.3234; }
    elif m2 == 12 { return 6.0000; }
    elif m2 == 20 { return 120.00; }
    elif m2 == 24 { return 720.00; }
    x = 1.0 + m / 2.0;
    return _sqrt(2.0 * _PI / x) * _pow_f(x / _E, x);
}

def segment_fatigue_damage(loa_m: float, beam_m: float, depth_m: float,
                             block_coeff: float, thickness_m: float,
                             hs_m: float, encounter_angle_deg: float,
                             slam_probability: float, jonswap_gamma: float,
                             tp_s: float, zone: str, scf: float,
                             sn_slope: float, sn_ref_stress_mpa: float,
                             sn_ref_cycles: int, duration_s: float) -> float {
    sigma_sig = significant_stress_mpa(loa_m, beam_m, depth_m, block_coeff, thickness_m,
                                        hs_m, encounter_angle_deg, slam_probability,
                                        jonswap_gamma, tp_s, zone, scf);
    if sigma_sig < sn_ref_stress_mpa * 0.40 { return 0.0; }
    tz = zero_crossing_period_s(tp_s, jonswap_gamma);
    n_peaks = duration_s / max(0.5, tz);
    m = sn_slope;
    c_sn = _pow_f(sn_ref_stress_mpa, m) * float(sn_ref_cycles);
    rayleigh = _gamma_approx(m) / _pow_f(2.0, m);
    return n_peaks * _pow_f(sigma_sig, m) * rayleigh / c_sn;
}

def stress_intensity_factor(stress_mpa: float, crack_half_length_m: float) -> float {
    return stress_mpa * 1.12 * _sqrt(_PI * crack_half_length_m);
}

def paris_crack_growth(delta_k: float, e_gpa: float) -> float {
    if delta_k <= 0.0 { return 0.0; }
    if e_gpa > 150.0 { return 6.0e-12 * _pow_f(delta_k, 3.0); }
    elif e_gpa > 50.0 { return 1.4e-11 * _pow_f(delta_k, 3.5); }
    return 5.0e-10 * _pow_f(delta_k, 4.2);
}

def is_critical_crack(crack_m: float, stress_mpa: float, k_ic: float) -> bool {
    return stress_intensity_factor(stress_mpa, crack_m) >= k_ic;
}

# ---------------------------------------------------------------------------
# Stability
# ---------------------------------------------------------------------------

def estimate_kg(depth_m: float, fuel_remaining_kg: float, fuel_capacity_kg: float) -> float {
    kg_ls = depth_m * 0.55;
    fuel_frac = fuel_remaining_kg / max(1.0, fuel_capacity_kg);
    fuel_offset = -depth_m * 0.06 * fuel_frac;
    return max(depth_m * 0.30, min(depth_m * 0.80, kg_ls + fuel_offset));
}

def metacentric_height_m(loa_m: float, beam_m: float, depth_m: float,
                          block_coeff: float, wpc: float,
                          mass_kg: float, kg_m: float) -> float {
    draft = max(0.05, draft_at_mass(loa_m, beam_m, block_coeff, mass_kg));
    v = max(0.01, mass_kg / 1025.0);
    kb = draft * (0.53 + 0.08 * block_coeff);
    i_wp = i_waterplane_m4(loa_m, beam_m, wpc);
    bm = i_wp / v;
    return kb + bm - kg_m;
}

def capsize_risk(gm_m: float, beam_m: float, hs_m: float, encounter_angle_deg: float) -> bool {
    gm_min = 0.07 * beam_m;
    if gm_m < gm_min { return True; }
    sin_val: float = _sin(encounter_angle_deg * _PI / 180.0);
    beam_component = _abs_f(sin_val);
    dyn_threshold = gm_min + 0.015 * hs_m ** 2 * beam_component;
    return gm_m < dyn_threshold;
}

# ---------------------------------------------------------------------------
# Resistance and fuel
# ---------------------------------------------------------------------------

def equilibrium_speed_ms(loa_m: float, beam_m: float, depth_m: float,
                          draft_m: float, block_coeff: float,
                          hull_drag: float, max_power_kw: float,
                          prop_eff: float, mass_kg: float,
                          hs_m: float, tp_s: float,
                          encounter_angle_deg: float, wind_ms: float) -> float {
    p_shaft = max_power_kw * 1000.0 * prop_eff;
    real_draft = draft_at_mass(loa_m, beam_m, block_coeff, mass_kg);
    wetted = wetted_area_m2(loa_m, beam_m, real_draft, block_coeff);
    k = 0.5 * 1025.0 * hull_drag * wetted;
    v: float = _pow_f(p_shaft / max(1.0, k), 1.0 / 3.0);
    for _ in range(12) {
        r_calm = 0.5 * 1025.0 * hull_drag * wetted * v ** 2;
        lambda_p = 9.81 * tp_s ** 2 / (2.0 * _PI);
        enc = encounter_factor(encounter_angle_deg);
        r_wave = 1025.0 * 9.81 * hs_m ** 2 * beam_m ** 2 / (16.0 * max(0.5, lambda_p)) * enc;
        above_water = beam_m * (depth_m - draft_m);
        r_wind = 0.5 * 1.225 * 0.75 * above_water * wind_ms ** 2;
        r_total = r_calm + r_wave + r_wind;
        thrust = p_shaft / max(0.01, v);
        residual = thrust - r_total;
        dr_dv = 2.0 * r_calm / max(0.01, v);
        jacobian = -(p_shaft / max(1e-4, v ** 2)) - dr_dv;
        delta = residual / max(1.0, _abs_f(jacobian));
        v = max(0.5, min(30.0, v - delta));
        if _abs_f(residual) < 10.0 { break; }
    }
    return max(0.5, v);
}

def fuel_burned_kg(loa_m: float, beam_m: float, depth_m: float,
                    draft_m: float, block_coeff: float,
                    hull_drag: float, max_power_kw: float,
                    prop_eff: float, sfc_g_per_kwh: float,
                    mass_kg: float, distance_nm: float,
                    hs_m: float, tp_s: float,
                    encounter_angle_deg: float, wind_ms: float) -> float {
    speed_ms = equilibrium_speed_ms(loa_m, beam_m, depth_m, draft_m, block_coeff,
                                     hull_drag, max_power_kw, prop_eff, mass_kg,
                                     hs_m, tp_s, encounter_angle_deg, wind_ms);
    speed_kts = speed_ms * 1.944;
    if speed_kts <= 0.0 { return 1e9; }
    duration_h = distance_nm / speed_kts;
    p_shaft = max_power_kw * 1000.0 * prop_eff;
    real_draft = draft_at_mass(loa_m, beam_m, block_coeff, mass_kg);
    wetted = wetted_area_m2(loa_m, beam_m, real_draft, block_coeff);
    r_calm = 0.5 * 1025.0 * hull_drag * wetted * speed_ms ** 2;
    lambda_p = 9.81 * tp_s ** 2 / (2.0 * _PI);
    enc = encounter_factor(encounter_angle_deg);
    r_wave = 1025.0 * 9.81 * hs_m ** 2 * beam_m ** 2 / (16.0 * max(0.5, lambda_p)) * enc;
    above_water = beam_m * (depth_m - draft_m);
    r_wind = 0.5 * 1.225 * 0.75 * above_water * wind_ms ** 2;
    r_total = r_calm + r_wave + r_wind;
    power_fraction = max(0.0, min(1.0, r_total * speed_ms / max(1.0, p_shaft)));
    fuel_rate_kg_h = (max_power_kw * power_fraction) * (sfc_g_per_kwh / 1000.0);
    return fuel_rate_kg_h * duration_h;
}

# ---------------------------------------------------------------------------
# Ice accretion
# ---------------------------------------------------------------------------

def spray_icing_rate_kg_per_h(loa_m: float, beam_m: float,
                                water_temp_c: float, wind_ms: float, hs_m: float) -> float {
    if water_temp_c >= 4.0 { return 0.0; }
    cold_factor = max(0.0, 4.0 - water_temp_c) / 4.0;
    wind_factor = min(4.0, _pow_f(wind_ms / 12.0, 2.0));
    wave_factor = min(3.0, max(0.0, hs_m / 2.0));
    topside_area = beam_m * loa_m * 0.30;
    return 0.70 * cold_factor * wind_factor * wave_factor * topside_area;
}

def gm_with_ice(base_gm_m: float, depth_m: float, vessel_mass_kg: float,
                 vessel_kg_m: float, ice_mass_kg: float) -> float {
    if ice_mass_kg <= 0.0 { return base_gm_m; }
    kg_ice = depth_m * 1.05;
    total_mass = vessel_mass_kg + ice_mass_kg;
    kg_combined = (vessel_mass_kg * vessel_kg_m + ice_mass_kg * kg_ice) / total_mass;
    return base_gm_m - (kg_combined - vessel_kg_m);
}

# ---------------------------------------------------------------------------
# Cost
# ---------------------------------------------------------------------------

def config_cost_usd(loa_m: float, beam_m: float, depth_m: float,
                     density_kg_m3: float, thickness_m: float,
                     cost_per_kg_usd: float, weld: str, seal: str,
                     fuel_capacity_kg: float) -> float {
    shell_area = 2.0 * (loa_m * depth_m + loa_m * beam_m + beam_m * depth_m);
    shell_mass = shell_area * thickness_m * density_kg_m3;
    mat_cost = shell_mass * cost_per_kg_usd;
    weld_cost = mat_cost * 0.15 * weld_cost_factor(weld);
    seal_cost = loa_m * 120.0 * seal_cost_factor(seal);
    fuel_cost = fuel_capacity_kg * 0.65;
    return mat_cost + weld_cost + seal_cost + fuel_cost;
}
