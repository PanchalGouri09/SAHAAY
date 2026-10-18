from __future__ import annotations

from types import SimpleNamespace

import pytest
from fastapi import BackgroundTasks, HTTPException
from fastapi.testclient import TestClient
from pydantic import ValidationError

from app.dependencies import get_current_firebase_user, get_current_profile
from app.main import app
from app.routers import ngo_verification, profile as profile_router
from app.schemas.profile import NgoProfileCreate, NgoProfileUpdate, ProfileUpdate
from app.services.ngo_verification import (
    assess_ngo_demo_verification,
    update_demo_verification,
)
from app.services.profile_completion import (
    ngo_profile_is_complete,
    profile_completion_report,
)


def _profile(**ngo_overrides) -> dict:
    ngo = {
        "id": "ngo-demo-1",
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
        "verified": False,
        "demo_verified": False,
        "demo_verified_at": None,
    }
    ngo.update(ngo_overrides)
    return {
        "id": "user-demo-1",
        "firebase_uid": "firebase-demo-1",
        "role": "ngo",
        "full_name": "NGO Contact",
        "email": "ngo@example.org",
        "phone": "+91 9876543210",
        "ngos": [ngo],
    }


def _firebase_user(**overrides) -> dict:
    return {
        "uid": "firebase-demo-1",
        "email": "ngo@example.org",
        "email_verified": True,
        "phone_number": "+919876543210",
        "firebase": {"identities": {"phone": ["+919876543210"]}},
        **overrides,
    }


@pytest.fixture(autouse=True)
def _enable_test_phone_auth(monkeypatch):
    settings = SimpleNamespace(firebase_phone_auth_enabled=True)
    monkeypatch.setattr("app.config.get_settings", lambda: settings)
    monkeypatch.setattr("app.services.ngo_verification.get_settings", lambda: settings)


class _UpdateTable:
    def __init__(self, row: dict, writes: list[dict]):
        self.row = row
        self.writes = writes
        self.values = None
        self.row_id = None
        self.conditions = {}

    def update(self, values):
        self.values = dict(values)
        return self

    def eq(self, key, value):
        if key == "id":
            self.row_id = value
        else:
            self.conditions[key] = value
        return self

    def select(self, *_args):
        return self

    def execute(self):
        if self.row_id != self.row["id"] or any(
            self.row.get(key) != value for key, value in self.conditions.items()
        ):
            return SimpleNamespace(data=[])
        self.row.update(self.values)
        self.writes.append(dict(self.values))
        return SimpleNamespace(
            data=[
                {
                    key: self.row.get(key)
                    for key in ("id", "demo_verified", "demo_verified_at")
                }
            ]
        )


class _Client:
    def __init__(self, ngo: dict):
        self.ngo = ngo
        self.writes: list[dict] = []

    def table(self, name):
        assert name == "ngos"
        return _UpdateTable(self.ngo, self.writes)


def test_verified_firebase_email_and_complete_profile_allow_demo_status():
    profile = _profile()

    result = assess_ngo_demo_verification(profile, _firebase_user())

    assert result["demo_verified"] is True
    assert result["production_verified"] is False
    assert result["checks"]["email_verified"] is True
    assert result["checks"]["profile_complete"] is True
    assert result["checks"]["phone_verified"] is True
    assert result["checks"]["phone_otp"] == {
        "configured": True,
        "required": True,
        "verified": True,
        "status": "verified",
    }
    assert "does not represent legal NGO verification" in result["label"]
    assert "demo" not in result["label"].lower()
    assert profile["ngos"][0]["verified"] is False


def test_unverified_or_mismatched_firebase_email_does_not_demo_verify():
    profile = _profile()

    unverified = assess_ngo_demo_verification(
        profile, _firebase_user(email_verified=False)
    )
    mismatched = assess_ngo_demo_verification(
        profile, _firebase_user(email="other@example.org")
    )

    assert unverified["demo_verified"] is False
    assert any("Firebase verification link" in item for item in unverified["blockers"])
    assert mismatched["demo_verified"] is False
    assert any("does not match" in item for item in mismatched["blockers"])


def test_entered_phone_is_not_phone_verified():
    profile = _profile()

    result = assess_ngo_demo_verification(
        profile,
        _firebase_user(phone_number=None, firebase={"identities": {}}),
    )

    assert profile["phone"] == "+91 9876543210"
    assert result["checks"]["phone_otp"]["verified"] is False
    assert result["checks"]["phone_otp"]["configured"] is True
    assert any("Verify and link a phone" in item for item in result["blockers"])
    assert "checked through Firebase" in result["phone_notice"]


def test_phone_verification_provider_must_be_enabled_before_demo_approval(
    monkeypatch,
):
    settings = SimpleNamespace(firebase_phone_auth_enabled=False)
    monkeypatch.setattr("app.config.get_settings", lambda: settings)
    monkeypatch.setattr("app.services.ngo_verification.get_settings", lambda: settings)

    result = assess_ngo_demo_verification(_profile(), _firebase_user())

    assert result["demo_verified"] is False
    assert result["checks"]["phone_otp"]["verified"] is True
    assert result["checks"]["phone_otp"]["configured"] is False
    assert any("not enabled" in blocker for blocker in result["blockers"])


