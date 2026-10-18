import pytest
from pydantic import ValidationError

from app.schemas.profile import NgoProfileCreate, NgoProfileUpdate


def _valid_ngo_profile() -> dict:
    return {
        "organization_name": "Community Kitchen",
        "address": "12 Example Road",
        "city": "Pune",
        "latitude": 18.52,
        "longitude": 73.85,
        "food_capacity": 200,
        "max_capacity_kg": 25,
        "preferred_food_types": ["Cooked Meals"],
        "dietary_preferences": ["vegetarian"],
        "available_from": "07:00",
        "available_to": "22:00",
    }


def test_ngo_create_allows_matching_details_to_be_configured_later() -> None:
    NgoProfileCreate.model_validate(
        {
            "organization_name": "New Community Kitchen",
            "address": "12 Example Road",
        }
    )
    NgoProfileCreate.model_validate(_valid_ngo_profile())


@pytest.mark.parametrize(
    ("fields", "message"),
    [
        ({"latitude": 18.52}, "latitude and longitude"),
        ({"available_from": "07:00"}, "available_from and available_to"),
    ],
)
def test_ngo_create_rejects_partial_matching_pairs(fields, message) -> None:
    with pytest.raises(ValidationError, match=message):
        NgoProfileCreate.model_validate(
            {"organization_name": "Community Kitchen", "address": "12 Road", **fields}
        )


@pytest.mark.parametrize(
    ("field", "value"),
    [
        ("latitude", 91),
        ("longitude", 181),
        ("max_capacity_kg", 0),
        ("preferred_food_types", []),
        ("available_from", "24:00"),
        ("available_to", "08:60"),
    ],
)
def test_ngo_create_rejects_invalid_matching_values(field: str, value) -> None:
    payload = _valid_ngo_profile()
    payload[field] = value

    with pytest.raises(ValidationError):
        NgoProfileCreate.model_validate(payload)


def test_ngo_create_rejects_zero_length_operating_window() -> None:
    payload = _valid_ngo_profile()
    payload["available_to"] = payload["available_from"]

    with pytest.raises(ValidationError, match="must be different"):
        NgoProfileCreate.model_validate(payload)


def test_ngo_update_requires_coordinate_and_hour_pairs() -> None:
    with pytest.raises(ValidationError, match="latitude and longitude"):
        NgoProfileUpdate.model_validate({"latitude": 18.52})
    with pytest.raises(ValidationError, match="available_from and available_to"):
        NgoProfileUpdate.model_validate({"available_from": "07:00"})


def test_ngo_update_allows_unrelated_fields_and_valid_matching_data() -> None:
    NgoProfileUpdate.model_validate({"description": "Community kitchen"})
    NgoProfileUpdate.model_validate(
        {
            "latitude": 18.52,
            "longitude": 73.85,
            "available_from": "07:00",
            "available_to": "22:00",
            "max_capacity_kg": 25,
        }
    )
