from pathlib import Path

import pytest
from pydantic import ValidationError

from app.schemas.donation import TransportCoordinationResponse


@pytest.mark.parametrize(
    ("phone", "normalized"),
    [
        ("9876543210", "9876543210"),
        (" 9876543210 ", "9876543210"),
        ("+91 9876543210", "9876543210"),
    ],
)
def test_yes_response_requires_and_normalizes_captain_contact(phone, normalized):
    response = TransportCoordinationResponse(
        response="yes",
        captain_name="  Pickup Captain  ",
        captain_phone=phone,
    )

    assert response.captain_name == "Pickup Captain"
    assert response.captain_phone == normalized


@pytest.mark.parametrize(
    "phone",
    ["", "1234567890", "987654321", "98765432101", "98765abc10"],
)
def test_yes_response_rejects_invalid_indian_mobile_number(phone):
    with pytest.raises(ValidationError):
        TransportCoordinationResponse(
            response="yes",
            captain_name="Pickup Captain",
            captain_phone=phone,
        )


def test_no_response_does_not_require_captain_details():
    response = TransportCoordinationResponse(response="no")

    assert response.captain_name is None
    assert response.captain_phone is None


def test_transport_migration_serializes_winner_and_volunteer_assignment():
    migration_path = (
        Path(__file__).parents[1]
        / "supabase"
        / "migrations"
        / "20261018000000_add_transport_coordination.sql"
    )
    migration = migration_path.read_text(encoding="utf-8").lower()
    response_function = migration.split(
        "create or replace function public.respond_to_claim_transport", 1
    )[1].split("create or replace function public.confirm_claim_volunteer_assignment", 1)[0]
    volunteer_function = migration.split(
        "create or replace function public.confirm_claim_volunteer_assignment", 1
    )[1].split("create or replace function public.verify_donation_handover", 1)[0]

    assert "for update" in response_function
    assert "responsible_role = case" in response_function
    assert "when p_response = 'yes' then 'provider'" in response_function
    assert "when p_response = 'yes' then 'ngo'" in response_function
    assert "v_coord.provider_response = 'no' and v_coord.ngo_response = 'no'" in response_function
    assert "status = 'searching_for_volunteers'" in response_function
    assert "status <> 'searching_for_volunteers'" in volunteer_function
    assert "volunteer_id is null" in volunteer_function
    assert "from public, anon, authenticated" in migration
    assert "to service_role" in migration


def test_handover_migration_keeps_completion_state_atomic_with_coordination():
    migration_path = (
        Path(__file__).parents[1]
        / "supabase"
        / "migrations"
        / "20261018000000_add_transport_coordination.sql"
    )
    migration = migration_path.read_text(encoding="utf-8").lower()
    verify_function = migration.split(
        "create or replace function public.verify_donation_handover", 1
    )[1]

    assert "v_claim.handover_code_expires_at <= v_now" in verify_function
    assert "v_claim.handover_code_hash <> p_candidate_hash" in verify_function
    assert "set status = 'completed'" in verify_function
    assert "update public.claim_transport_coordination" in verify_function
