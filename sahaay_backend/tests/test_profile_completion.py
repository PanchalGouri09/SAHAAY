from __future__ import annotations

from types import SimpleNamespace

import pytest
from fastapi import BackgroundTasks, HTTPException
from fastapi.testclient import TestClient

from app.dependencies import get_current_firebase_user, get_current_profile
from app.main import app
from app.routers import claims, donation_offers, donations, profile as profile_router
from app.routers.donation_offers import OfferResponse
from app.schemas.donation import ClaimCreate, DonationCreate
from app.schemas.profile import (
    NgoProfileCreate,
    NgoProfileUpdate,
    ProfileCreate,
    ProfileUpdate,
    ProviderProfileCreate,
    ProviderProfileUpdate,
)
from app.services.ai_client import AIClient
from app.services.profile_completion import (
    contact_verification_state,
    ngo_profile_is_complete,
    profile_completion_report,
    require_complete_profile,
    require_verified_contacts,
)


def _provider(**overrides) -> dict:
    row = {
        "id": "provider-1",
        "organization_name": "Community Kitchen",
        "address": "1 Market Street",
        "city": "Pune",
        "latitude": 18.52,
        "longitude": 73.85,
    }
    row.update(overrides.pop("provider", {}))
    return {
        "role": "provider",
        "full_name": "Provider Contact",
        "email": "provider@example.org",
        "phone": "+91 9876543210",
        "providers": [row],
        **overrides,
    }


def _ngo(*, verified=True, **overrides) -> dict:
    row = {
        "id": "ngo-1",
        "organization_name": "Community Pantry",
        "address": "2 Market Street",
        "city": "Pune",
        "latitude": 18.53,
        "longitude": 73.86,
        "available_from": "07:00",
        "available_to": "22:00",
        "max_capacity_kg": 25.0,
        "preferred_food_types": ["Cooked Meals"],
        "dietary_preferences": ["vegetarian"],
        "verified": verified,
    }
    row.update(overrides.pop("ngo", {}))
    return {
        "id": "user-ngo-1",
        "role": "ngo",
        "full_name": "NGO Contact",
        "email": "ngo@example.org",
        "phone": "+91 9876543210",
        "ngos": [row],
        **overrides,
    }


def _verified_firebase_user(email="ngo@example.org") -> dict:
    return {
        "email": email,
        "email_verified": True,
        "phone_number": "+919876543210",
        "firebase": {"identities": {"phone": ["+919876543210"]}},
    }


def test_profile_completion_does_not_depend_on_legacy_verification():
    report = profile_completion_report(_ngo(verified=False))

    assert report["complete"] is True
    assert report["percentage"] == 100
    assert report["missing_fields"] == []
    assert "verified" not in report
    assert "matching_reason" not in report
    assert ngo_profile_is_complete(_ngo(), _ngo(verified=False)["ngos"][0])


def test_ngo_null_and_malformed_fields_are_listed_as_missing():
    report = profile_completion_report(
        _ngo(
            verified=True,
            ngo={
                "latitude": None,
                "available_to": "25:90",
                "max_capacity_kg": 0,
                "preferred_food_types": [],
                "dietary_preferences": None,
            },
        )
    )

    assert report["complete"] is False
    assert report["percentage"] < 100
    assert set(report["missing_fields"]) == {
        "Location coordinates",
        "Operating hours",
        "Maximum donation capacity (kg)",
        "Preferred food types",
        "Dietary preferences",
    }


def test_provider_completion_includes_real_pickup_location():
    report = profile_completion_report(_provider(provider={"latitude": None}))

    assert report["complete"] is False
    assert report["missing_fields"] == ["Pickup location coordinates"]

    completed = profile_completion_report(_provider())
    assert completed["complete"] is True
    assert completed["completed_fields"] == completed["total_fields"]


def test_profile_completion_changes_after_missing_field_is_saved():
    profile = _ngo(verified=True, ngo={"dietary_preferences": []})
    assert profile_completion_report(profile)["complete"] is False

    profile["ngos"][0]["dietary_preferences"] = ["vegetarian"]
    report = profile_completion_report(profile)
    assert report["complete"] is True
    require_complete_profile(profile, action="accepting a donation")


