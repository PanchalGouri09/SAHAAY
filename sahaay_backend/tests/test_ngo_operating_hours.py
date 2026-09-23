"""
NGO operating-hours tests for the Phase-2 AI finalization (STEP 1).

Covers:
  * NGO profile create / update / read of available_from & available_to
  * rejection of partial or malformed hours (API 422 + DB constraint contract)
  * NGO matching using REAL hours read from the ngos table
  * NGOs with missing / malformed hours are excluded (never invented)
  * authorization: hours are written to the authenticated NGO's own row only;
    a client-supplied ngo_id is never trusted for that write.

Mocks (test-only): Supabase -> recording fake; auth -> dependency_overrides;
AI transport -> httpx.MockTransport running the real typed AIClient.
"""

from __future__ import annotations

import json
from types import SimpleNamespace

import httpx
import pytest
from fastapi.testclient import TestClient

from app.dependencies import get_current_firebase_user, get_current_profile
from app.main import app
from app.services.ai_client import AIClient, get_ai_client

client = TestClient(app)

_USER_ID = "user-ngo-1"
_NGO_ID = "ngo-1"
_PROVIDER_ID = "provider-1"


class _RowResult(SimpleNamespace):
    pass


class _FakeTable:
    def __init__(self, name: str) -> None:
        self._name = name
        self._rows: list[dict] = []
        self._filters: list[tuple] = []
        self._mode = "query"
        self._update_values: dict | None = None
        self._insert_values: list[dict] = []
        self._last_insert: dict | None = None

    def select(self, *cols) -> "_FakeTable":
        return self

    def eq(self, key: str, value: object) -> "_FakeTable":
        self._filters.append(("eq", key, value))
        return self

    def maybe_single(self) -> "_FakeTable":
        self._mode = "maybe_single"
        return self

    def single(self) -> "_FakeTable":
        self._mode = "single"
        return self

    def insert(self, values: dict) -> "_FakeTable":
        self._insert_values.append(dict(values))
        return self

    def update(self, values: dict) -> "_FakeTable":
        self._update_values = dict(values)
        return self

    def delete(self) -> "_FakeTable":
        return self

    def __getattr__(self, item):
        return lambda *a, **k: self

    def execute(self):
        rows = self._filtered()
        mode, values = self._mode, self._update_values
        self._mode = "query"
        self._update_values = None
        if self._insert_values:
            inserted = self._insert_values.pop(0)
            inserted.setdefault("id", f"{self._name}-row-1")
            self._rows.append(inserted)
            self._last_insert = inserted
            return _RowResult(data=[dict(inserted)])
        if values is not None:
            for row in rows:
                row.update(values)
            return _RowResult(data=dict(rows[0]) if rows else {})
        if mode == "maybe_single":
            if not rows:
                return None
            return _RowResult(data=dict(rows[0]))
        if mode == "single":
            return _RowResult(data=dict(rows[0]) if rows else {})
        return _RowResult(data=[dict(r) for r in rows])

    def _filtered(self) -> list[dict]:
        rows = list(self._rows)
        for kind, key, value in self._filters:
            if kind == "eq":
                rows = [r for r in rows if r.get(key) == value]
        return rows


class _FakeSupabase:
    def __init__(self) -> None:
        self.tables: dict[str, _FakeTable] = {}

    def table(self, name: str) -> _FakeTable:
        if name not in self.tables:
            self.tables[name] = _FakeTable(name)
        return self.tables[name]

    def seed(self, name: str, rows: list[dict]) -> None:
        for row in rows:
            self.tables[name]._rows.append(dict(row))


