"""Route geometry helpers — port of src/environment/route.rs (+ haversine from main.rs)."""

import from math { atan2, cos, radians, sin, sqrt }

import from engine.types { GeoPoint, VoyageRoute }

"Great-circle distance between two WGS-84 points [nautical miles]."
def haversine_nm(from_pt: GeoPoint, to_pt: GeoPoint) -> float {
    r_nm = 3440.065;  # Earth mean radius in nautical miles
    lat1 = radians(from_pt.lat_deg);
    lat2 = radians(to_pt.lat_deg);
    dlat = radians(to_pt.lat_deg - from_pt.lat_deg);
    dlon = radians(to_pt.lon_deg - from_pt.lon_deg);
    a = (sin(dlat / 2.0) ** 2) + cos(lat1) * cos(lat2) * (sin(dlon / 2.0) ** 2);
    c = 2.0 * atan2(sqrt(a), sqrt(1.0 - a));
    return r_nm * c;
}

"Sum of segment great-circle distances [nm]."
def total_distance_nm(route: VoyageRoute) -> float {
    total = 0.0;
    for s in route.segments {
        total += s.distance_nm;
    }
    return total;
}
