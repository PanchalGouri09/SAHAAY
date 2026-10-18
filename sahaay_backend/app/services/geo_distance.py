"""Validated coordinate helpers for honest matching-distance fallbacks."""

from __future__ import annotations

from math import asin, cos, isfinite, radians, sin, sqrt


def coordinates(row: dict | None) -> tuple[float, float] | None:
    if not isinstance(row, dict):
        return None
    try:
        latitude = float(row["latitude"])
        longitude = float(row["longitude"])
    except (KeyError, TypeError, ValueError, OverflowError):
        return None
    if (
        not isfinite(latitude)
        or not isfinite(longitude)
        or not -90 <= latitude <= 90
        or not -180 <= longitude <= 180
    ):
        return None
    return latitude, longitude


def distance_with_fallback(
    score_details: dict,
    pickup_row: dict | None,
    destination_row: dict | None,
) -> dict:
    """Keep a saved route distance; calculate straight-line only if it is absent."""
    details = dict(score_details)
    current = details.get("distance_km")
    if (
        isinstance(current, (int, float))
        and isfinite(current)
        and current >= 0
    ):
        return details

    pickup = coordinates(pickup_row)
    destination = coordinates(destination_row)
    if pickup is None or destination is None:
        return details

    lat1, lon1 = map(radians, pickup)
    lat2, lon2 = map(radians, destination)
    delta_lat = lat2 - lat1
    delta_lon = lon2 - lon1
    haversine = (
        sin(delta_lat / 2) ** 2
        + cos(lat1) * cos(lat2) * sin(delta_lon / 2) ** 2
    )
    details["distance_km"] = round(
        6371.0 * 2 * asin(sqrt(min(1.0, haversine))), 2
    )
    details["distance_source"] = "straight_line"
    return details