class _MatchHandler:
    def __init__(self) -> None:
        self.requests: list[httpx.Request] = []

    def handler(self, request: httpx.Request) -> httpx.Response:
        self.requests.append(request)
        if request.url.path == "/api/v1/reliability/calculate":
            body = json.loads(request.content)
            return httpx.Response(
                200,
                json={
                    "restaurant_id": body["restaurant_id"],
                    "reliability_score": 88.0,
                    "grade": "Good",
                    "breakdown": {},
                },
            )
        if request.url.path == "/api/v1/matching/rank-ngos":
            body = json.loads(request.content)
            ranked = [
                {
                    "ngo_id": c["ngo_id"],
                    "ngo_name": c["name"],
                    "distance_km": 2.0,
                    "distance_source": "straight_line",
                    "distance_score": 95.0,
                    "quantity_fit_score": 90.0,
                    "dietary_compatibility_score": 100.0,
                    "pickup_time_feasibility_score": 100.0,
                    "restaurant_reliability_score": 88.0,
                    "final_score": 91.0,
                    "rank": i + 1,
                }
                for i, c in enumerate(body["candidate_ngos"])
            ]
            return httpx.Response(
                200,
                json={
                    "donation_id": body["donation"]["donation_id"],
                    "ranked_ngos": ranked,
                    "weights_used": {},
                },
            )
        return httpx.Response(404, json={"detail": "not found"})


@pytest.fixture
def supabase(monkeypatch: pytest.MonkeyPatch):
    fake = _FakeSupabase()
    for module in (
        "app.dependencies.get_supabase_client",
        "app.routers.profile.get_supabase_client",
        "app.routers.ai_features.get_supabase_client",
        "app.routers.donations.get_supabase_client",
    ):
        monkeypatch.setattr(module, lambda: fake)
    yield fake
    app.dependency_overrides.clear()


@pytest.fixture
def ngo_auth(supabase):
    # Create-only: a Firebase user with no SAHAAY profile row yet.
    app.dependency_overrides[get_current_firebase_user] = lambda: {"uid": "fb-ngo-1"}
    yield supabase
    app.dependency_overrides.clear()


@pytest.fixture
def ngo_user(supabase):
    supabase.table("users")._rows.append(
        {
            "id": _USER_ID,
            "firebase_uid": "fb-ngo-1",
            "full_name": "NGO Coordinator",
            "email": "ngo@example.org",
            "role": "ngo",
            "ngos": [{"id": _NGO_ID}],
        }
    )
    app.dependency_overrides[get_current_firebase_user] = lambda: {"uid": "fb-ngo-1"}
    app.dependency_overrides[get_current_profile] = lambda: {
        "id": _USER_ID,
        "role": "ngo",
        "ngos": [{"id": _NGO_ID}],
    }
    yield supabase
    app.dependency_overrides.clear()


@pytest.fixture
def provider_user(supabase):
    supabase.table("users")._rows.append(
        {
            "id": "user-provider-1",
            "firebase_uid": "fb-provider-1",
            "role": "provider",
            "providers": [{"id": _PROVIDER_ID}],
        }
    )
    app.dependency_overrides[get_current_firebase_user] = lambda: {"uid": "fb-provider-1"}
    app.dependency_overrides[get_current_profile] = lambda: {
        "id": "user-provider-1",
        "role": "provider",
        "providers": [{"id": _PROVIDER_ID}],
    }
    yield supabase
    app.dependency_overrides.clear()


@pytest.fixture
def ai(supabase):
    handler = _MatchHandler()
    # Matching is a provider action: derive a provider profile server-side.
    supabase.table("users")._rows.append(
        {
            "id": "user-provider-2",
            "firebase_uid": "fb-provider-2",
            "role": "provider",
            "providers": [
                {"id": _PROVIDER_ID, "organization_name": "Tasty Kitchen",
                 "latitude": 18.52, "longitude": 73.85}
            ],
        }
    )
    app.dependency_overrides[get_current_profile] = lambda: {
        "id": "user-provider-2",
        "role": "provider",
        "providers": [
            {"id": _PROVIDER_ID, "organization_name": "Tasty Kitchen",
             "latitude": 18.52, "longitude": 73.85}
        ],
    }
    app.dependency_overrides[get_ai_client] = lambda: AIClient(
        base_url="http://ai.test", timeout=5.0, transport=httpx.MockTransport(handler.handler)
    )
    yield handler
    app.dependency_overrides.clear()


