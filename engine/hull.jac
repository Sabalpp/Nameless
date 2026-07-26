"""Hull geometry helpers — port of src/vessel/hull.rs (HullGeometry methods)."""

import from engine.types { HullGeometry }

"Displaced volume at design draft [m³]."
def displacement_m3(hull: HullGeometry) -> float {
    return hull.loa_m * hull.beam_m * hull.draft_m * hull.block_coeff;
}

"Displaced mass in seawater at design draft [kg]."
def design_displacement_kg(hull: HullGeometry) -> float {
    return displacement_m3(hull) * 1025.0;
}

"Waterplane area [m²]."
def waterplane_area_m2(hull: HullGeometry) -> float {
    return hull.loa_m * hull.beam_m * hull.waterplane_coeff;
}

"Second moment of waterplane area about centreline [m⁴]."
def i_waterplane_m4(hull: HullGeometry) -> float {
    return hull.loa_m * (hull.beam_m ** 3) * hull.waterplane_coeff / 12.0;
}

"""Hull section second moment of area about neutral axis [m⁴].
Uses hollow rectangular box with uniform plating thickness t [m].
"""
def i_section_m4(hull: HullGeometry, plate_thickness_m: float) -> float {
    b = hull.beam_m;
    d = hull.depth_m;
    t = max(plate_thickness_m, 0.001);
    b_inner = max(b - 2.0 * t, 0.0);
    d_inner = max(d - 2.0 * t, 0.0);
    return (b * (d ** 3) - b_inner * (d_inner ** 3)) / 12.0;
}

"Draft at an arbitrary displacement [kg], keeping same Cb and Cw."
def draft_at_mass(hull: HullGeometry, mass_kg: float) -> float {
    return mass_kg / (1025.0 * hull.loa_m * hull.beam_m * hull.block_coeff);
}

"Wetted surface area approximation [m²] (Mumford formula)."
def wetted_area_m2(hull: HullGeometry, draft_m: float) -> float {
    return hull.loa_m * (1.7 * draft_m + hull.beam_m * hull.block_coeff);
}

"Representative ocean-going ASV at ~7m LOA (Rust Default for HullGeometry)."
def default_hull_geometry() -> HullGeometry {
    return HullGeometry(
        loa_m=7.3,
        beam_m=2.4,
        depth_m=1.1,
        draft_m=0.32,
        block_coeff=0.58,
        waterplane_coeff=0.78
    );
}
