"""
NGO vehicle-availability tests.

Covers:
  * tri-state semantics: true / false / null ("not answered")
  * the authenticated NGO's own row is the only row ever written
  * non-NGO roles are rejected (403) and a client cannot address another NGO
  * the AI matching request contract is unchanged (no vehicle field is sent)
  * vehicle availability is surfaced in ranked results and applied as a
    documented preference tier, never as a hard filter
  * existing matching behaviour is untouched when no NGO has a vehicle

Mocks (test-only): Supabase -> recording fake; auth -> dependency_overrides;
AI transport -> httpx.MockTransport running the real typed AIClient.
"""

from __future__ import annotations

import json
from types import SimpleNamespace

import httpx
import pytest
from fastapi import HTTPException
from fastapi.testclient import TestClient

from app.dependencies import get_current_firebase_user, get_current_profile, require_role
from app.main import app
from app.services.ai_client import AIClient, get_ai_client

client = TestClient(app)

_USER_ID = "user-ngo-1"
_NGO_ID = "ngo-1"
_OTHER_NGO_ID = "ngo-other"
_PROVIDER_ID = "provider-1"

_VEHICLE_URL = "/api/v1/profile/ngo/vehicle-availability"


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
        # Reset per-request builder state, mirroring supabase-py's behaviour
        # where each table() call starts a fresh query. Without this, filters
        # from an earlier request would leak into the next one.
        self._mode = "query"
        self._update_values = None
        self._filters = []
        if self._insert_values:
            inserted = self._insert_values.pop(0)
            inserted.setdefault("id", f"{self._name}-row-1")
            self._rows.append(inserted)
            return _RowResult(data=[dict(inserted)])
        if values is not None:
            for row in rows:
                row.update(values)
            return _RowResult(data=[dict(r) for r in rows])
        if mode == "maybe_single":
            return None if not rows else _RowResult(data=dict(rows[0]))
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
        target = self.table(name)
        for row in rows:
            target._rows.append(dict(row))


class _MatchHandler:
    """Fake AI transport. Ranks candidates in the order received, and also
    records the raw request so tests can assert the AI contract is unchanged."""

    def __init__(self) -> None:
        self.requests: list[httpx.Request] = []
        self.match_bodies: list[dict] = []

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
            self.match_bodies.append(body)
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
    """Firebase-authenticated user with no SAHAAY profile row yet."""
    app.dependency_overrides[get_current_firebase_user] = lambda: {"uid": "fb-ngo-1"}
    yield supabase
    app.dependency_overrides.clear()