# ---------------------------------------------------------------------------
# NGO operating-hours schema: profile create
# ---------------------------------------------------------------------------
def _ngo_create_payload(**ngos) -> dict:
    base = {
        "full_name": "NGO Coordinator",
        "email": "ngo@example.org",
        "role": "ngo",
        "ngo": {
            "organization_name": "Feed The City",
            "address": "45 Bandra West, Mumbai",
            "city": "Mumbai",
            "food_capacity": 200,
        },
    }
    base["ngo"].update(ngos)
    return base


def test_ngo_profile_create_persists_operating_hours(ngo_auth) -> None:
    response = client.post(
        "/api/v1/profile",
        json=_ngo_create_payload(available_from="07:00", available_to="22:00"),
    )

    assert response.status_code == 201
    body = response.json()
    assert body["profile"]["available_from"] == "07:00"
    assert body["profile"]["available_to"] == "22:00"
    rows = ngo_auth.table("ngos")._rows
    assert rows[0]["available_from"] == "07:00"
    assert rows[0]["available_to"] == "22:00"


def test_ngo_profile_create_allows_missing_hours(ngo_auth) -> None:
    # Optional by design: an NGO may not have hours yet; matching just excludes it.
    response = client.post("/api/v1/profile", json=_ngo_create_payload())

    assert response.status_code == 201
    rows = ngo_auth.table("ngos")._rows
    assert rows[0].get("available_from") is None
    assert rows[0].get("available_to") is None


def test_ngo_profile_create_partial_hours_is_422(ngo_auth) -> None:
    response = client.post(
        "/api/v1/profile",
        json=_ngo_create_payload(available_from="07:00"),
    )

    assert response.status_code == 422
    assert ngo_auth.table("ngos")._rows == []


def test_ngo_profile_create_malformed_hours_is_422(ngo_auth) -> None:
    for bad in ("7:00", "25:00", "07:60", "seven", " 07:00"):
        response = client.post(
            "/api/v1/profile",
            json=_ngo_create_payload(available_from=bad, available_to="22:00"),
        )
        assert response.status_code == 422, f"expected 422 for available_from={bad!r}"
        assert ngo_auth.table("ngos")._rows == []


# ---------------------------------------------------------------------------
# NGO operating-hours schema: profile update
# ---------------------------------------------------------------------------
def test_ngo_profile_update_sets_operating_hours(ngo_user) -> None:
    ngo_user.table("ngos")._rows.append(
        {
            "id": _NGO_ID,
            "organization_name": "Feed The City",
            "address": "45 Bandra West, Mumbai",
        }
    )
    response = client.patch(
        "/api/v1/profile",
        json={
            "ngo": {
                "organization_name": "Feed The City",
                "address": "45 Bandra West, Mumbai",
                "available_from": "08:00",
                "available_to": "20:00",
            }
        },
    )

    assert response.status_code == 200
    updated = ngo_user.table("ngos")._rows[0]
    assert updated["available_from"] == "08:00"
    assert updated["available_to"] == "20:00"


def test_ngo_profile_update_partial_hours_is_422(ngo_user) -> None:
    ngo_user.table("ngos")._rows.append(
        {"id": _NGO_ID, "organization_name": "Feed The City", "address": "adr"}
    )
    response = client.patch(
        "/api/v1/profile",
        json={
            "ngo": {
                "organization_name": "Feed The City",
                "address": "adr",
                "available_to": "20:00",
            }
        },
    )

    assert response.status_code == 422
    assert ngo_user.table("ngos")._rows[0].get("available_to") is None


