"""
Regression tests for the postgrest-py 2.31 `maybe_single` contract.

In postgrest-py 2.31.0 the sync client's `.maybe_single().execute()` returns
Python `None` when the query matches zero rows (NOT a response object with
empty `.data`). Every route that used `if not response.data:` therefore crashed
with `AttributeError: 'NoneType' object has no attribute 'data'` on the
legitimate "no row found" path.

These tests drive the real FastAPI dependency chain (`get_current_profile`) and
each affected router against a fake Supabase that faithfully models the real
`maybe_single()` -> `None` behavior, asserting the intended HTTP status codes
(404/409) instead of a 500 crash, plus positive cases proving the happy path
still reads `.data` correctly.

Only the app-auth (`get_current_firebase_user`) and Supabase-transport layers
are mocked; no Firebase tokens and no live Supabase are required.
"""

from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from app.dependencies import get_current_firebase_user
from app.main import app

client = TestClient(app)


# ---------------------------------------------------------------------------
# Fake Supabase modelling the real postgrest-py sync semantics
# ---------------------------------------------------------------------------
class _RowResult:
    def __init__(self, data) -> None:
        self.data = data


class _FakeTable:
    def __init__(self, name: str) -> None:
        self._name = name
        self._rows: list[dict] = []
        self._mode = "query"
        self._values: dict | None = None

    def select(self, *cols: str) -> "_FakeTable":
        return self

    def eq(self, key: str, value: object) -> "_FakeTable":
        return self

    def order(self, col: str, **kwargs) -> "_FakeTable":
        return self

    def update(self, values: dict) -> "_FakeTable":
        self._values = dict(values)
        return self

    def insert(self, values: dict) -> "_FakeTable":
        row = dict(values)
        row.setdefault("id", f"{self._name}-row-1")
        self._rows.append(row)
        return self

    def delete(self) -> "_FakeTable":
        return self

    def maybe_single(self) -> "_FakeTable":
        self._mode = "maybe_single"
        return self

    def single(self) -> "_FakeTable":
        self._mode = "single"
        return self

    def execute(self):
        mode = self._mode
        values = self._values
        self._mode = "query"
        self._values = None
        if mode == "maybe_single":
            if not self._rows:
                return None
            return _RowResult(self._merged(values))
        if mode == "single":
            if not self._rows:
                raise RuntimeError("single() expected exactly one row")
            return _RowResult(self._merged(values))
        rows = []
        for row in self._rows:
            merged = dict(row)
            if values:
                merged.update(values)
            rows.append(merged)
        return _RowResult(rows)

    def _merged(self, values: dict | None) -> dict:
        row = dict(self._rows[0])
        if values:
            row.update(values)
        return row


class _FakeSupabase:
    def __init__(self) -> None:
        self.tables: dict[str, _FakeTable] = {}

    def table(self, name: str) -> _FakeTable:
        if name not in self.tables:
            self.tables[name] = _FakeTable(name)
        return self.tables[name]


@pytest.fixture
def supabase(monkeypatch: pytest.MonkeyPatch) -> _FakeSupabase:
    fake = _FakeSupabase()
    for module in (
        "app.dependencies.get_supabase_client",
        "app.routers.profile.get_supabase_client",
        "app.routers.donations.get_supabase_client",
        "app.routers.notifications.get_supabase_client",
        "app.routers.claims.get_supabase_client",
        "app.routers.deliveries.get_supabase_client",
    ):
        monkeypatch.setattr(module, lambda: fake)
    app.dependency_overrides[get_current_firebase_user] = lambda: {
        "uid": "firebase-uid-1"
    }
    yield fake
    app.dependency_overrides.clear()


# ---------------------------------------------------------------------------
# Profile lookup (app/dependencies.get_current_profile)
# ---------------------------------------------------------------------------
def test_profile_lookup_missing_row_returns_404(supabase) -> None:
    response = client.get("/api/v1/profile")

    assert response.status_code == 404
    assert response.json()["detail"] == "SAHAAY profile not found."