def test_profile_update_recomputes_completion_from_saved_role_row(monkeypatch):
    user = _ngo(verified=True, ngo={"dietary_preferences": None})
    role_row = user["ngos"][0]

    class _Table:
        def __init__(self, name):
            self.name = name

        def update(self, values):
            if self.name == "ngos":
                role_row.update(values)
            return self

        def select(self, *_args):
            return self

        def eq(self, *_args):
            return self

        def single(self):
            return self

        def execute(self):
            return SimpleNamespace(data={**user, "ngos": [dict(role_row)]})

    class _Client:
        def table(self, name):
            return _Table(name)

    monkeypatch.setattr(profile_router, "get_supabase_client", lambda: _Client())
    response = profile_router.update_profile(
        ProfileUpdate.model_validate({"ngo": {"dietary_preferences": ["vegetarian"]}}),
        BackgroundTasks(),
        user,
        None,
    )

    assert response["profile_completion"]["complete"] is True
    assert response["profile_completion"]["percentage"] == 100
    assert "verified" not in response["profile_completion"]


def test_complete_eligible_ngo_profile_save_schedules_matching_refresh(monkeypatch):
    profile = _ngo(verified=True)
    ngo = profile["ngos"][0]

    class _Table:
        def __init__(self, name):
            self.name = name
            self.values = {}

        def update(self, values):
            self.values = dict(values)
            return self

        def select(self, *_args):
            return self

        def eq(self, *_args):
            return self

        def single(self):
            return self

        def execute(self):
            if self.name == "ngos":
                ngo.update(self.values)
            return SimpleNamespace(data={**profile, "ngos": [dict(ngo)]})

    class _Client:
        def table(self, name):
            return _Table(name)

    monkeypatch.setattr(profile_router, "get_supabase_client", lambda: _Client())
    tasks = BackgroundTasks()

    response = profile_router.update_profile(
        ProfileUpdate.model_validate({"ngo": {"dietary_preferences": ["vegetarian"]}}),
        tasks,
        profile,
        _verified_firebase_user(),
    )

    assert response["profile_completion"]["complete"] is True
    assert len(tasks.tasks) == 1
    assert tasks.tasks[0].func is profile_router._refresh_open_donation_matches


@pytest.mark.parametrize(
    ("value", "expected"),
    [
        ("9876543210", "9876543210"),
        ("+91 (98765) 43210", "9876543210"),
        ("0091-98765-43210", "9876543210"),
        ("91 98765 43210", "9876543210"),
    ],
)
def test_profile_creation_phone_fields_normalize_indian_mobile_numbers(value, expected):
    create = ProfileCreate(
        full_name="Volunteer",
        email="volunteer@example.org",
        phone=value,
        role="volunteer",
    )
    provider = ProviderProfileCreate(
        organization_name="Kitchen",
        organization_type="restaurant",
        address="1 Market Road",
        phone=value,
    )
    ngo = NgoProfileCreate(
        organization_name="Pantry",
        address="2 Market Road",
        phone=value,
    )
    assert create.phone == expected
    assert provider.phone == expected
    assert ngo.phone == expected


@pytest.mark.parametrize(
    "value",
    [
        "987654321",
        "98765432101",
        "5123456789",
        "98765abc10",
        "+44 9876543210",
    ],
)
def test_profile_creation_rejects_invalid_indian_mobile_numbers(value):
    with pytest.raises(ValueError):
        ProfileCreate(
            full_name="Volunteer",
            email="volunteer@example.org",
            phone=value,
            role="volunteer",
        )
    with pytest.raises(ValueError):
        ProviderProfileCreate(
            organization_name="Kitchen",
            organization_type="restaurant",
            address="1 Market Road",
            phone=value,
        )
    with pytest.raises(ValueError):
        NgoProfileCreate(
            organization_name="Pantry",
            address="2 Market Road",
            phone=value,
        )


def test_profile_updates_do_not_require_registration_phone_format():
    raw_phone = "not-verified-or-normalized"

    assert ProfileUpdate(phone=raw_phone).phone == raw_phone
    assert ProviderProfileUpdate(phone=raw_phone).phone == raw_phone
    assert NgoProfileUpdate(phone=raw_phone).phone == raw_phone


