from app.services.geo_distance import distance_with_fallback


def test_distance_fallback_uses_real_coordinate_pairs_and_marks_source():
    details = distance_with_fallback(
        {},
        {"latitude": 18.52, "longitude": 73.85},
        {"latitude": 18.53, "longitude": 73.86},
    )

    assert details["distance_km"] > 0
    assert details["distance_source"] == "straight_line"


def test_distance_fallback_does_not_invent_distance_when_coordinates_are_missing():
    details = distance_with_fallback(
        {},
        {"latitude": 18.52, "longitude": None},
        {"latitude": 18.53, "longitude": 73.86},
    )

    assert "distance_km" not in details
    assert "distance_source" not in details


def test_distance_fallback_preserves_a_saved_route_distance():
    details = distance_with_fallback(
        {"distance_km": 2.4, "distance_source": "road"},
        {"latitude": 18.52, "longitude": 73.85},
        {"latitude": 18.53, "longitude": 73.86},
    )

    assert details["distance_km"] == 2.4
    assert details["distance_source"] == "road"