def test_profile_lookup_found_row_returns_200(supabase) -> None:
    supabase.table("users").insert(
        {
            "id": "user-1",
            "firebase_uid": "firebase-uid-1",
            "role": "volunteer",
            "volunteers": [{"id": "vol-1"}],
        }
    )

    response = client.get("/api/v1/profile")

    assert response.status_code == 200
    body = response.json()
    assert body["role"] == "volunteer"
    assert body["profile"] == [{"id": "vol-1"}]


# ---------------------------------------------------------------------------
# Profile creation (app/routers/profile.py)
# ---------------------------------------------------------------------------
def test_profile_create_existing_row_returns_409(supabase) -> None:
    supabase.table("users").insert({"id": "user-1", "firebase_uid": "firebase-uid-1"})
    payload = {
        "full_name": "A New User",
        "email": "new@example.com",
        "role": "volunteer",
        "volunteer": {"availability_status": "available"},
    }

    response = client.post("/api/v1/profile", json=payload)

    assert response.status_code == 409
    assert response.json()["detail"] == "A SAHAAY profile already exists."


def test_profile_create_missing_row_creates_profile(supabase) -> None:
    payload = {
        "full_name": "A New User",
        "email": "new@example.com",
        "role": "volunteer",
        "volunteer": {"availability_status": "available"},
    }

    response = client.post("/api/v1/profile", json=payload)

    assert response.status_code == 201
    body = response.json()
    assert body["id"] == "users-row-1"
    assert body["profile"]["availability_status"] == "available"
    assert body["profile"]["user_id"] == "users-row-1"


def test_provider_profile_creation_succeeds(supabase) -> None:
    payload = {
        "full_name": "Provider Owner",
        "email": "owner@provider.org",
        "role": "provider",
        "provider": {
            "organization_name": "Fresh Bites Kitchen",
            "organization_type": "restaurant",
            "address": "123 MG Road, Pune",
            "city": "Pune",
        },
    }

    response = client.post("/api/v1/profile", json=payload)

    assert response.status_code == 201
    body = response.json()
    assert body["role"] == "provider"
    assert body["profile"]["organization_name"] == "Fresh Bites Kitchen"
    assert body["profile"]["user_id"] == "users-row-1"


def test_ngo_profile_creation_succeeds(supabase) -> None:
    payload = {
        "full_name": "NGO Coordinator",
        "email": "coordinator@ngo.org",
        "role": "ngo",
        "ngo": {
            "organization_name": "Feed The City",
            "address": "45 Bandra West, Mumbai",
            "city": "Mumbai",
            "food_capacity": 200,
        },
    }

    response = client.post("/api/v1/profile", json=payload)

    assert response.status_code == 201
    body = response.json()
    assert body["role"] == "ngo"
    assert body["profile"]["organization_name"] == "Feed The City"
    assert body["profile"]["food_capacity"] == 200
    assert body["profile"]["user_id"] == "users-row-1"


def test_volunteer_profile_creation_succeeds(supabase) -> None:
    payload = {
        "full_name": "Volunteer One",
        "email": "vol1@example.com",
        "role": "volunteer",
        "volunteer": {"availability_status": "available", "vehicle_type": "bike"},
    }

    response = client.post("/api/v1/profile", json=payload)

    assert response.status_code == 201
    body = response.json()
    assert body["role"] == "volunteer"
    assert body["profile"]["availability_status"] == "available"
    assert body["profile"]["vehicle_type"] == "bike"
    assert body["profile"]["user_id"] == "users-row-1"


def test_profile_create_provider_without_data_is_422(supabase) -> None:
    payload = {"full_name": "No Data", "email": "nodata@example.com", "role": "provider"}

    response = client.post("/api/v1/profile", json=payload)

    assert response.status_code == 422
    assert "Provider profile data is required" in response.json()["detail"]


def test_profile_create_admin_role_is_403(supabase) -> None:
    payload = {
        "full_name": "Admin Wannabe",
        "email": "admin@example.com",
        "role": "admin",
    }

    response = client.post("/api/v1/profile", json=payload)

    assert response.status_code == 403
    assert response.json()["detail"] == "Admin profiles are provisioned separately."


# ---------------------------------------------------------------------------
# Donation lookup (app/routers/donations.py)
# ---------------------------------------------------------------------------
def test_donation_missing_row_returns_404(supabase) -> None:
    supabase.table("users").insert(
        {"id": "user-1", "role": "provider", "providers": [{"id": "provider-1"}]}
    )

    response = client.get("/api/v1/donations/missing-donation-id")

    assert response.status_code == 404
    assert response.json()["detail"] == "Donation not found."