def test_contact_phone_verification_requires_trusted_number_to_match_saved_number(
    monkeypatch,
):
    monkeypatch.setattr(
        "app.config.get_settings",
        lambda: type("Settings", (), {"firebase_phone_auth_enabled": True})(),
    )
    profile = _provider(phone="9876543210")
    matching_claim = {
        "phone_number": "+91 98765 43210",
        "firebase": {"identities": {"phone": ["+919876543210"]}},
    }
    assert contact_verification_state(profile, matching_claim)["phone_verified"]

    mismatched_claim = {**matching_claim, "phone_number": "+919876543211"}
    assert not contact_verification_state(profile, mismatched_claim)["phone_verified"]
    # A valid number string saved by the client is not itself proof of ownership.
    assert not contact_verification_state(profile, {"phone_number": None})[
        "phone_verified"
    ]


def test_profile_phone_change_notifies_only_for_a_real_normalized_change(
    monkeypatch,
):
    profile = _provider(id="user-1", phone="+91 98765 43210")
    notifications = []

    class _Table:
        def __init__(self, name):
            self.name = name
            self.values = None
            self.mode = None

        def update(self, values):
            self.values = values
            self.mode = "update"
            return self

        def select(self, *_args):
            self.mode = "select"
            return self

        def eq(self, *_args):
            return self

        def single(self):
            return self

        def execute(self):
            if self.mode == "update":
                profile.update(self.values)
                return SimpleNamespace(data=profile)
            return SimpleNamespace(data=dict(profile))

    class _Client:
        def table(self, name):
            return _Table(name)

    monkeypatch.setattr(profile_router, "get_supabase_client", lambda: _Client())
    monkeypatch.setattr(
        profile_router.notification_service,
        "contact_phone_updated",
        lambda _client, **kwargs: notifications.append(kwargs),
    )

    profile_router.update_profile(
        ProfileUpdate(phone="9876543211"),
        BackgroundTasks(),
        profile,
        {"uid": "firebase-user"},
    )
    assert len(notifications) == 1
    assert notifications[0]["previous_phone"] == "+91 98765 43210"
    assert profile["phone"] == "9876543211"

    profile_router.update_profile(
        ProfileUpdate(phone="+91 (98765) 43211"),
        BackgroundTasks(),
        profile,
        {"uid": "firebase-user"},
    )
    assert len(notifications) == 1


def test_backend_donation_create_rejects_incomplete_provider_before_ai_or_db(
    monkeypatch,
):
    payload = DonationCreate(
        food_name="Rice",
        food_category="Cooked Meals",
        veg_type="vegetarian",
        quantity=5,
        unit="kg",
        food_image_url="https://example.org/food.png",
        prepared_at="2026-10-16T08:00:00Z",
        expiry_time="2026-10-16T14:00:00Z",
        pickup_deadline="2026-10-16T12:00:00Z",
        pickup_address="1 Market Street",
        storage_condition="refrigerated",
    )
    monkeypatch.setattr(
        donations,
        "_verify_safety",
        lambda *_args: pytest.fail("profile gate must run before the AI request"),
    )
    with pytest.raises(HTTPException) as error:
        donations.create_donation(
            payload,
            _provider(provider={"latitude": None}),
            AIClient(base_url="http://unused"),
        )

    assert error.value.status_code == 409
    assert "Pickup location coordinates" in error.value.detail


def test_backend_offer_acceptance_requires_profile_completion_not_legacy_flag(
    monkeypatch,
):
    monkeypatch.setattr(
        donation_offers,
        "get_supabase_client",
        lambda: pytest.fail("must reject before database offer mutation"),
    )
    payload = OfferResponse(decision="accepted")
    with pytest.raises(HTTPException) as incomplete:
        donation_offers.respond(
            "offer-1",
            payload,
            _ngo(ngo={"max_capacity_kg": None}),
        )
    assert incomplete.value.status_code == 409
    assert "Maximum donation capacity (kg)" in incomplete.value.detail

    monkeypatch.setattr(donation_offers, "get_supabase_client", lambda: object())
    monkeypatch.setattr(
        donation_offers,
        "respond_to_offer",
        lambda *_args, **_kwargs: {"status": "accepted"},
    )
    response = donation_offers.respond("offer-1", payload, _ngo(verified=False))
    assert response["status"] == "accepted"