def test_missing_address_coordinates_and_matching_fields_are_reported():
    profile = _profile(
        address=" ",
        latitude=91,
        max_capacity_kg=None,
        preferred_food_types=[],
    )

    result = assess_ngo_demo_verification(profile, _firebase_user())

    assert result["demo_verified"] is False
    assert result["checks"]["address_valid"] is False
    assert result["checks"]["profile_complete"] is False
    assert any("address and choose a valid map location" in item for item in result["blockers"])
    assert any("Maximum donation capacity (kg)" in item for item in result["blockers"])
    assert any("Preferred food types" in item for item in result["blockers"])


def test_demo_status_transition_is_persisted_once_without_changing_production_flag():
    profile = _profile()
    ngo = profile["ngos"][0]
    client = _Client(ngo)
    assessment = assess_ngo_demo_verification(profile, _firebase_user())

    update_demo_verification(client, ngo, assessment)
    update_demo_verification(
        client,
        ngo,
        assess_ngo_demo_verification(profile, _firebase_user()),
    )

    assert ngo["demo_verified"] is True
    assert ngo["demo_verified_at"]
    assert ngo["verified"] is False
    assert len(client.writes) == 1
    assert profile_completion_report(profile)["complete"] is True
    assert ngo_profile_is_complete(profile, ngo)


def test_demo_status_transition_notifies_once(monkeypatch):
    profile = _profile()
    ngo = profile["ngos"][0]
    client = _Client(ngo)
    notifications = []
    monkeypatch.setattr(
        "app.services.ngo_verification.notification_service.ngo_demo_verification_changed",
        lambda _client, *, ngo, verified: notifications.append((ngo["id"], verified)),
    )
    assessment = assess_ngo_demo_verification(profile, _firebase_user())

    update_demo_verification(client, ngo, assessment)
    update_demo_verification(client, ngo, assessment)

    assert notifications == [("ngo-demo-1", True)]


def test_lost_eligibility_revokes_only_demo_status():
    profile = _profile(demo_verified=True, demo_verified_at="2026-10-16T00:00:00Z")
    ngo = profile["ngos"][0]
    client = _Client(ngo)

    result = assess_ngo_demo_verification(
        profile, _firebase_user(email_verified=False)
    )
    update_demo_verification(client, ngo, result)

    assert ngo["demo_verified"] is False
    assert ngo["demo_verified_at"] is None
    assert ngo["verified"] is False


def test_saving_last_required_field_refreshes_matching_without_demo_status(monkeypatch):
    profile = _profile(dietary_preferences=None)
    ngo = profile["ngos"][0]

    class _Table:
        def __init__(self, name):
            self.name = name
            self.values = None
            self.row_id = None
            self.single_result = False

        def update(self, values):
            self.values = dict(values)
            return self

        def select(self, *_args):
            return self

        def eq(self, _key, value):
            self.row_id = value
            return self

        def single(self):
            self.single_result = True
            return self

        def execute(self):
            if self.name == "ngos":
                ngo.update(self.values or {})
                return SimpleNamespace(data=[dict(ngo)])
            return SimpleNamespace(data={**profile, "ngos": [dict(ngo)]})

    class _ProfileClient:
        def table(self, name):
            return _Table(name)

    monkeypatch.setattr(
        profile_router, "get_supabase_client", lambda: _ProfileClient()
    )
    tasks = BackgroundTasks()
    response = profile_router.update_profile(
        ProfileUpdate.model_validate(
            {"ngo": {"dietary_preferences": ["vegetarian"]}}
        ),
        tasks,
        profile,
        _firebase_user(),
    )

    assert response["profile_completion"]["complete"] is True
    assert "demo_verification" not in response
    assert ngo["demo_verified"] is False
    assert ngo["verified"] is False
    assert len(tasks.tasks) == 1


def test_complete_ngo_matching_does_not_depend_on_legacy_verification_flags():
    profile = _profile(verified=False, demo_verified=False)
    ngo = profile["ngos"][0]
    assert profile_completion_report(profile)["complete"] is True
    assert ngo_profile_is_complete(profile, ngo)


def test_client_cannot_set_ngo_production_or_demo_verification_fields():
    with pytest.raises(ValidationError):
        NgoProfileCreate(
            organization_name="Community Pantry",
            address="2 Market Street",
            verified=True,
        )
    with pytest.raises(ValidationError):
        NgoProfileUpdate.model_validate({"demo_verified": True})


def test_separate_evaluation_route_is_not_exposed(monkeypatch):
    test_client = TestClient(app)
    profile = _profile()
    app.dependency_overrides[get_current_profile] = lambda: {
        **profile,
        "role": "provider",
    }
    app.dependency_overrides[get_current_firebase_user] = lambda: _firebase_user()
    try:
        absent = test_client.post("/api/v1/profile/ngo/demo-verification/evaluate")
        assert absent.status_code == 404
    finally:
        app.dependency_overrides.clear()