def test_ngo_profile_read_returns_operating_hours(ngo_user) -> None:
    ngo_row = {
        "id": _NGO_ID,
        "organization_name": "Feed The City",
        "address": "adr",
        "available_from": "09:00",
        "available_to": "18:00",
    }
    ngo_user.table("ngos")._rows.append(ngo_row)
    app.dependency_overrides[get_current_profile] = lambda: {
        "id": _USER_ID,
        "role": "ngo",
        "ngos": [ngo_row],
    }
    response = client.get("/api/v1/profile")

    assert response.status_code == 200
    body = response.json()
    ngo_profile = body["profile"][0]
    assert ngo_profile["available_from"] == "09:00"
    assert ngo_profile["available_to"] == "18:00"


# ---------------------------------------------------------------------------
# Authorization: hours write only to the authenticated NGO's own row
# ---------------------------------------------------------------------------
def test_ngo_hours_ignore_client_supplied_ngo_id(ngo_user) -> None:
    ngo_user.table("ngos")._rows.append(
        {
            "id": _NGO_ID,
            "organization_name": "Feed The City",
            "address": "adr",
        }
    )
    # An attacker tries to smuggle a different ngo_id — the backend must ignore it.
    response = client.patch(
        "/api/v1/profile",
        json={
            "ngo": {
                "organization_name": "Feed The City",
                "address": "adr",
                "ngo_id": "other-ngo-id",
                "available_from": "10:00",
                "available_to": "19:00",
            }
        },
    )

    assert response.status_code == 200
    updated = ngo_user.table("ngos")._rows[0]
    assert updated["id"] == _NGO_ID
    assert updated["available_from"] == "10:00"
    # No row belonging to a different NGO was touched.
    assert len(ngo_user.table("ngos")._rows) == 1


def test_ngo_hours_cannot_be_written_by_provider_role(provider_user) -> None:
    provider_user.table("providers")._rows.append(
        {"id": _PROVIDER_ID, "organization_name": "Tasty Kitchen", "address": "adr"}
    )
    provider_user.table("ngos")._rows.append(
        {"id": _NGO_ID, "organization_name": "Feed The City", "address": "adr"}
    )
    response = client.patch(
        "/api/v1/profile",
        json={"provider": {"organization_name": "Tasty Kitchen", "organization_type": "restaurant", "address": "adr"}},
    )

    assert response.status_code == 200
    # Provider update touched only the provider row, never an NGO row.
    assert provider_user.table("ngos")._rows[0].get("available_from") is None
    assert provider_user.table("providers")._rows[0]["address"] == "adr"


def test_ngo_profile_update_missing_role_row_is_404(ngo_user) -> None:
    # No ngos row exists for this user yet.
    ngo_user.table("ngos")._rows.clear()
    app.dependency_overrides[get_current_profile] = lambda: {
        "id": _USER_ID,
        "role": "ngo",
        "ngos": [],
    }
    response = client.patch("/api/v1/profile", json={"ngo": {"organization_name": "X", "address": "adr"}})

    assert response.status_code == 404
    assert "Role profile not found" in response.json()["detail"]


# ---------------------------------------------------------------------------
# NGO matching with real operating hours
# ---------------------------------------------------------------------------
def _seed_donation(fake, **overrides) -> None:
    row = {
        "id": "don-1",
        "provider_id": _PROVIDER_ID,
        "food_name": "Vegetable Rice",
        "quantity": 10.0,
        "unit": "kg",
        "veg_type": "vegetarian",
        "pickup_deadline": "2026-09-30T18:30:00+00:00",
        "prepared_at": "2026-09-29T12:00:00+00:00",
        "status": "available",
        "latitude": 18.52,
        "longitude": 73.85,
    }
    row.update(overrides)
    fake.table("donations")._rows.append(row)


def _seed_ngo(fake, ngo_id: str, *, hours: tuple[str, str] | None = ("07:00", "22:00"), **overrides) -> None:
    row = {
        "id": ngo_id,
        "organization_name": f"NGO {ngo_id}",
        "latitude": 18.53,
        "longitude": 73.86,
        "food_capacity": 50,
        "preferred_food_types": ["vegetarian", "vegan"],
        "verified": True,
    }
    if hours is not None:
        row["available_from"], row["available_to"] = hours
    row.update(overrides)
    fake.table("ngos")._rows.append(row)