def test_donation_found_row_returns_200(supabase) -> None:
    supabase.table("users").insert(
        {"id": "user-1", "role": "provider", "providers": [{"id": "provider-1"}]}
    )
    supabase.table("donations").insert(
        {
            "id": "don-1",
            "provider_id": "provider-1",
            "status": "available",
            "food_name": "Vegetable Rice",
        }
    )

    response = client.get("/api/v1/donations/don-1")

    assert response.status_code == 200
    assert response.json()["id"] == "don-1"


# ---------------------------------------------------------------------------
# Notification read (app/routers/notifications.py)
# ---------------------------------------------------------------------------
def test_notification_missing_row_returns_404(supabase) -> None:
    supabase.table("users").insert({"id": "user-1"})

    response = client.patch("/api/v1/notifications/missing-notif/read")

    assert response.status_code == 404
    assert response.json()["detail"] == "Notification not found."


def test_notification_found_row_marks_read(supabase) -> None:
    supabase.table("users").insert({"id": "user-1"})
    supabase.table("notifications").insert(
        {"id": "notif-1", "user_id": "user-1", "is_read": False}
    )

    response = client.patch("/api/v1/notifications/notif-1/read")

    assert response.status_code == 200
    assert response.json()["is_read"] is True


# ---------------------------------------------------------------------------
# Claim creation (app/routers/claims.py)
# ---------------------------------------------------------------------------
def test_claim_creation_returns_201_with_row(supabase) -> None:
    supabase.table("users").insert(
        {"id": "user-1", "role": "ngo", "ngos": [{"id": "ngo-1"}]}
    )

    response = client.post(
        "/api/v1/claims",
        json={"donation_id": "11111111-1111-1111-1111-111111111111", "requested_quantity": 5.0},
    )

    assert response.status_code == 201
    body = response.json()
    assert body["ngo_id"] == "ngo-1"
    assert body["donation_id"] == "11111111-1111-1111-1111-111111111111"
    assert body["id"] == "claims-row-1"


# ---------------------------------------------------------------------------
# Claim update (app/routers/claims.py)
# ---------------------------------------------------------------------------
def test_claim_missing_row_returns_404(supabase) -> None:
    supabase.table("users").insert(
        {"id": "user-1", "role": "ngo", "ngos": [{"id": "ngo-1"}]}
    )

    response = client.patch("/api/v1/claims/missing-claim", params={"status": "accepted"})

    assert response.status_code == 404
    assert response.json()["detail"] == "Claim not found for this NGO."


def test_claim_found_row_updates_status(supabase) -> None:
    supabase.table("users").insert(
        {"id": "user-1", "role": "ngo", "ngos": [{"id": "ngo-1"}]}
    )
    supabase.table("claims").insert(
        {"id": "claim-1", "ngo_id": "ngo-1", "status": "pending"}
    )

    response = client.patch("/api/v1/claims/claim-1", params={"status": "accepted"})

    assert response.status_code == 200
    assert response.json()["status"] == "accepted"


# ---------------------------------------------------------------------------
# Delivery status update (app/routers/deliveries.py)
# ---------------------------------------------------------------------------
def test_delivery_missing_row_returns_404(supabase) -> None:
    supabase.table("users").insert(
        {"id": "user-1", "role": "volunteer", "volunteers": [{"id": "vol-1"}]}
    )

    response = client.patch(
        "/api/v1/deliveries/missing-delivery/status",
        json={"status": "accepted"},
    )

    assert response.status_code == 404
    assert response.json()["detail"] == "Delivery not found."


def test_delivery_found_row_updates_status(supabase) -> None:
    supabase.table("users").insert(
        {"id": "user-1", "role": "volunteer", "volunteers": [{"id": "vol-1"}]}
    )
    supabase.table("deliveries").insert(
        {"id": "delivery-1", "volunteer_id": "vol-1", "status": "assigned"}
    )

    response = client.patch(
        "/api/v1/deliveries/delivery-1/status",
        json={"status": "accepted"},
    )

    assert response.status_code == 200
    assert response.json()["status"] == "accepted"