def test_backend_claim_path_rejects_incomplete_ngo():
    payload = ClaimCreate(
        donation_id="11111111-1111-1111-1111-111111111111",
        requested_quantity=1,
    )
    with pytest.raises(HTTPException) as error:
        claims.create_claim(payload, _ngo(ngo={"available_from": None}))
    assert error.value.status_code == 409
    assert "Operating hours" in error.value.detail


def test_contact_verification_uses_only_signed_firebase_claims(monkeypatch):
    monkeypatch.setattr(
        "app.config.get_settings",
        lambda: type("Settings", (), {"firebase_phone_auth_enabled": False})(),
    )
    profile = _provider()
    valid = {
        "email": profile["email"],
        "email_verified": True,
        "phone_number": "+919876543210",
        "firebase": {"identities": {"phone": ["+919876543210"]}},
    }
    state = contact_verification_state(profile, valid)
    assert state == {
        "email_verified": True,
        "phone_verified": True,
        "phone_auth_configured": False,
    }
    require_verified_contacts(profile, valid, action="accepting a volunteer task")

    untrusted = {
        **valid,
        "phone_number": None,
    }
    assert contact_verification_state(profile, untrusted)["phone_verified"] is False
    with pytest.raises(HTTPException) as error:
        require_verified_contacts(profile, untrusted, action="creating a donation")
    assert error.value.status_code == 403
    assert "phone verified" in error.value.detail
    assert "phone verification enabled" not in error.value.detail


def test_claim_api_accepts_authenticated_complete_ngo_without_phone_auth(
    monkeypatch,
):
    class _ClaimQuery:
        def __init__(self, table):
            self.table_name = table
            self.inserted = None

        def insert(self, values):
            self.inserted = dict(values)
            return self

        def select(self, *_args):
            return self

        def eq(self, *_args):
            return self

        def maybe_single(self):
            return self

        def execute(self):
            if self.table_name == "claims":
                return type(
                    "Response",
                    (),
                    {
                        "data": [
                            {
                                "id": "claim-1",
                                **self.inserted,
                            }
                        ]
                    },
                )()
            return type("Response", (), {"data": None})()

    class _ClaimClient:
        def table(self, table_name):
            return _ClaimQuery(table_name)

    profile = _ngo(verified=False)
    monkeypatch.setattr(claims, "get_supabase_client", _ClaimClient)
    monkeypatch.setattr(
        claims, "recompute_volunteer_transport_required", lambda *_args: None
    )
    monkeypatch.setattr(
        claims.notification_service, "claim_created", lambda *_args, **_kwargs: None
    )
    app.dependency_overrides[get_current_profile] = lambda: profile
    app.dependency_overrides[get_current_firebase_user] = lambda: {
        **_verified_firebase_user(),
        "email_verified": False,
        "phone_number": None,
    }
    try:
        response = TestClient(app).post(
            "/api/v1/claims",
            json={
                "donation_id": "11111111-1111-1111-1111-111111111111",
                "requested_quantity": 1,
            },
        )
        assert response.status_code == 201
        assert response.json()["ngo_id"] == "ngo-1"
    finally:
        app.dependency_overrides.clear()


def test_claim_endpoint_still_requires_authentication_and_ngo_role():
    unauthenticated = TestClient(app).post(
        "/api/v1/donation-offers/offer-1/respond",
        json={"decision": "accepted"},
    )
    assert unauthenticated.status_code == 401

    app.dependency_overrides[get_current_profile] = lambda: _provider()
    try:
        donor_offer_response = TestClient(app).post(
            "/api/v1/donation-offers/offer-1/respond",
            json={"decision": "accepted"},
        )
        assert donor_offer_response.status_code == 403

        donor = TestClient(app).post(
            "/api/v1/claims",
            json={
                "donation_id": "11111111-1111-1111-1111-111111111111",
                "requested_quantity": 1,
            },
        )
        assert donor.status_code == 403
        assert "Insufficient role" in donor.json()["detail"]
    finally:
        app.dependency_overrides.clear()


def test_complete_ngo_is_not_blocked_by_legacy_verification_flag():
    profile = _ngo(verified=False)
    require_complete_profile(profile, action="accepting a donation")
    assert ngo_profile_is_complete(profile, profile["ngos"][0])
