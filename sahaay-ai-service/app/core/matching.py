"""
Weighted-scoring NGO matching engine.

For a given donation and a list of candidate NGOs, calculates a score
(0-100) for each NGO based on 5 factors, then ranks NGOs from best to
worst match. Weights are defined in app/config.py so they're easy to
tune without touching this logic.

Distance can come from two sources:
  - "road"          : real road distance via a routing API (OSRM)
  - "straight_line"  : haversine (great-circle) distance, used as a
                        fallback whenever the routing API is disabled,
                        unreachable, or too slow
"""

import math
from datetime import datetime
from typing import List, Tuple

import requests

from app.config import (
    MATCHING_WEIGHTS,
    MAX_MATCHING_DISTANCE_KM,
    OSRM_BASE_URL,
    ROAD_DISTANCE_TIMEOUT_SECONDS,
    USE_ROAD_DISTANCE,
)
from app.models.schemas import DonationInput, MatchResponse, NGOInput, NGOScoreBreakdown


def haversine_distance_km(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    """Great-circle (straight-line) distance between two lat/lon points, in km."""
    R = 6371.0  # Earth radius in km
    phi1, phi2 = math.radians(lat1), math.radians(lat2)
    d_phi = math.radians(lat2 - lat1)
    d_lambda = math.radians(lon2 - lon1)

    a = (
        math.sin(d_phi / 2) ** 2
        + math.cos(phi1) * math.cos(phi2) * math.sin(d_lambda / 2) ** 2
    )
    c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))
    return R * c


def get_road_distance_km(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    """
    Calls a routing API (OSRM) to get real road driving distance in km.
    Raises an exception on any failure (timeout, no internet, bad
    response) — the caller (get_distance_km) is responsible for
    catching this and falling back to haversine.
    """
    # OSRM expects coordinates as "longitude,latitude"
    url = f"{OSRM_BASE_URL}/route/v1/driving/{lon1},{lat1};{lon2},{lat2}"
    params = {"overview": "false"}

    response = requests.get(url, params=params, timeout=ROAD_DISTANCE_TIMEOUT_SECONDS)
    response.raise_for_status()
    data = response.json()

    if data.get("code") != "Ok" or not data.get("routes"):
        raise ValueError(f"OSRM returned no route: {data.get('code')}")

    distance_meters = data["routes"][0]["distance"]
    return round(distance_meters / 1000.0, 2)


def get_distance_km(lat1: float, lon1: float, lat2: float, lon2: float) -> Tuple[float, str]:
    """
    Returns (distance_km, source) where source is "road" or "straight_line".
    Tries real road distance first (if enabled); falls back to haversine
    on any failure so matching never breaks due to a network issue.
    """
    if USE_ROAD_DISTANCE:
        try:
            distance_km = get_road_distance_km(lat1, lon1, lat2, lon2)
            return distance_km, "road"
        except Exception:  # noqa: BLE001 — any routing failure falls back silently
            pass

    return round(haversine_distance_km(lat1, lon1, lat2, lon2), 2), "straight_line"


def _distance_score(distance_km: float) -> float:
    """Closer = higher score. Linear falloff to 0 at MAX_MATCHING_DISTANCE_KM."""
    if distance_km >= MAX_MATCHING_DISTANCE_KM:
        return 0.0
    return round((1 - distance_km / MAX_MATCHING_DISTANCE_KM) * 100, 2)


def _quantity_fit_score(donation_qty: float, ngo_min: float, ngo_max: float) -> float:
    """
    100 if the donation quantity fits comfortably within the NGO's
    capacity range. Score drops off if the donation is too small for
    the NGO to bother with, or too large for them to handle.
    """
    if donation_qty > ngo_max:
        # NGO cannot take it all — score based on how much they CAN take
        return round(max(0.0, (ngo_max / donation_qty)) * 100, 2)
    if donation_qty < ngo_min:
        # Below NGO's practical minimum — still possible but not ideal
        return round(max(0.0, (donation_qty / ngo_min)) * 70, 2) if ngo_min > 0 else 100.0
    # Within range — score higher the closer it is to using their capacity well,
    # without being wasteful either way.
    utilization = donation_qty / ngo_max
    return round(min(100.0, 60 + utilization * 40), 2)


def _dietary_compatibility_score(donation_type: str, ngo_accepted_types: List[str]) -> float:
    if donation_type in ngo_accepted_types or "any" in ngo_accepted_types:
        return 100.0
    return 0.0


def _pickup_time_feasibility_score(pickup_time: str, ngo_from: str, ngo_to: str) -> float:
    """100 if pickup_time falls within the NGO's availability window, else 0."""
    try:
        pickup = datetime.strptime(pickup_time, "%H:%M").time()
        window_start = datetime.strptime(ngo_from, "%H:%M").time()
        window_end = datetime.strptime(ngo_to, "%H:%M").time()
    except ValueError:
        return 0.0

    if window_start <= window_end:
        feasible = window_start <= pickup <= window_end
    else:
        # window crosses midnight, e.g. 22:00 - 04:00
        feasible = pickup >= window_start or pickup <= window_end
    return 100.0 if feasible else 0.0


def score_and_rank_ngos(donation: DonationInput, candidate_ngos: List[NGOInput]) -> MatchResponse:
    scored: List[NGOScoreBreakdown] = []

    for ngo in candidate_ngos:
        distance_km, distance_source = get_distance_km(
            donation.restaurant_latitude,
            donation.restaurant_longitude,
            ngo.latitude,
            ngo.longitude,
        )
        distance_score = _distance_score(distance_km)
        quantity_score = _quantity_fit_score(donation.quantity_kg, ngo.min_capacity_kg, ngo.max_capacity_kg)
        dietary_score = _dietary_compatibility_score(
            donation.dietary_type.value, [d.value for d in ngo.dietary_accepted]
        )
        time_score = _pickup_time_feasibility_score(
            donation.pickup_time, ngo.available_from, ngo.available_to
        )
        reliability_score = donation.restaurant_reliability_score

        final_score = (
            distance_score * MATCHING_WEIGHTS["distance"]
            + quantity_score * MATCHING_WEIGHTS["quantity_fit"]
            + dietary_score * MATCHING_WEIGHTS["dietary_compatibility"]
            + time_score * MATCHING_WEIGHTS["pickup_time_feasibility"]
            + reliability_score * MATCHING_WEIGHTS["restaurant_reliability"]
        )

        scored.append(
            NGOScoreBreakdown(
                ngo_id=ngo.ngo_id,
                ngo_name=ngo.name,
                distance_km=distance_km,
                distance_source=distance_source,
                distance_score=distance_score,
                quantity_fit_score=quantity_score,
                dietary_compatibility_score=dietary_score,
                pickup_time_feasibility_score=time_score,
                restaurant_reliability_score=reliability_score,
                final_score=round(final_score, 2),
                rank=0,  # filled in after sorting
            )
        )

    scored.sort(key=lambda s: s.final_score, reverse=True)
    for idx, item in enumerate(scored, start=1):
        item.rank = idx

    return MatchResponse(
        donation_id=donation.donation_id,
        ranked_ngos=scored,
        weights_used=MATCHING_WEIGHTS,
    )