def test_match_sends_real_ngo_hours_to_ai(ai, supabase) -> None:
    _seed_donation(supabase, provider_id=_PROVIDER_ID)
    _seed_ngo(supabase, "ngo-1", hours=("06:30", "23:00"))

    response = client.post("/api/v1/donations/don-1/match")

    assert response.status_code == 200
    assert response.json()["status"] == "ok"
    match_req = next(r for r in ai.requests if r.url.path == "/api/v1/matching/rank-ngos")
    payload = json.loads(match_req.content)
    candidate = payload["candidate_ngos"][0]
    assert candidate["available_from"] == "06:30"
    assert candidate["available_to"] == "23:00"
    assert candidate["ngo_id"] == "ngo-1"


def test_match_excludes_ngo_without_hours_but_keeps_one_with(ai, supabase) -> None:
    _seed_donation(supabase, provider_id=_PROVIDER_ID)
    _seed_ngo(supabase, "ngo-has-hours", hours=("07:00", "22:00"))
    _seed_ngo(supabase, "ngo-no-hours", hours=None)

    response = client.post("/api/v1/donations/don-1/match")

    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "ok"
    match_req = next(r for r in ai.requests if r.url.path == "/api/v1/matching/rank-ngos")
    candidates = json.loads(match_req.content)["candidate_ngos"]
    assert {c["ngo_id"] for c in candidates} == {"ngo-has-hours"}
    assert body["ranked_ngos"]  # real matching results for the candidate with hours


def test_match_all_ngos_missing_hours_returns_insufficient_data(ai, supabase) -> None:
    _seed_donation(supabase, provider_id=_PROVIDER_ID)
    _seed_ngo(supabase, "ngo-1", hours=None)
    _seed_ngo(supabase, "ngo-2", hours=None)

    response = client.post("/api/v1/donations/don-1/match")

    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "insufficient_data"
    assert "hours" in body["reason"]
    assert not any(r.url.path == "/api/v1/matching/rank-ngos" for r in ai.requests)


def test_match_all_ngos_malformed_hours_returns_insufficient_data(ai, supabase) -> None:
    _seed_donation(supabase, provider_id=_PROVIDER_ID)
    _seed_ngo(supabase, "ngo-1", hours=("7:00", "22:00"))
    _seed_ngo(supabase, "ngo-2", hours=("25:00", "26:00"))

    response = client.post("/api/v1/donations/don-1/match")

    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "insufficient_data"
    assert not any(r.url.path == "/api/v1/matching/rank-ngos" for r in ai.requests)


def test_match_ngos_with_malformed_hours_excluded_while_valid_kept(ai, supabase) -> None:
    _seed_donation(supabase, provider_id=_PROVIDER_ID)
    _seed_ngo(supabase, "ngo-valid", hours=("07:00", "22:00"))
    _seed_ngo(supabase, "ngo-bad-format", hours=("7:00", "22:00"))

    response = client.post("/api/v1/donations/don-1/match")

    assert response.status_code == 200
    assert response.json()["status"] == "ok"
    match_req = next(r for r in ai.requests if r.url.path == "/api/v1/matching/rank-ngos")
    candidates = json.loads(match_req.content)["candidate_ngos"]
    assert {c["ngo_id"] for c in candidates} == {"ngo-valid"}


def test_match_missing_donation_returns_404(ai, supabase) -> None:
    # No donation row at all — must be 404, not a crash.
    response = client.post("/api/v1/donations/don-missing/match")

    assert response.status_code == 404


def test_match_donation_owned_by_other_provider_returns_403(ai, supabase) -> None:
    _seed_donation(supabase, provider_id="provider-OTHER")

    response = client.post("/api/v1/donations/don-1/match")

    assert response.status_code == 403