@pytest.fixture
def ngo_user(supabase):
    """A signed-in NGO that already has a ngos row."""
    supabase.seed("ngos", [{"id": _NGO_ID, "organization_name": "Feed The City"}])
    supabase.seed(
        "users",
        [
            {
                "id": _USER_ID,
                "firebase_uid": "fb-ngo-1",
                "full_name": "NGO Coordinator",
                "email": "ngo@example.org",
                "role": "ngo",
                "ngos": [{"id": _NGO_ID}],
            }
        ],
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
    supabase.seed(
        "users",
        [
            {
                "id": "user-provider-1",
                "firebase_uid": "fb-provider-1",
                "role": "provider",
                "providers": [{"id": _PROVIDER_ID}],
            }
        ],
    )
    app.dependency_overrides[get_current_firebase_user] = lambda: {"uid": "fb-provider-1"}
    app.dependency_overrides[get_current_profile] = lambda: {
        "id": "user-provider-1",
        "role": "provider",
        "providers": [{"id": _PROVIDER_ID}],
    }
    yield supabase
    app.dependency_overrides.clear()


# ---------------------------------------------------------------------------
# Tri-state writes
# ---------------------------------------------------------------------------
def test_ngo_can_set_vehicle_available_true(ngo_user) -> None:
    response = client.patch(_VEHICLE_URL, json={"vehicle_available": True})

    assert response.status_code == 200
    assert response.json()["vehicle_available"] is True
    assert ngo_user.table("ngos")._rows[0]["vehicle_available"] is True


def test_ngo_can_set_vehicle_available_false(ngo_user) -> None:
    response = client.patch(_VEHICLE_URL, json={"vehicle_available": False})

    assert response.status_code == 200
    assert response.json()["vehicle_available"] is False
    assert ngo_user.table("ngos")._rows[0]["vehicle_available"] is False


def test_false_is_stored_as_false_not_as_null(ngo_user) -> None:
    # Guards the core requirement: an explicit "no" must not collapse into the
    # same stored value as "not answered".
    client.patch(_VEHICLE_URL, json={"vehicle_available": False})
    stored = ngo_user.table("ngos")._rows[0]["vehicle_available"]

    assert stored is False
    assert stored is not None


def test_ngo_can_change_the_answer_later(ngo_user) -> None:
    client.patch(_VEHICLE_URL, json={"vehicle_available": False})
    response = client.patch(_VEHICLE_URL, json={"vehicle_available": True})

    assert response.status_code == 200
    assert response.json()["vehicle_available"] is True
    assert ngo_user.table("ngos")._rows[0]["vehicle_available"] is True


def test_null_clears_the_answer_back_to_unanswered(ngo_user) -> None:
    client.patch(_VEHICLE_URL, json={"vehicle_available": True})
    response = client.patch(_VEHICLE_URL, json={"vehicle_available": None})

    assert response.status_code == 200
    assert response.json()["vehicle_available"] is None
    assert ngo_user.table("ngos")._rows[0]["vehicle_available"] is None


def test_unset_null_state_is_preserved_on_read(ngo_user) -> None:
    # A never-answered NGO keeps NULL; it is never coerced to false.
    assert ngo_user.table("ngos")._rows[0].get("vehicle_available") is None

    response = client.patch(_VEHICLE_URL, json={})

    assert response.status_code == 200
    assert response.json()["vehicle_available"] is None


def test_non_boolean_values_are_rejected(ngo_user) -> None:
    for bad in ("true", "false", "yes", 1, 0, []):
        response = client.patch(_VEHICLE_URL, json={"vehicle_available": bad})
        assert response.status_code == 422, f"expected 422 for {bad!r}"

    assert ngo_user.table("ngos")._rows[0].get("vehicle_available") is None


def test_endpoint_returns_updated_ngo_data(ngo_user) -> None:
    response = client.patch(_VEHICLE_URL, json={"vehicle_available": True})

    body = response.json()
    assert body["status"] == "ok"
    assert body["ngo_id"] == _NGO_ID
    assert body["organization_name"] == "Feed The City"


# ---------------------------------------------------------------------------
# Authorization
# ---------------------------------------------------------------------------
def test_provider_cannot_update_ngo_vehicle_availability(provider_user, supabase) -> None:
    supabase.seed("ngos", [{"id": _NGO_ID, "organization_name": "Feed The City"}])

    response = client.patch(_VEHICLE_URL, json={"vehicle_available": True})

    assert response.status_code == 403
    assert supabase.table("ngos")._rows[0].get("vehicle_available") is None


def test_volunteer_cannot_update_ngo_vehicle_availability(supabase) -> None:
    supabase.seed("ngos", [{"id": _NGO_ID, "organization_name": "Feed The City"}])
    app.dependency_overrides[get_current_firebase_user] = lambda: {"uid": "fb-vol-1"}
    app.dependency_overrides[get_current_profile] = lambda: {
        "id": "user-vol-1",
        "role": "volunteer",
        "volunteers": [{"id": "vol-1"}],
    }

    response = client.patch(_VEHICLE_URL, json={"vehicle_available": True})

    assert response.status_code == 403
    assert supabase.table("ngos")._rows[0].get("vehicle_available") is None
    app.dependency_overrides.clear()


def test_unauthenticated_request_is_rejected(supabase) -> None:
    # No profile override: the real get_current_profile runs and must reject the
    # request through the verified-token dependency before any write happens.
    def _reject() -> dict:
        raise HTTPException(status_code=401, detail="Firebase token is invalid.")

    app.dependency_overrides[get_current_firebase_user] = _reject

    response = client.patch(_VEHICLE_URL, json={"vehicle_available": True})

    assert response.status_code == 401
    assert supabase.table("ngos")._rows == []
    app.dependency_overrides.clear()


def test_ngo_id_in_body_cannot_target_another_ngos_row(ngo_user, supabase) -> None:
    # The endpoint body has no identifier field, so a client cannot address
    # another NGO. The authenticated NGO's own row is the only one written.
    supabase.seed("ngos", [{"id": _OTHER_NGO_ID, "organization_name": "Other NGO"}])

    response = client.patch(
        _VEHICLE_URL,
        json={"vehicle_available": True, "ngo_id": _OTHER_NGO_ID, "id": _OTHER_NGO_ID},
    )

    assert response.status_code == 200
    rows = {r["id"]: r for r in supabase.table("ngos")._rows}
    assert rows[_NGO_ID]["vehicle_available"] is True
    assert rows[_OTHER_NGO_ID].get("vehicle_available") is None


def test_ngo_id_in_body_is_ignored_not_trusted(ngo_user) -> None:
    # Even if a future schema grew an id field, the write must stay scoped to
    # the server-resolved row. Pydantic ignores unknown keys by default.
    response = client.patch(
        _VEHICLE_URL,
        json={"vehicle_available": False, "ngo_id": _OTHER_NGO_ID},
    )

    assert response.status_code == 200
    assert response.json()["ngo_id"] == _NGO_ID


def test_identity_is_derived_server_side(ngo_user) -> None:
    # Two different Firebase users must never share one vehicle answer.
    ngo_user.seed("ngos", [{"id": _OTHER_NGO_ID, "organization_name": "Other NGO"}])
    client.patch(_VEHICLE_URL, json={"vehicle_available": True})

    app.dependency_overrides[get_current_firebase_user] = lambda: {"uid": "fb-ngo-2"}
    app.dependency_overrides[get_current_profile] = lambda: {
        "id": "user-ngo-2",
        "role": "ngo",
        "ngos": [{"id": _OTHER_NGO_ID}],
    }
    second = client.patch(_VEHICLE_URL, json={"vehicle_available": False})
    assert second.status_code == 200, second.json()

    rows = {r["id"]: r for r in ngo_user.table("ngos")._rows}
    assert rows[_NGO_ID]["vehicle_available"] is True
    assert rows[_OTHER_NGO_ID]["vehicle_available"] is False


# ---------------------------------------------------------------------------
# Profile create carries the field through
# ---------------------------------------------------------------------------
def test_ngo_profile_create_accepts_vehicle_available(ngo_auth) -> None:
    response = client.post(
        "/api/v1/profile",
        json={
            "full_name": "NGO Coordinator",
            "email": "ngo@example.org",
            "role": "ngo",
            "ngo": {
                "organization_name": "Feed The City",
                "address": "45 Bandra West, Mumbai",
                "city": "Mumbai",
                "food_capacity": 200,
                "vehicle_available": True,
            },
        },
    )

    assert response.status_code == 201
    assert response.json()["profile"]["vehicle_available"] is True
    assert ngo_auth.table("ngos")._rows[0]["vehicle_available"] is True


def test_ngo_profile_create_defaults_to_unanswered(ngo_auth) -> None:
    response = client.post(
        "/api/v1/profile",
        json={
            "full_name": "NGO Coordinator",
            "email": "ngo@example.org",
            "role": "ngo",
            "ngo": {
                "organization_name": "Feed The City",
                "address": "45 Bandra West, Mumbai",
            },
        },
    )

    assert response.status_code == 201
    assert response.json()["profile"].get("vehicle_available") is None


# ---------------------------------------------------------------------------
# Matching
# ---------------------------------------------------------------------------
def _ngo_row(ngo_id: str, **overrides) -> dict:
    row = {
        "id": ngo_id,
        "organization_name": f"NGO {ngo_id}",
        "city": "Mumbai",
        "address": "Somewhere",
        "verified": True,
        "food_capacity": 200,
        "preferred_food_types": ["vegetarian", "vegan"],
        "available_from": "07:00",
        "available_to": "22:00",
        "latitude": 19.07,
        "longitude": 72.87,
    }
    row.update(overrides)
    return row


def _seed_matching_donation(supabase, **donation_overrides) -> str:
    donation_id = "donation-1"
    donation = {
        "id": donation_id,
        "provider_id": _PROVIDER_ID,
        "status": "available",
        "quantity": 10.0,
        "unit": "kg",
        "veg_type": "vegetarian",
        "pickup_deadline": "2030-01-01T18:00:00Z",
        "latitude": 19.0,
        "longitude": 72.8,
    }
    donation.update(donation_overrides)
    supabase.seed("donations", [donation])
    supabase.seed(
        "providers",
        [
            {
                "id": _PROVIDER_ID,
                "organization_name": "Tasty Kitchen",
                "latitude": 19.0,
                "longitude": 72.8,
            }
        ],
    )
    supabase.seed("food_predictions", [])
    return donation_id


@pytest.fixture
def matching(supabase, monkeypatch: pytest.MonkeyPatch):
    handler = _MatchHandler()
    # The provider's transport capability is read from the authenticated profile
    # join, so it lives on the profile dict the dependency returns. Exposing it on
    # the handler lets a test set the provider side of the pair.
    handler.provider_profile = {
        "id": "user-provider-1",
        "role": "provider",
        "providers": [
            {
                "id": _PROVIDER_ID,
                "organization_name": "Tasty Kitchen",
                "latitude": 19.0,
                "longitude": 72.8,
            }
        ],
    }
    app.dependency_overrides[get_current_firebase_user] = lambda: {"uid": "fb-provider-1"}
    app.dependency_overrides[get_current_profile] = lambda: handler.provider_profile
    app.dependency_overrides[get_ai_client] = lambda: AIClient(
        base_url="http://ai.test", timeout=5.0, transport=httpx.MockTransport(handler.handler)
    )
    yield handler
    app.dependency_overrides.clear()


def _set_provider_vehicle(matching, value: bool | None) -> None:
    """Sets the provider's tri-state vehicle answer for a matching test."""
    matching.provider_profile["providers"][0]["vehicle_available"] = value


def test_matching_request_never_sends_vehicle_to_ai(matching, supabase) -> None:
    # The AI contract is unchanged: no vehicle field is invented.
    supabase.seed("ngos", [_ngo_row("ngo-a", vehicle_available=True)])
    donation_id = _seed_matching_donation(supabase)

    response = client.post(f"/api/v1/donations/{donation_id}/match")

    assert response.status_code == 200
    body = matching.match_bodies[-1]
    assert "vehicle_available" not in json.dumps(body)
    for candidate in body["candidate_ngos"]:
        assert "vehicle_available" not in candidate


def test_matching_surfaces_vehicle_available_in_results(matching, supabase) -> None:
    supabase.seed("ngos", [_ngo_row("ngo-a", vehicle_available=True)])
    donation_id = _seed_matching_donation(supabase)

    response = client.post(f"/api/v1/donations/{donation_id}/match")

    assert response.status_code == 200
    assert "ranked_ngos" in response.json(), response.json()
    ranked = response.json()["ranked_ngos"]
    assert ranked[0]["ngo"]["vehicle_available"] is True


def test_matching_reports_null_for_unanswered_ngos(matching, supabase) -> None:
    # NULL is passed through as null, never coerced to false.
    supabase.seed("ngos", [_ngo_row("ngo-a", vehicle_available=None)])
    donation_id = _seed_matching_donation(supabase)

    response = client.post(f"/api/v1/donations/{donation_id}/match")

    assert response.status_code == 200
    ranked = response.json()["ranked_ngos"]
    assert ranked[0]["ngo"]["vehicle_available"] is None


def test_matching_missing_column_value_is_treated_as_unanswered(matching, supabase) -> None:
    # Rows written before the migration have no key at all.
    row = _ngo_row("ngo-a")
    row.pop("vehicle_available", None)
    supabase.seed("ngos", [row])
    donation_id = _seed_matching_donation(supabase)

    response = client.post(f"/api/v1/donations/{donation_id}/match")

    assert response.status_code == 200
    ranked = response.json()["ranked_ngos"]
    assert ranked[0]["ngo"]["vehicle_available"] is None


def test_ngo_vehicle_alone_does_not_drive_ordering(matching, supabase) -> None:
    # CORRECTED BUSINESS RULE: a vehicle-owning NGO is not automatically better.
    # With the provider having no transport capability, an NGO that CAN collect
    # is the one that completes the pickup, so it leads. This is pairwise
    # logistics viability, not "vehicle = higher score".
    supabase.seed(
        "ngos",
        [
            _ngo_row("ngo-novehicle", vehicle_available=False),
            _ngo_row("ngo-vehicle", vehicle_available=True),
        ],
    )
    _set_provider_vehicle(matching, False)
    donation_id = _seed_matching_donation(supabase)

    response = client.post(f"/api/v1/donations/{donation_id}/match")

    assert response.status_code == 200
    body = response.json()
    assert body["logistics_ordering_applied"] is True
    assert body["provider_vehicle_available"] is False
    order = [item["ngo"]["id"] for item in body["ranked_ngos"]]
    assert order == ["ngo-vehicle", "ngo-novehicle"]
    compat = {item["ngo"]["id"]: item["vehicle_compatibility"] for item in body["ranked_ngos"]}
    assert compat == {
        "ngo-vehicle": "ngo_transport",
        "ngo-novehicle": "volunteer_required",
    }


def test_unknown_ranks_above_volunteer_required(matching, supabase) -> None:
    # Documented ordering: an unanswered NGO may still resolve into a working
    # arrangement, whereas volunteer_required is a confirmed dependency on a
    # third party, so it is offered last. A capable NGO is present so the
    # logistics layer is actually active.
    supabase.seed(
        "ngos",
        [
            _ngo_row("ngo-false", vehicle_available=False),
            _ngo_row("ngo-null", vehicle_available=None),
            _ngo_row("ngo-true", vehicle_available=True),
        ],
    )
    _set_provider_vehicle(matching, False)
    donation_id = _seed_matching_donation(supabase)

    response = client.post(f"/api/v1/donations/{donation_id}/match")

    assert response.status_code == 200
    order = [item["ngo"]["id"] for item in response.json()["ranked_ngos"]]
    assert order == ["ngo-true", "ngo-null", "ngo-false"]


def test_no_ngos_are_dropped_by_the_logistics_layer(matching, supabase) -> None:
    # Not a filter: a volunteer_required NGO is still ranked and claimable.
    supabase.seed(
        "ngos",
        [
            _ngo_row("ngo-a", vehicle_available=False),
            _ngo_row("ngo-b", vehicle_available=False),
            _ngo_row("ngo-c", vehicle_available=True),
        ],
    )
    _set_provider_vehicle(matching, False)
    donation_id = _seed_matching_donation(supabase)

    response = client.post(f"/api/v1/donations/{donation_id}/match")

    assert response.status_code == 200
    order = [item["ngo"]["id"] for item in response.json()["ranked_ngos"]]
    assert sorted(order) == ["ngo-a", "ngo-b", "ngo-c"]


def test_ai_order_preserved_when_no_candidate_can_carry_the_food(
    matching, supabase
) -> None:
    # Nothing can be transported without a volunteer, so reordering would be
    # noise and the AI ranking is returned untouched.
    supabase.seed(
        "ngos",
        [
            _ngo_row("ngo-a", vehicle_available=False),
            _ngo_row("ngo-b", vehicle_available=None),
        ],
    )
    _set_provider_vehicle(matching, None)
    donation_id = _seed_matching_donation(supabase)

    response = client.post(f"/api/v1/donations/{donation_id}/match")

    assert response.status_code == 200
    body = response.json()
    assert body["logistics_ordering_applied"] is False
    # The AI returned candidates in seed order; that order is preserved.
    order = [item["ngo"]["id"] for item in body["ranked_ngos"]]
    assert order == ["ngo-a", "ngo-b"]


def test_all_ngos_unanswered_keeps_ai_order(matching, supabase) -> None:
    supabase.seed(
        "ngos",
        [_ngo_row("ngo-a", vehicle_available=None), _ngo_row("ngo-b", vehicle_available=None)],
    )
    donation_id = _seed_matching_donation(supabase)

    response = client.post(f"/api/v1/donations/{donation_id}/match")

    assert response.status_code == 200
    order = [item["ngo"]["id"] for item in response.json()["ranked_ngos"]]
    assert order == ["ngo-a", "ngo-b"]


def test_vehicle_does_not_change_candidate_eligibility(matching, supabase) -> None:
    # Both NGOs are still sent to the AI regardless of vehicle state.
    supabase.seed(
        "ngos",
        [
            _ngo_row("ngo-vehicle", vehicle_available=True),
            _ngo_row("ngo-false", vehicle_available=False),
        ],
    )
    donation_id = _seed_matching_donation(supabase)

    client.post(f"/api/v1/donations/{donation_id}/match")

    sent = [c["ngo_id"] for c in matching.match_bodies[-1]["candidate_ngos"]]
    assert sorted(sent) == ["ngo-false", "ngo-vehicle"]


def test_existing_ngo_exclusion_rules_still_apply(matching, supabase) -> None:
    # An NGO missing usable hours is still excluded, unchanged.
    supabase.seed(
        "ngos",
        [
            _ngo_row("ngo-vehicle", vehicle_available=True),
            _ngo_row(
                "ngo-nohours",
                vehicle_available=True,
                available_from=None,
                available_to=None,
            ),
        ],
    )
    donation_id = _seed_matching_donation(supabase)

    client.post(f"/api/v1/donations/{donation_id}/match")

    sent = [c["ngo_id"] for c in matching.match_bodies[-1]["candidate_ngos"]]
    assert sent == ["ngo-vehicle"]
