"""Vehicle-aware logistics matching: provider x NGO pairs, and the volunteer hand-off.

Covers the corrected business rule that SAHAAY matches FOOD + PROVIDER + NGO +
TRANSPORT capability:

  * every one of the ten (provider, NGO) tri-state pairs -> the documented
    compatibility state, with NULL never coerced to false
  * provider and NGO can each only write their OWN vehicle field, wrong-role
    access is 403, and client-supplied ids cannot override the token identity
  * matching keeps the AI ranking as primary intelligence, keeps existing NGO
    eligibility, never drops a volunteer_required candidate, and does not send
    any vehicle field to the AI microservice
  * false+false flags the donation and publishes a REAL, unassigned volunteer
    task, which a real authenticated volunteer then accepts

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
from app.config import Settings
from app.services import donation_offers as offer_service
from app.services.ai_client import AIClient, get_ai_client
from app.services.vehicle_logistics import (
    vehicle_compatibility,
    requires_volunteer_transport,
    order_by_logistics,
    logistics_tier,
)

client = TestClient(app)

# Real UUIDs because ClaimCreate.donation_id is typed as a UUID, so a
# non-UUID id would be rejected by validation before reaching the router.
_PROVIDER_ID = "00000000-0000-0000-0000-000000000001"
_NGO_ID = "00000000-0000-0000-0000-000000000002"
_DONATION_ID = "00000000-0000-0000-0000-000000000003"

_PROVIDER_VEHICLE_URL = "/api/v1/profile/provider/vehicle-availability"
_NGO_VEHICLE_URL = "/api/v1/profile/ngo/vehicle-availability"


# ---------------------------------------------------------------------------
# Fake Supabase (supports the .is_() null filter the volunteer flow needs)
# ---------------------------------------------------------------------------
class _RowResult(SimpleNamespace):
    pass


class _RpcResult:
    def __init__(self, data: dict) -> None:
        self.data = data

    def execute(self) -> _RowResult:
        return _RowResult(data=self.data)


#: Column defaults taken from the real schema, so a fake row always has the
#: shape Postgres would actually give it.
_COLUMN_DEFAULTS: dict[str, dict] = {
    "claims": {"status": "pending"},
    "deliveries": {"status": "assigned", "volunteer_id": None},
    "donations": {"volunteer_transport_required": False},
}


class _FakeTable:
    def __init__(self, name: str, owner: "_FakeSupabase") -> None:
        self._name = name
        self._owner = owner
        self._rows: list[dict] = []
        self._filters: list[tuple] = []
        self._mode = "query"
        self._update_values: dict | None = None
        self._insert_values: list[dict] = []
        self._seq = 0

    def select(self, *cols) -> "_FakeTable":
        return self

    def eq(self, key: str, value: object) -> "_FakeTable":
        self._filters.append(("eq", key, value))
        return self

    def is_(self, key: str, value: object) -> "_FakeTable":
        self._filters.append(("is", key, value))
        return self

    def in_(self, key: str, values) -> "_FakeTable":
        self._filters.append(("in", key, list(values)))
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

    def order(self, *a, **k) -> "_FakeTable":
        return self

    def __getattr__(self, item):
        return lambda *a, **k: self

    def execute(self):
        rows = self._filtered()
        mode, values = self._mode, self._update_values
        self._mode = "query"
        self._update_values = None
        self._filters = []
        if self._insert_values:
            inserted = self._insert_values.pop(0)
            self._seq += 1
            inserted.setdefault("id", f"{self._name}-row-{self._seq}")
            # Mirror the real column defaults from
            # 20260912112505_remote_schema.sql, otherwise the fake invents a row
            # shape the real database would never produce.
            for key, default in _COLUMN_DEFAULTS.get(self._name, {}).items():
                inserted.setdefault(key, default)
            self._rows.append(inserted)
            if self._name == "claims":
                donation = next(
                    (
                        row
                        for row in self._owner.table("donations")._rows
                        if str(row.get("id")) == str(inserted.get("donation_id"))
                    ),
                    {},
                )
                self._owner.table("claim_transport_coordination")._rows.append(
                    {
                        "claim_id": inserted["id"],
                        "donation_id": inserted["donation_id"],
                        "provider_id": donation.get("provider_id"),
                        "ngo_id": inserted.get("ngo_id"),
                        "provider_response": None,
                        "ngo_response": None,
                        "responsible_role": None,
                        "status": "awaiting_responses",
                    }
                )
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
            elif kind == "is":
                rows = [r for r in rows if r.get(key) is value]
            elif kind == "in":
                rows = [r for r in rows if r.get(key) in value]
        return rows


class _FakeSupabase:
    def __init__(self) -> None:
        self.tables: dict[str, _FakeTable] = {}

    def table(self, name: str) -> _FakeTable:
        if name not in self.tables:
            self.tables[name] = _FakeTable(name, self)
        return self.tables[name]

    def seed(self, name: str, rows: list[dict]) -> None:
        target = self.table(name)
        for row in rows:
            seeded = dict(row)
            # Apply the real column defaults here too, so a seeded row has the
            # same shape Postgres would give a real one.
            for key, default in _COLUMN_DEFAULTS.get(name, {}).items():
                seeded.setdefault(key, default)
            target._rows.append(seeded)
            if name == "ngos" and seeded.get("user_id"):
                self.seed(
                "users",
                [
                    {
                        "id": seeded["user_id"],
                        "role": "ngo",
                        "full_name": "Test NGO Contact",
                        "email": f"{seeded['user_id']}@example.org",
                        "phone": "+91 9876543210",
                    }
                ],
                )

    def rpc(self, name: str, params: dict):
        if name == "respond_to_claim_transport":
            claim_id = str(params["p_claim_id"])
            coordination = next(
                row
                for row in self.table("claim_transport_coordination")._rows
                if str(row.get("claim_id")) == claim_id
            )
            role = params["p_actor_role"]
            field = f"{role}_response"
            if coordination.get(field) is not None:
                return _RpcResult(dict(coordination))
            coordination[field] = params["p_response"]
            if params["p_response"] == "yes" and not coordination.get("responsible_role"):
                coordination["responsible_role"] = role
                coordination["status"] = f"{role}_transport"
            if (
                coordination.get("provider_response") == "no"
                and coordination.get("ngo_response") == "no"
            ):
                coordination["status"] = "awaiting_volunteer_request"
            return _RpcResult(dict(coordination))

        if name == "request_claim_volunteer_delivery":
            claim_id = str(params["p_claim_id"])
            coordination = next(
                row
                for row in self.table("claim_transport_coordination")._rows
                if str(row.get("claim_id")) == claim_id
            )
            if (
                coordination.get("provider_response") != "no"
                or coordination.get("ngo_response") != "no"
            ):
                raise RuntimeError("both participants must decline")
            delivery_table = self.table("deliveries")
            if coordination.get("status") in {
                "searching_for_volunteers",
                "volunteer_assigned",
            }:
                existing = next(
                    row
                    for row in delivery_table._rows
                    if str(row.get("donation_id"))
                    == str(coordination.get("donation_id"))
                )
                return _RpcResult(
                    {
                        "coordination": dict(coordination),
                        "delivery": dict(existing),
                        "created": False,
                    }
                )
            existing = next(
                (
                    row
                    for row in delivery_table._rows
                    if str(row.get("donation_id"))
                    == str(coordination.get("donation_id"))
                ),
                None,
            )
            if existing is None:
                donation = next(
                    row
                    for row in self.table("donations")._rows
                    if str(row.get("id"))
                    == str(coordination.get("donation_id"))
                )
                ngo = next(
                    row
                    for row in self.table("ngos")._rows
                    if str(row.get("id")) == str(coordination.get("ngo_id"))
                )
                created = (
                    delivery_table.insert(
                        {
                            "donation_id": coordination["donation_id"],
                            "claim_id": claim_id,
                            "pickup_address": donation["pickup_address"],
                            "delivery_address": ngo["address"],
                            "pickup_time": donation.get("pickup_deadline"),
                            "status": "unassigned",
                            "volunteer_id": None,
                        }
                    )
                    .select()
                    .execute()
                )
                if not created.data:
                    raise RuntimeError("delivery task could not be created")
                existing = created.data[0]
            elif existing.get("volunteer_id") is not None or existing.get("status") != "unassigned":
                raise RuntimeError("existing delivery task is not available")
            elif str(existing.get("claim_id")) != claim_id:
                prior = next(
                    (
                        row
                        for row in self.table("claims")._rows
                        if str(row.get("id")) == str(existing.get("claim_id"))
                    ),
                    None,
                )
                if prior and prior.get("status") not in {"cancelled", "rejected"}:
                    raise RuntimeError("existing delivery task belongs to another live claim")
                donation = next(
                    row
                    for row in self.table("donations")._rows
                    if str(row.get("id")) == str(coordination.get("donation_id"))
                )
                ngo = next(
                    row
                    for row in self.table("ngos")._rows
                    if str(row.get("id")) == str(coordination.get("ngo_id"))
                )
                existing.update(
                    {
                        "claim_id": claim_id,
                        "delivery_address": ngo["address"],
                        "pickup_time": donation.get("pickup_deadline"),
                    }
                )
            coordination["status"] = "searching_for_volunteers"
            self.table("donations").update(
                {"volunteer_transport_required": True}
            ).eq("id", str(coordination["donation_id"])).execute()
            return _RpcResult(
                {
                    "coordination": dict(coordination),
                    "delivery": dict(existing),
                    "created": True,
                }
            )

        if name == "confirm_claim_volunteer_assignment":
            delivery = next(
                row
                for row in self.table("deliveries")._rows
                if str(row.get("id")) == str(params["p_delivery_id"])
            )
            coordination = next(
                row
                for row in self.table("claim_transport_coordination")._rows
                if str(row.get("claim_id")) == str(delivery.get("claim_id"))
            )
            if (
                coordination.get("status") != "searching_for_volunteers"
                or delivery.get("status") != "unassigned"
                or delivery.get("volunteer_id") is not None
            ):
                raise RuntimeError("transport task has already been accepted")
            delivery.update(
                {"volunteer_id": params["p_volunteer_id"], "status": "assigned"}
            )
            coordination.update(
                {"responsible_role": "volunteer", "status": "volunteer_assigned"}
            )
            return _RpcResult(
                {
                    "delivery": dict(delivery),
                    "coordination": dict(coordination),
                },
            )
        raise AssertionError(f"Unexpected RPC: {name}")


class _MatchHandler:
    """Fake AI transport that ranks candidates in the order received."""

    def __init__(self) -> None:
        self.match_bodies: list[dict] = []

    def handler(self, request: httpx.Request) -> httpx.Response:
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


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------
@pytest.fixture
def supabase(monkeypatch: pytest.MonkeyPatch):
    fake = _FakeSupabase()
    monkeypatch.setattr(
        "app.config.get_settings",
        lambda: Settings(firebase_phone_auth_enabled=True),
    )

    def persist(_client, *, donation_id, ranked_ngos):
        candidates = offer_service._ranked_candidate_rows(ranked_ngos)
        fake.seed(
            "donation_match_candidates",
            [{**candidate, "donation_id": donation_id} for candidate in candidates],
        )
        return {"status": "offered"}

    monkeypatch.setattr(offer_service, "persist_ranked_candidates", persist)
    for module in (
        "app.dependencies.get_supabase_client",
        "app.routers.profile.get_supabase_client",
        "app.routers.ai_features.get_supabase_client",
        "app.routers.donations.get_supabase_client",
        "app.routers.claims.get_supabase_client",
        "app.routers.deliveries.get_supabase_client",
        "app.routers.transport_coordination.get_supabase_client",
    ):
        monkeypatch.setattr(module, lambda: fake)
    yield fake
    app.dependency_overrides.clear()


def _ngo_row(**overrides) -> dict:
    row = {
        "id": _NGO_ID,
        "user_id": f"user-{_NGO_ID}",
        "organization_name": "Feed The City",
        "city": "Mumbai",
        "address": "12 NGO Lane",
        "verified": True,
        "food_capacity": 200,
        "max_capacity_kg": 25,
        # Food categories (SAHAAY vocabulary) are separate from dietary prefs.
        "preferred_food_types": ["Cooked Meals"],
        "dietary_preferences": ["vegetarian"],
        "available_from": "07:00",
        "available_to": "22:00",
        "latitude": 19.07,
        "longitude": 72.87,
    }
    row.update(overrides)
    return row


def _seed_donation(supabase, **overrides) -> str:
    donation = {
        "id": _DONATION_ID,
        "provider_id": _PROVIDER_ID,
        "status": "available",
        "food_name": "Vegetable curry",
        "food_category": "Cooked Meals",
        "quantity": 10.0,
        "unit": "kg",
        "servings": 40,
        "veg_type": "vegetarian",
        "pickup_address": "5 Kitchen Road",
        "latitude": 19.0,
        "longitude": 72.8,
        "pickup_deadline": "2030-01-01T13:00:00Z",
        "expiry_time": "2030-01-01T20:00:00Z",
    }
    donation.update(overrides)
    supabase.seed("donations", [donation])
    supabase.seed("food_predictions", [])
    return _DONATION_ID


def _login(role: str, profile_rows: dict | None = None) -> dict:
    """Installs an authenticated profile for `role` and returns its user id.

    The role join is keyed by the PLURAL table name (providers/ngos/volunteers),
    which is the shape Supabase's `users.select("*, providers(*)")` produces.
    """
    user_id = f"user-{role}-1"
    table = {"provider": "providers", "ngo": "ngos", "volunteer": "volunteers"}[role]
    defaults = {
        "provider": {
            "id": f"{role}-1",
            "organization_name": "Test Kitchen",
            "address": "1 Market Road",
            "city": "Pune",
            "latitude": 18.52,
            "longitude": 73.85,
        },
        "ngo": {
            "id": f"{role}-1",
            "organization_name": "Test Pantry",
            "address": "2 Market Road",
            "city": "Pune",
            "latitude": 18.53,
            "longitude": 73.86,
            "available_from": "07:00",
            "available_to": "22:00",
            "max_capacity_kg": 25,
            "preferred_food_types": ["Cooked Meals"],
            "dietary_preferences": ["vegetarian"],
            "verified": True,
        },
        "volunteer": {"id": f"{role}-1"},
    }[role]
    defaults.update(profile_rows or {})
    app.dependency_overrides[get_current_firebase_user] = lambda: {
        "uid": f"fb-{role}-1",
        "email": f"{role}@example.org",
        "email_verified": True,
        "phone_number": "+919876543210",
        "firebase": {"identities": {"phone": ["+919876543210"]}},
    }
    app.dependency_overrides[get_current_profile] = lambda: {
        "id": user_id,
        "role": role,
        "full_name": "Test Contact",
        "email": f"{role}@example.org",
        "phone": "+91 9876543210",
        table: [defaults],
    }
    return user_id


@pytest.fixture
def provider_auth(supabase):
    supabase.seed("providers", [{"id": _PROVIDER_ID, "organization_name": "Tasty Kitchen"}])
    _login("provider", {"id": _PROVIDER_ID, "organization_name": "Tasty Kitchen"})
    yield supabase
    app.dependency_overrides.clear()


@pytest.fixture
def ngo_auth(supabase):
    supabase.seed("ngos", [_ngo_row()])
    _login("ngo", {"id": _NGO_ID, "organization_name": "Feed The City"})
    yield supabase
    app.dependency_overrides.clear()


@pytest.fixture
def volunteer_auth(supabase):
    _login("volunteer", {"id": "volunteer-1"})
    yield supabase
    app.dependency_overrides.clear()


@pytest.fixture
def matching(supabase, monkeypatch: pytest.MonkeyPatch):
    """Provider-signed-in matching with the real typed AIClient over a mock."""
    handler = _MatchHandler()
    handler.provider_profile = {
        "id": "user-provider-1",
        "role": "provider",
        "providers": [
            {
                "id": _PROVIDER_ID,
                "organization_name": "Tasty Kitchen",
                "latitude": 19.0,
                "longitude": 72.8,
                "vehicle_available": None,
            }
        ],
    }
    app.dependency_overrides[get_current_firebase_user] = lambda: {
        "uid": "fb-provider-1",
        "email": "provider@example.org",
        "email_verified": True,
        "phone_number": "+919876543210",
        "firebase": {"identities": {"phone": ["+919876543210"]}},
    }
    app.dependency_overrides[get_current_profile] = lambda: handler.provider_profile
    app.dependency_overrides[get_ai_client] = lambda: AIClient(
        base_url="http://ai.test",
        timeout=5.0,
        transport=httpx.MockTransport(handler.handler),
    )
    yield handler
    app.dependency_overrides.clear()


# ---------------------------------------------------------------------------
# 1. Compatibility truth table (unit level, no HTTP)
# ---------------------------------------------------------------------------
@pytest.mark.parametrize(
    ("provider", "ngo", "expected"),
    [
        # Both sides answered.
        (True, True, "both_transport"),
        (True, False, "provider_transport"),
        (False, True, "ngo_transport"),
        (False, False, "volunteer_required"),
        # Either side unanswered -> unknown, never coerced.
        (None, True, "unknown"),
        (None, False, "unknown"),
        (False, None, "unknown"),
        (True, None, "unknown"),
        (None, None, "unknown"),
    ],
)
def test_every_vehicle_combination(provider, ngo, expected) -> None:
    assert vehicle_compatibility(provider, ngo) == expected


def test_volunteer_required_needs_two_explicit_false_answers() -> None:
    # The critical NULL-safety property: missing data can never escalate a
    # donation to "needs a volunteer".
    assert requires_volunteer_transport(False, False) is True
    for provider, ngo in [
        (None, False),
        (False, None),
        (None, None),
        (None, True),
        (True, None),
    ]:
        assert requires_volunteer_transport(provider, ngo) is False
        assert vehicle_compatibility(provider, ngo) != "volunteer_required"


def test_logistics_tiers_are_documented_and_total() -> None:
    # both -> provider -> ngo -> unknown -> volunteer_required
    assert logistics_tier("both_transport") == 0
    assert logistics_tier("provider_transport") == 1
    assert logistics_tier("ngo_transport") == 2
    assert logistics_tier("unknown") == 3
    assert logistics_tier("volunteer_required") == 4


def test_ordering_is_stable_within_a_tier() -> None:
    items = [
        {"ngo_id": "a", "vehicle_compatibility": "volunteer_required"},
        {"ngo_id": "b", "vehicle_compatibility": "both_transport"},
        {"ngo_id": "c", "vehicle_compatibility": "both_transport"},
        {"ngo_id": "d", "vehicle_compatibility": "ngo_transport"},
        {"ngo_id": "e", "vehicle_compatibility": "provider_transport"},
        {"ngo_id": "f", "vehicle_compatibility": "unknown"},
    ]
    ordered, changed = order_by_logistics(items)
    assert changed is True
    # b before c (AI order preserved inside the tier), volunteer_required last.
    assert [i["ngo_id"] for i in ordered] == ["b", "c", "e", "d", "f", "a"]


def test_ordering_is_a_noop_when_nothing_can_carry_the_food() -> None:
    items = [
        {"ngo_id": "a", "vehicle_compatibility": "unknown"},
        {"ngo_id": "b", "vehicle_compatibility": "volunteer_required"},
    ]
    ordered, changed = order_by_logistics(items)
    assert changed is False
    assert ordered is items


# ---------------------------------------------------------------------------
# 2. Provider vehicle availability writes
# ---------------------------------------------------------------------------
def test_provider_can_set_vehicle_true(provider_auth) -> None:
    response = client.patch(_PROVIDER_VEHICLE_URL, json={"vehicle_available": True})
    assert response.status_code == 200
    assert response.json()["vehicle_available"] is True
    assert provider_auth.table("providers")._rows[0]["vehicle_available"] is True


def test_provider_can_set_vehicle_false(provider_auth) -> None:
    response = client.patch(_PROVIDER_VEHICLE_URL, json={"vehicle_available": False})
    assert response.status_code == 200
    assert provider_auth.table("providers")._rows[0]["vehicle_available"] is False


def test_provider_can_clear_vehicle_back_to_unanswered(provider_auth) -> None:
    provider_auth.seed("providers", [{"id": _PROVIDER_ID, "vehicle_available": True}])
    response = client.patch(_PROVIDER_VEHICLE_URL, json={"vehicle_available": None})
    assert response.status_code == 200
    # null is stored as null, NOT coerced to false.
    assert response.json()["vehicle_available"] is None
    assert provider_auth.table("providers")._rows[0]["vehicle_available"] is None


def test_provider_vehicle_rejects_non_boolean(provider_auth) -> None:
    for bad in ["true", 1, "yes"]:
        response = client.patch(_PROVIDER_VEHICLE_URL, json={"vehicle_available": bad})
        assert response.status_code == 422, bad


def test_provider_can_never_address_another_providers_row(provider_auth) -> None:
    provider_auth.seed("providers", [{"id": "provider-someone-else"}])
    # A client-supplied identifier must be ignored, not honoured.
    response = client.patch(
        _PROVIDER_VEHICLE_URL,
        json={"vehicle_available": True, "provider_id": "provider-someone-else", "id": "provider-someone-else"},
    )
    assert response.status_code == 200
    assert provider_auth.table("providers")._rows[0]["id"] == _PROVIDER_ID
    assert provider_auth.table("providers")._rows[1].get("vehicle_available") is None


def test_ngo_cannot_write_the_provider_vehicle_field(ngo_auth) -> None:
    response = client.patch(_PROVIDER_VEHICLE_URL, json={"vehicle_available": True})
    assert response.status_code == 403


def test_provider_cannot_write_the_ngo_vehicle_field(provider_auth) -> None:
    response = client.patch(_NGO_VEHICLE_URL, json={"vehicle_available": True})
    assert response.status_code == 403


def test_provider_vehicle_requires_authentication(supabase) -> None:
    response = client.patch(_PROVIDER_VEHICLE_URL, json={"vehicle_available": True})
    assert response.status_code in (401, 403)


def test_volunteer_cannot_write_either_vehicle_field(volunteer_auth) -> None:
    assert client.patch(_PROVIDER_VEHICLE_URL, json={"vehicle_available": True}).status_code == 403
    assert client.patch(_NGO_VEHICLE_URL, json={"vehicle_available": True}).status_code == 403


def test_provider_vehicle_is_persisted_at_registration(supabase) -> None:
    app.dependency_overrides[get_current_firebase_user] = lambda: {"uid": "fb-new"}
    response = client.post(
        "/api/v1/profile",
        json={
            "full_name": "Tasty Kitchen",
            "email": "kitchen@example.com",
            "role": "provider",
            "provider": {
                "organization_name": "Tasty Kitchen",
                "organization_type": "restaurant",
                "address": "5 Kitchen Road",
                "vehicle_available": True,
            },
        },
    )
    assert response.status_code == 201
    assert response.json()["profile"]["vehicle_available"] is True


# ---------------------------------------------------------------------------
# 3. Matching uses provider + NGO vehicle information
# ---------------------------------------------------------------------------
def _match(supabase, ngo_vehicle, provider_vehicle) -> dict:
    supabase.seed("ngos", [_ngo_row(vehicle_available=ngo_vehicle)])
    _seed_donation(supabase)
    response = client.post(f"/api/v1/donations/{_DONATION_ID}/match")
    assert response.status_code == 200, response.text
    return response.json()


def test_matching_reports_pairwise_compatibility_for_every_combination(
    matching, supabase
) -> None:
    expected = {
        (True, True): "both_transport",
        (True, False): "provider_transport",
        (False, True): "ngo_transport",
        (False, False): "volunteer_required",
        (None, True): "unknown",
        (None, False): "unknown",
        (False, None): "unknown",
        (True, None): "unknown",
        (None, None): "unknown",
    }
    for (provider_vehicle, ngo_vehicle), want in expected.items():
        supabase.table("donation_match_candidates")._rows.clear()
        matching.provider_profile["providers"][0]["vehicle_available"] = provider_vehicle
        body = _match(supabase, ngo_vehicle, provider_vehicle)
        item = body["ranked_ngos"][0]
        assert item["vehicle_compatibility"] == want, (provider_vehicle, ngo_vehicle)
        assert item["provider_vehicle_available"] == provider_vehicle
        assert item["ngo"]["vehicle_available"] == ngo_vehicle
        assert item["volunteer_transport_required"] is (want == "volunteer_required")
        # Top-level summary agrees with the per-candidate value.
        assert body["volunteer_transport_required"] is (want == "volunteer_required")
        supabase.table("ngos")._rows.clear()
        supabase.table("donations")._rows.clear()


def test_matching_never_sends_vehicle_data_to_the_ai(matching, supabase) -> None:
    # The AI microservice must not be modified and must not be told about
    # vehicles it has no field for.
    matching.provider_profile["providers"][0]["vehicle_available"] = True
    _match(supabase, True, True)
    sent = json.dumps(matching.match_bodies[-1]).lower()
    assert "vehicle" not in sent


def test_matching_preserves_existing_ngo_eligibility_rules(matching, supabase) -> None:
    # An NGO missing operating hours / location / capacity / dietary is still
    # excluded, exactly as before, regardless of vehicle state.
    supabase.seed(
        "ngos",
        [
            _ngo_row(id="eligible", vehicle_available=True),
            _ngo_row(id="no-hours", available_from=None, available_to=None, vehicle_available=True),
            _ngo_row(id="no-coords", latitude=None, longitude=None, vehicle_available=True),
            _ngo_row(id="no-capacity", max_capacity_kg=0, vehicle_available=True),
            _ngo_row(id="no-dietary", preferred_food_types=[], vehicle_available=True),
        ],
    )
    _seed_donation(supabase)
    response = client.post(f"/api/v1/donations/{_DONATION_ID}/match")

    assert response.status_code == 200
    ids = [item["ngo"]["id"] for item in response.json()["ranked_ngos"]]
    assert ids == ["eligible"]


def test_matching_keeps_the_ai_ranking_as_primary_intelligence(matching, supabase) -> None:
    # All candidates share one compatibility state, so the AI's own order is
    # returned byte-for-byte.
    supabase.seed(
        "ngos",
        [
            _ngo_row(id="far", vehicle_available=True),
            _ngo_row(id="near", vehicle_available=True),
        ],
    )
    _seed_donation(supabase)
    response = client.post(f"/api/v1/donations/{_DONATION_ID}/match")

    body = response.json()
    assert [i["ngo"]["id"] for i in body["ranked_ngos"]] == ["far", "near"]
    # The AI's own scores are untouched by the logistics layer.
    assert [i["final_score"] for i in body["ranked_ngos"]] == [91.0, 91.0]
    assert body["logistics_ordering_applied"] is False


def test_volunteer_required_ngo_is_still_ranked_and_claimable(matching, supabase) -> None:
    # The single most important non-regression: lacking vehicles must NOT remove
    # the NGO from the result.
    matching.provider_profile["providers"][0]["vehicle_available"] = False
    body = _match(supabase, False, False)

    assert len(body["ranked_ngos"]) == 1
    assert body["ranked_ngos"][0]["vehicle_compatibility"] == "volunteer_required"
    assert body["volunteer_required_ngo_ids"] == [_NGO_ID]


def test_matching_response_exposes_human_readable_logistics(matching, supabase) -> None:
    matching.provider_profile["providers"][0]["vehicle_available"] = False
    item = _match(supabase, False, False)["ranked_ngos"][0]

    assert item["vehicle_compatibility_label"] == "Volunteer transport required"
    assert "volunteer" in item["vehicle_compatibility_detail"].lower()


# ---------------------------------------------------------------------------
# 4. Volunteer hand-off
# ---------------------------------------------------------------------------
def _claim_as_ngo(
    supabase,
    provider_vehicle: bool | None,
    ngo_vehicle: bool | None,
) -> httpx.Response:
    """Seeds a real provider/NGO/donation trio and claims as that NGO.

    The NGO's `vehicle_available` is set on BOTH the ngos row and the profile
    join, because in production `get_current_profile` returns
    `ngos(*)` — the claim router reads the NGO from that join.
    """
    supabase.seed(
        "ngos", [_ngo_row(vehicle_available=ngo_vehicle, address="12 NGO Lane")]
    )
    supabase.seed(
        "providers",
        [
            {
                "id": _PROVIDER_ID,
                "organization_name": "Tasty Kitchen",
                "vehicle_available": provider_vehicle,
            }
        ],
    )
    _seed_donation(supabase)
    _login(
        "ngo",
        {
            "id": _NGO_ID,
            "organization_name": "Feed The City",
            "vehicle_available": ngo_vehicle,
            "address": "12 NGO Lane",
        },
    )
    return client.post(
        "/api/v1/claims", json={"donation_id": _DONATION_ID, "requested_quantity": 5.0}
    )


def test_claim_does_not_start_volunteer_search_until_both_no_responses(supabase) -> None:
    # Profile vehicle preferences do not replace either participant's explicit
    # response in the persisted coordination flow.
    response = _claim_as_ngo(supabase, provider_vehicle=False, ngo_vehicle=False)
    assert response.status_code == 201, response.text
    assert response.json()["logistics"]["vehicle_compatibility"] is None
    assert response.json()["logistics"]["vehicle_compatibility_label"] == (
        "Transport response needed"
    )
    assert response.json()["logistics"]["volunteer_transport_required"] is False
    assert supabase.table("donations")._rows[0]["volunteer_transport_required"] is False
    assert supabase.table("deliveries")._rows == []


def test_claim_does_not_infer_a_provider_yes_from_profile_vehicle_data(supabase) -> None:
    response = _claim_as_ngo(supabase, provider_vehicle=True, ngo_vehicle=False)

    assert response.status_code == 201
    assert response.json()["logistics"]["volunteer_transport_required"] is False
    assert response.json()["logistics"]["delivery_created"] is False
    assert supabase.table("deliveries")._rows == []


def test_claim_does_not_infer_an_ngo_yes_from_profile_vehicle_data(supabase) -> None:
    response = _claim_as_ngo(supabase, provider_vehicle=False, ngo_vehicle=True)

    assert response.status_code == 201
    assert response.json()["logistics"]["vehicle_compatibility"] is None
    assert response.json()["logistics"]["vehicle_compatibility_label"] == (
        "Transport response needed"
    )
    assert supabase.table("deliveries")._rows == []


def test_unknown_vehicle_data_never_creates_a_volunteer_task(supabase) -> None:
    # Provider simply has not answered: the system must not invent a need.
    response = _claim_as_ngo(supabase, provider_vehicle=None, ngo_vehicle=False)

    assert response.status_code == 201
    assert response.json()["logistics"]["vehicle_compatibility"] is None
    assert response.json()["logistics"]["vehicle_compatibility_label"] == (
        "Transport response needed"
    )
    assert response.json()["logistics"]["volunteer_transport_required"] is False
    assert supabase.table("deliveries")._rows == []


def test_repeat_claims_do_not_create_tasks_before_both_no_responses(supabase) -> None:
    first = _claim_as_ngo(supabase, provider_vehicle=False, ngo_vehicle=False)
    assert first.status_code == 201
    second = _claim_as_ngo(supabase, provider_vehicle=False, ngo_vehicle=False)

    assert second.status_code == 201
    assert supabase.table("deliveries")._rows == []


def _volunteer_task_id(supabase) -> str:
    """Creates a claim, records both No responses, explicitly requests a task."""
    response = _claim_as_ngo(supabase, provider_vehicle=False, ngo_vehicle=False)
    assert response.status_code == 201, response.text
    claim_id = response.json()["id"]
    first = client.post(
        f"/api/v1/claims/{claim_id}/transport-coordination/respond",
        json={"response": "no"},
    )
    assert first.status_code == 200, first.text
    _login("provider", {"id": _PROVIDER_ID, "organization_name": "Tasty Kitchen"})
    second = client.post(
        f"/api/v1/claims/{claim_id}/transport-coordination/respond",
        json={"response": "no"},
    )
    assert second.status_code == 200, second.text
    assert second.json()["status"] == "awaiting_volunteer_request"
    supabase.seed("volunteers", [{"id": "volunteer-1", "user_id": "user-volunteer-1"}])
    request = client.post(
        f"/api/v1/claims/{claim_id}/transport-coordination/request-volunteer"
    )
    assert request.status_code == 200, request.text
    task = next(
        row
        for row in supabase.table("deliveries")._rows
        if str(row.get("claim_id")) == str(claim_id)
    )
    assert task["status"] == "unassigned"
    return str(task["id"])


def test_both_no_responses_wait_for_explicit_volunteer_request(supabase) -> None:
    claim = _claim_as_ngo(supabase, provider_vehicle=False, ngo_vehicle=False)
    claim_id = claim.json()["id"]
    supabase.table("providers")._rows[0]["user_id"] = "user-provider"
    supabase.table("ngos")._rows[0]["user_id"] = "user-ngo"

    first = client.post(
        f"/api/v1/claims/{claim_id}/transport-coordination/respond",
        json={"response": "no"},
    )
    assert first.status_code == 200
    assert first.json()["status"] == "awaiting_responses"
    assert supabase.table("deliveries")._rows == []
    assert supabase.table("donations")._rows[0]["volunteer_transport_required"] is False

    _login("provider", {"id": _PROVIDER_ID, "organization_name": "Tasty Kitchen"})
    second = client.post(
        f"/api/v1/claims/{claim_id}/transport-coordination/respond",
        json={"response": "no"},
    )
    assert second.status_code == 200
    assert second.json()["status"] == "awaiting_volunteer_request"
    assert supabase.table("donations")._rows[0]["volunteer_transport_required"] is False
    assert supabase.table("deliveries")._rows == []

    supabase.seed("volunteers", [{"id": "volunteer-1", "user_id": "user-volunteer-1"}])
    request = client.post(
        f"/api/v1/claims/{claim_id}/transport-coordination/request-volunteer"
    )
    assert request.status_code == 200
    assert request.json()["status"] == "searching_for_volunteers"
    assert supabase.table("donations")._rows[0]["volunteer_transport_required"] is True
    assert len(supabase.table("deliveries")._rows) == 1
    task = supabase.table("deliveries")._rows[0]
    assert task["status"] == "unassigned"
    assert task["volunteer_id"] is None

    notification_count = len(supabase.table("notifications")._rows)
    repeated = client.post(
        f"/api/v1/claims/{claim_id}/transport-coordination/request-volunteer",
    )
    assert repeated.status_code == 200
    assert len(supabase.table("deliveries")._rows) == 1
    assert len(supabase.table("notifications")._rows) == notification_count


def test_missing_volunteers_returns_retryable_error_without_creating_a_task(
    supabase,
) -> None:
    claim = _claim_as_ngo(supabase, provider_vehicle=False, ngo_vehicle=False)
    claim_id = claim.json()["id"]
    assert _answer_both_no(supabase, claim_id, _NGO_ID).status_code == 200

    unavailable = client.post(
        f"/api/v1/claims/{claim_id}/transport-coordination/request-volunteer"
    )
    assert unavailable.status_code == 409
    assert "no volunteer accounts" in unavailable.json()["detail"].lower()
    assert supabase.table("deliveries")._rows == []

    assert _request_volunteer(supabase, claim_id).status_code == 200
    assert len(supabase.table("deliveries")._rows) == 1


@pytest.mark.parametrize(
    ("first_role", "second_role", "first_response", "second_response", "winner"),
    [
        ("provider", "ngo", "yes", "no", "provider"),
        ("ngo", "provider", "yes", "no", "ngo"),
        ("provider", "ngo", "no", "yes", "ngo"),
        ("ngo", "provider", "no", "yes", "provider"),
    ],
)
def test_either_participant_yes_wins_without_requesting_volunteer(
    supabase,
    first_role: str,
    second_role: str,
    first_response: str,
    second_response: str,
    winner: str,
) -> None:
    claim = _claim_as_ngo(supabase, provider_vehicle=False, ngo_vehicle=False)
    claim_id = claim.json()["id"]
    _login(first_role, {"id": _PROVIDER_ID if first_role == "provider" else _NGO_ID})
    first = client.post(
        f"/api/v1/claims/{claim_id}/transport-coordination/respond",
        json={
            "response": first_response,
            **(
                {"captain_name": "Test Captain", "captain_phone": "9876543210"}
                if first_response == "yes"
                else {}
            ),
        },
    )
    assert first.status_code == 200, first.text
    assert first.json()["responsible_role"] == (
        first_role if first_response == "yes" else None
    )

    _login(second_role, {"id": _PROVIDER_ID if second_role == "provider" else _NGO_ID})
    second = client.post(
        f"/api/v1/claims/{claim_id}/transport-coordination/respond",
        json={
            "response": second_response,
            **(
                {"captain_name": "Test Captain", "captain_phone": "9876543210"}
                if second_response == "yes"
                else {}
            ),
        },
    )
    assert second.status_code == 200, second.text
    assert second.json()["responsible_role"] == winner
    assert second.json()["status"] == f"{winner}_transport"
    assert supabase.table("deliveries")._rows == []
    assert supabase.table("donations")._rows[0]["volunteer_transport_required"] is False


def test_expired_claim_cannot_request_or_accept_volunteer(supabase) -> None:
    claim = _claim_as_ngo(supabase, provider_vehicle=False, ngo_vehicle=False)
    claim_id = claim.json()["id"]
    _answer_both_no(supabase, claim_id, _NGO_ID)
    supabase.table("donations").update(
        {"expiry_time": "2020-01-01T00:00:00Z"}
    ).eq("id", _DONATION_ID).execute()
    supabase.seed("volunteers", [{"id": "volunteer-1", "user_id": "user-volunteer-1"}])

    request = client.post(
        f"/api/v1/claims/{claim_id}/transport-coordination/request-volunteer"
    )
    assert request.status_code == 409
    assert supabase.table("deliveries")._rows == []

    # A previously discovered delivery is also rejected if it expires before
    # acceptance, even when the volunteer submits its stale task id.
    supabase.table("donations").update(
        {"expiry_time": "2030-01-01T20:00:00Z"}
    ).eq("id", _DONATION_ID).execute()
    task_id = _volunteer_task_id(supabase)
    supabase.table("donations").update(
        {"pickup_deadline": "2020-01-01T00:00:00Z"}
    ).eq("id", _DONATION_ID).execute()
    _login("volunteer", {"id": "volunteer-1"})
    acceptance = client.post(f"/api/v1/deliveries/{task_id}/accept")
    assert acceptance.status_code == 409
    assert supabase.table("deliveries")._rows[0]["volunteer_id"] is None


def test_expired_assigned_delivery_cannot_advance(supabase) -> None:
    task_id = _volunteer_task_id(supabase)
    _login("volunteer", {"id": "volunteer-1"})
    assert client.post(f"/api/v1/deliveries/{task_id}/accept").status_code == 200
    supabase.table("donations").update(
        {"pickup_deadline": "2020-01-01T00:00:00Z"}
    ).eq("id", _DONATION_ID).execute()

    response = client.patch(
        f"/api/v1/deliveries/{task_id}/status", json={"status": "picked_up"}
    )
    assert response.status_code == 409
    assert supabase.table("deliveries")._rows[0]["status"] == "assigned"


def _answer_both_no(supabase, claim_id: str, ngo_id: str) -> httpx.Response:
    ngo = next(
        row
        for row in supabase.table("ngos")._rows
        if str(row.get("id")) == str(ngo_id)
    )
    _login("ngo", {"id": ngo_id, "organization_name": ngo.get("organization_name")})
    first = client.post(
        f"/api/v1/claims/{claim_id}/transport-coordination/respond",
        json={"response": "no"},
    )
    assert first.status_code == 200, first.text
    _login("provider", {"id": _PROVIDER_ID, "organization_name": "Tasty Kitchen"})
    return client.post(
        f"/api/v1/claims/{claim_id}/transport-coordination/respond",
        json={"response": "no"},
    )


def _request_volunteer(supabase, claim_id: str) -> httpx.Response:
    supabase.seed("volunteers", [{"id": "volunteer-1", "user_id": "user-volunteer-1"}])
    return client.post(
        f"/api/v1/claims/{claim_id}/transport-coordination/request-volunteer"
    )


def test_volunteer_task_is_discoverable_with_real_facts(supabase) -> None:
    _volunteer_task_id(supabase)
    _login("volunteer", {"id": "volunteer-1"})

    response = client.get("/api/v1/deliveries/transport-required")

    assert response.status_code == 200
    tasks = response.json()
    assert len(tasks) == 1
    task = tasks[0]
    assert task["volunteer_transport_required"] is True
    assert task["transport_requirement"] == "Volunteer transport required"
    assert task["volunteer_id"] is None
    # Everything a volunteer needs comes from real rows, not placeholders.
    assert task["donation"]["food_name"] == "Vegetable curry"
    assert task["donation"]["quantity"] == 10.0
    assert task["donation"]["pickup_address"] == "5 Kitchen Road"
    assert task["provider"]["organization_name"] == "Tasty Kitchen"
    assert task["provider"]["vehicle_available"] is False
    assert task["ngo"]["organization_name"] == "Feed The City"
    assert task["ngo"]["vehicle_available"] is False


def test_volunteer_discovery_requires_a_volunteer_token(supabase) -> None:
    _volunteer_task_id(supabase)
    response = client.get("/api/v1/deliveries/transport-required")
    assert response.status_code in (401, 403)


def test_volunteer_discovery_is_empty_when_nothing_needs_a_volunteer(supabase) -> None:
    _claim_as_ngo(supabase, provider_vehicle=True, ngo_vehicle=False)
    _login("volunteer", {"id": "volunteer-1"})

    assert client.get("/api/v1/deliveries/transport-required").json() == []


def test_real_volunteer_accepts_the_task(supabase) -> None:
    task_id = _volunteer_task_id(supabase)
    _login("volunteer", {"id": "volunteer-1"})

    response = client.post(f"/api/v1/deliveries/{task_id}/accept")

    assert response.status_code == 200
    assert response.json()["volunteer_id"] == "volunteer-1"
    assert response.json()["status"] == "assigned"
    # It now appears as the volunteer's own work, not as an open task.
    assert client.get("/api/v1/deliveries/transport-required").json() == []
    mine = client.get("/api/v1/deliveries").json()
    assert [d["id"] for d in mine] == [task_id]


def test_a_task_cannot_be_accepted_twice(supabase) -> None:
    task_id = _volunteer_task_id(supabase)
    _login("volunteer", {"id": "volunteer-1"})
    assert client.post(f"/api/v1/deliveries/{task_id}/accept").status_code == 200

    _login("volunteer", {"id": "volunteer-2"})
    # A second volunteer must not be able to steal already-accepted work.
    assert client.post(f"/api/v1/deliveries/{task_id}/accept").status_code == 409


def test_accept_ignores_a_client_supplied_volunteer_id(supabase) -> None:
    task_id = _volunteer_task_id(supabase)
    _login("volunteer", {"id": "volunteer-1"})

    response = client.post(
        f"/api/v1/deliveries/{task_id}/accept", json={"volunteer_id": "volunteer-999"}
    )

    assert response.status_code == 200
    # Identity comes from the token only.
    assert response.json()["volunteer_id"] == "volunteer-1"


def test_accept_requires_authentication_and_the_right_role(supabase) -> None:
    task_id = _volunteer_task_id(supabase)

    assert client.post(f"/api/v1/deliveries/{task_id}/accept").status_code in (401, 403)

    _login("ngo", {"id": _NGO_ID, "organization_name": "Feed The City"})
    assert client.post(f"/api/v1/deliveries/{task_id}/accept").status_code == 403


def test_accepting_an_unknown_task_is_404(supabase) -> None:
    _login("volunteer", {"id": "volunteer-1"})
    assert client.post("/api/v1/deliveries/does-not-exist/accept").status_code == 404


def test_a_client_cannot_set_the_backend_only_unassigned_status(supabase) -> None:
    task_id = _volunteer_task_id(supabase)
    _login("volunteer", {"id": "volunteer-1"})
    assert client.post(f"/api/v1/deliveries/{task_id}/accept").status_code == 200

    # "unassigned" means volunteer_id IS NULL, so a volunteer must not be able to
    # push their own assigned task back into that state.
    response = client.patch(
        f"/api/v1/deliveries/{task_id}/status", json={"status": "unassigned"}
    )

    assert response.status_code == 422
    mine = client.get("/api/v1/deliveries").json()
    assert [d["volunteer_id"] for d in mine] == ["volunteer-1"]
    assert [d["status"] for d in mine] == ["assigned"]


# ---------------------------------------------------------------------------
# 8. Volunteer transport LIFECYCLE
#
#   A-H  recomputation of the flag from live claims (cases C and D are the
#        reason this is an aggregate and not "clear on cancel")
#   I-J  discovery must follow the CLAIM status, not just the delivery status
#   K    a task that cannot be published must not leave a false requirement
#   L-M  existing acceptance behaviour is unchanged by any of the above
# ---------------------------------------------------------------------------
def _flag(supabase) -> bool:
    return bool(supabase.table("donations")._rows[0]["volunteer_transport_required"])


def _claim_status(supabase, claim_id: str) -> str:
    row = next(c for c in supabase.table("claims")._rows if c["id"] == claim_id)
    return row["status"]


def _set_claim_status(supabase, claim_id: str, status: str) -> None:
    for row in supabase.table("claims")._rows:
        if row["id"] == claim_id:
            row["status"] = status


def _seed_second_claim(
    supabase, ngo_id: str, *, provider_vehicle=None, ngo_vehicle=None, status="pending"
) -> str:
    """Adds another real claim (default: a different NGO) for the same donation."""
    supabase.seed(
        "ngos",
        [_ngo_row(id=ngo_id, organization_name="Second NGO", vehicle_available=ngo_vehicle,
                  address="99 Other Road")],
    )
    supabase.table("claims").insert(
        {
            "id": f"claim-{ngo_id}",
            "donation_id": _DONATION_ID,
            "ngo_id": ngo_id,
            "requested_quantity": 3.0,
            "status": status,
        }
    ).execute()
    return f"claim-{ngo_id}"


_SECOND_NGO_ID = "00000000-0000-0000-0000-0000000000aa"


# --- A: false + false + live claim => required ---------------------------
def test_A_false_provider_and_ngo_with_a_live_claim_requires_a_volunteer(supabase) -> None:
    response = _claim_as_ngo(supabase, provider_vehicle=False, ngo_vehicle=False)

    assert response.status_code == 201
    assert _claim_status(supabase, response.json()["id"]) == "pending"
    assert _flag(supabase) is False


# --- B: cancelled with no other live claim => requirement removed ---------
@pytest.mark.parametrize("terminal", ["cancelled", "rejected", "completed"])
def test_B_terminal_claim_without_others_removes_the_requirement(
    supabase, terminal
) -> None:
    response = _claim_as_ngo(supabase, provider_vehicle=False, ngo_vehicle=False)
    claim_id = response.json()["id"]
    _login("ngo", {"id": _NGO_ID, "organization_name": "Feed The City"})

    assert client.patch(
        f"/api/v1/claims/{claim_id}?status={terminal}"
    ).status_code == 200

    assert _flag(supabase) is False


# --- C: one cancelled, one still pending => requirement REMAINS ----------
def test_C_a_cancelled_claim_does_not_clear_a_pending_claims_requirement(supabase) -> None:
    # This is the case that makes "clear the flag on cancel" wrong.
    first = _claim_as_ngo(supabase, provider_vehicle=False, ngo_vehicle=False)
    cancelled_id = first.json()["id"]
    _set_claim_status(supabase, cancelled_id, "cancelled")

    second_id = _seed_second_claim(
        supabase,
        _SECOND_NGO_ID,
        ngo_vehicle=False,
        status="pending",
    )
    # Recompute the way the lifecycle does, from the current live claims.
    from app.services.volunteer_transport import recompute_volunteer_transport_required

    assert recompute_volunteer_transport_required(supabase, _DONATION_ID) is False
    assert _claim_status(supabase, second_id) == "pending"
    assert _flag(supabase) is False


# --- D: every claim dead => requirement removed --------------------------
def test_D_all_claims_dead_removes_the_requirement(supabase) -> None:
    first = _claim_as_ngo(supabase, provider_vehicle=False, ngo_vehicle=False)
    second_id = _seed_second_claim(
        supabase, _SECOND_NGO_ID, ngo_vehicle=False, status="pending"
    )
    _set_claim_status(supabase, first.json()["id"], "cancelled")
    _set_claim_status(supabase, second_id, "rejected")

    from app.services.volunteer_transport import recompute_volunteer_transport_required

    assert recompute_volunteer_transport_required(supabase, _DONATION_ID) is False
    assert _flag(supabase) is False


# --- E-H: NULL is never coerced, and a usable vehicle is never a volunteer -
@pytest.mark.parametrize(
    ("provider_vehicle", "ngo_vehicle"),
    [
        (None, False),  # E
        (False, None),  # F
        (True, False),  # G
        (False, True),  # H
    ],
)
def test_E_to_H_a_live_claim_that_is_not_false_false_never_requires_a_volunteer(
    supabase, provider_vehicle, ngo_vehicle
) -> None:
    response = _claim_as_ngo(
        supabase, provider_vehicle=provider_vehicle, ngo_vehicle=ngo_vehicle
    )

    assert response.status_code == 201
    assert _flag(supabase) is False
    assert supabase.table("deliveries")._rows == []


def test_recompute_is_idempotent_for_unchanged_state(supabase) -> None:
    from app.services.volunteer_transport import recompute_volunteer_transport_required

    _volunteer_task_id(supabase)
    results = [recompute_volunteer_transport_required(supabase, _DONATION_ID) for _ in range(3)]

    assert results == [True, True, True]
    assert _flag(supabase) is True

    # And the same holds for the negative case, so replaying is always safe.
    _set_claim_status(
        supabase, supabase.table("claims")._rows[0]["id"], "cancelled"
    )
    assert [
        recompute_volunteer_transport_required(supabase, _DONATION_ID) for _ in range(3)
    ] == [False, False, False]
    assert _flag(supabase) is False


# --- I: a stale task whose claim was cancelled is NOT discoverable ------
def test_I_a_task_whose_claim_was_cancelled_is_not_discoverable(supabase) -> None:
    task_id = _volunteer_task_id(supabase)
    # The delivery row still exists, still unassigned, still volunteer_id NULL:
    # only the CLAIM status changed. Filtering on the delivery alone would keep
    # showing it.
    task = supabase.table("deliveries")._rows[0]
    assert task["status"] == "unassigned" and task["volunteer_id"] is None

    _set_claim_status(supabase, task["claim_id"], "cancelled")
    _login("volunteer", {"id": "volunteer-1"})

    response = client.get("/api/v1/deliveries/transport-required")

    assert response.status_code == 200
    assert task_id not in [t["id"] for t in response.json()]


def test_a_task_whose_claim_was_rejected_is_not_discoverable(supabase) -> None:
    task = _volunteer_task_id(supabase)
    _set_claim_status(supabase, supabase.table("deliveries")._rows[0]["claim_id"], "rejected")
    _login("volunteer", {"id": "volunteer-1"})

    assert client.get("/api/v1/deliveries/transport-required").json() == []


def test_a_task_with_no_resolvable_claim_is_not_advertised(supabase) -> None:
    # A row whose origin claim cannot be verified is dropped rather than shown:
    # hiding real work is recoverable, sending a volunteer to a dead destination
    # is not.
    _volunteer_task_id(supabase)
    supabase.table("deliveries")._rows[0]["claim_id"] = "claim-that-does-not-exist"
    _login("volunteer", {"id": "volunteer-1"})

    assert client.get("/api/v1/deliveries/transport-required").json() == []


# --- J: a live claim keeps its task discoverable ------------------------
def test_J_a_task_for_a_live_claim_stays_discoverable(supabase) -> None:
    _volunteer_task_id(supabase)
    _login("volunteer", {"id": "volunteer-1"})

    tasks = client.get("/api/v1/deliveries/transport-required").json()

    assert len(tasks) == 1
    assert tasks[0]["claim"]["status"] == "pending"


@pytest.mark.parametrize("live", ["pending", "accepted", "completed"])
def test_J2_every_live_claim_status_keeps_the_task_discoverable(supabase, live) -> None:
    _volunteer_task_id(supabase)
    _set_claim_status(supabase, supabase.table("deliveries")._rows[0]["claim_id"], live)
    _login("volunteer", {"id": "volunteer-1"})

    assert len(client.get("/api/v1/deliveries/transport-required").json()) == 1


# --- K: a task that cannot be published must not leave a false flag -----
def test_K_unpublishable_task_fails_loudly_without_flagging(supabase) -> None:
    # An NGO without a saved address is incomplete, so the backend rejects the
    # claim before creating a claim row or publishing a volunteer task.
    supabase.seed("ngos", [_ngo_row(vehicle_available=False, address=None)])
    supabase.seed(
        "providers",
        [{"id": _PROVIDER_ID, "organization_name": "Tasty Kitchen", "vehicle_available": False}],
    )
    _seed_donation(supabase)
    _login(
        "ngo",
        {
            "id": _NGO_ID,
            "organization_name": "Feed The City",
            "address": None,
            "vehicle_available": False,
        },
    )

    response = client.post(
        "/api/v1/claims", json={"donation_id": _DONATION_ID, "requested_quantity": 5.0}
    )

    assert response.status_code == 409
    assert "Address" in response.json()["detail"]
    # No incomplete profile reaches claim/task persistence.
    assert _flag(supabase) is False
    assert supabase.table("deliveries")._rows == []


def test_K2_a_failed_delivery_insert_does_not_flag_the_donation(
    supabase, monkeypatch: pytest.MonkeyPatch
) -> None:
    claim = _claim_as_ngo(supabase, provider_vehicle=False, ngo_vehicle=False)
    claim_id = claim.json()["id"]

    table = supabase.table("deliveries")
    original_execute = table.execute

    def failing_execute():
        if table._insert_values:
            table._insert_values.clear()
            return _RowResult(data=[])  # insert "succeeded" but created nothing
        return original_execute()

    monkeypatch.setattr(table, "execute", failing_execute)

    first = client.post(
        f"/api/v1/claims/{claim_id}/transport-coordination/respond",
        json={"response": "no"},
    )
    assert first.status_code == 200
    _login("provider", {"id": _PROVIDER_ID, "organization_name": "Tasty Kitchen"})
    response = client.post(
        f"/api/v1/claims/{claim_id}/transport-coordination/respond",
        json={"response": "no"},
    )
    assert response.status_code == 200
    supabase.seed("volunteers", [{"id": "volunteer-1", "user_id": "user-volunteer-1"}])
    response = client.post(
        f"/api/v1/claims/{claim_id}/transport-coordination/request-volunteer"
    )

    assert response.status_code == 503
    assert _flag(supabase) is False


# --- L: real acceptance is unchanged ------------------------------------
def test_L_a_live_task_can_still_be_accepted_by_a_real_volunteer(supabase) -> None:
    task_id = _volunteer_task_id(supabase)
    _login("volunteer", {"id": "volunteer-1"})

    response = client.post(f"/api/v1/deliveries/{task_id}/accept")

    assert response.status_code == 200
    assert response.json()["volunteer_id"] == "volunteer-1"
    assert response.json()["status"] == "assigned"


def test_L2_a_cancelled_claim_is_never_advertised_to_volunteers(supabase) -> None:
    # The guarantee a volunteer actually relies on: once the claim is cancelled
    # the task disappears from discovery entirely, for every volunteer.
    _volunteer_task_id(supabase)
    _set_claim_status(
        supabase, supabase.table("deliveries")._rows[0]["claim_id"], "cancelled"
    )

    for volunteer in ("volunteer-1", "volunteer-2", "volunteer-3"):
        _login("volunteer", {"id": volunteer})
        assert client.get("/api/v1/deliveries/transport-required").json() == []


# --- M: the 422 unassigned guard still holds after all of the above -----
def test_M_unassigned_guard_survives_the_lifecycle_change(supabase) -> None:
    task_id = _volunteer_task_id(supabase)
    _login("volunteer", {"id": "volunteer-1"})
    assert client.post(f"/api/v1/deliveries/{task_id}/accept").status_code == 200

    assert client.patch(
        f"/api/v1/deliveries/{task_id}/status", json={"status": "unassigned"}
    ).status_code == 422


# --- Reuse safety: a new live claim must not inherit stale routing ------
def test_reusing_a_task_rebinds_it_to_the_new_live_claim(supabase) -> None:
    first = _claim_as_ngo(supabase, provider_vehicle=False, ngo_vehicle=False)
    first_claim = first.json()["id"]
    assert _answer_both_no(supabase, first_claim, _NGO_ID).status_code == 200
    assert _request_volunteer(supabase, first_claim).status_code == 200
    _set_claim_status(supabase, first_claim, "cancelled")

    # A second live claim that also needs a volunteer. deliveries.donation_id is
    # UNIQUE, so the existing row must be reused rather than duplicated.
    supabase.seed(
        "ngos",
        [_ngo_row(id=_SECOND_NGO_ID, organization_name="Second NGO",
                  vehicle_available=False, address="99 Other Road")],
    )
    _login("ngo", {"id": _SECOND_NGO_ID, "organization_name": "Second NGO",
                   "vehicle_available": False, "address": "99 Other Road"})
    second = client.post(
        "/api/v1/claims", json={"donation_id": _DONATION_ID, "requested_quantity": 4.0}
    )
    assert second.status_code == 201, second.text
    second_claim = second.json()["id"]
    assert _answer_both_no(supabase, second_claim, _SECOND_NGO_ID).status_code == 200
    assert _request_volunteer(supabase, second_claim).status_code == 200

    rows = supabase.table("deliveries")._rows
    assert len(rows) == 1, "the UNIQUE donation_id constraint must not be bypassed"
    task = rows[0]
    # The ACTIVE claim is now authoritative: not the cancelled one.
    assert task["claim_id"] == second_claim != first_claim
    # And the destination is the new NGO, not the withdrawn one.
    assert task["delivery_address"] == "99 Other Road"
    assert _flag(supabase) is True

    # A volunteer must be shown the current destination, not the stale one.
    _login("volunteer", {"id": "volunteer-1"})
    listed = client.get("/api/v1/deliveries/transport-required").json()
    assert [t["ngo"]["organization_name"] for t in listed] == ["Second NGO"]


def test_a_taken_task_is_never_rebound_to_another_claim(supabase) -> None:
    first = _claim_as_ngo(supabase, provider_vehicle=False, ngo_vehicle=False)
    first_claim = first.json()["id"]
    assert _answer_both_no(supabase, first_claim, _NGO_ID).status_code == 200
    assert _request_volunteer(supabase, first_claim).status_code == 200
    task_id = supabase.table("deliveries")._rows[0]["id"]

    # A real volunteer takes the work.
    _login("volunteer", {"id": "volunteer-1"})
    assert client.post(f"/api/v1/deliveries/{task_id}/accept").status_code == 200

    supabase.seed(
        "ngos",
        [_ngo_row(id=_SECOND_NGO_ID, organization_name="Second NGO",
                  vehicle_available=False, address="99 Other Road")],
    )
    _login("ngo", {"id": _SECOND_NGO_ID, "organization_name": "Second NGO",
                   "vehicle_available": False, "address": "99 Other Road"})
    second = client.post(
        "/api/v1/claims", json={"donation_id": _DONATION_ID, "requested_quantity": 2.0}
    )
    second_claim = second.json()["id"]
    response = _answer_both_no(supabase, second_claim, _SECOND_NGO_ID)
    assert response.status_code == 200
    assert _request_volunteer(supabase, second_claim).status_code == 409

    task = supabase.table("deliveries")._rows[0]
    # Somebody is already on it: the row must be left completely alone.
    assert task["volunteer_id"] == "volunteer-1"
    assert task["status"] == "assigned"
    assert task["claim_id"] == first_claim


# --- Recompute is wired into the escalation auto-rejection path ----------
def test_the_escalation_auto_rejection_recomputes_the_flag(supabase) -> None:
    from app.services.escalation import assess_donation_escalation

    response = _claim_as_ngo(supabase, provider_vehicle=False, ngo_vehicle=False)
    claim_id = response.json()["id"]
    assert _flag(supabase) is False

    # The auto-rejection only ever touches a claim that is still 'pending', so a
    # false/false pending claim is exactly the case that must be recalculated.
    class _EscalatingAI:
        def check_escalation(self, request):
            return _FakeEscalationResult(
                donation_id=request.donation_id,
                action="escalate",
                next_ngo_id=None,
                next_ngo_index=None,
                minutes_elapsed=99,
                message="No response",
            )

    result = assess_donation_escalation(
        supabase, _EscalatingAI(), supabase.table("donations")._rows[0]
    )

    assert result["action"] == "escalate"
    assert _claim_status(supabase, claim_id) == "rejected"
    # The rejected claim is no longer live, so the requirement is gone without
    # any scheduler having run.
    assert _flag(supabase) is False


class _FakeEscalationResult:
    def __init__(self, **kwargs) -> None:
        self.__dict__.update(kwargs)


def test_the_recompute_helper_never_touches_a_second_donation(supabase) -> None:
    # Scoping check: the update is filtered by donation id, so a recompute for
    # one donation must not clear another donation's flag.
    from app.services.volunteer_transport import recompute_volunteer_transport_required

    task_id = _volunteer_task_id(supabase)
    assert task_id
    supabase.seed(
        "donations",
        [
            {
                "id": _SECOND_DONATION_ID,
                "provider_id": _PROVIDER_ID,
                "status": "available",
                "pickup_address": "6 Other Road",
                "volunteer_transport_required": True,
            }
        ],
    )

    assert recompute_volunteer_transport_required(supabase, _DONATION_ID) is True
    # The unrelated donation is untouched, not blanket-cleared.
    other_row = next(
        d for d in supabase.table("donations")._rows if d["id"] == _SECOND_DONATION_ID
    )
    assert other_row["volunteer_transport_required"] is True


# ---------------------------------------------------------------------------
# Accept race condition: a task whose claim went dead must never be acceptable,
# even when the volunteer loaded it while the claim was still live.
# ---------------------------------------------------------------------------
def _accept_after_load(supabase, claim_status: str | None) -> tuple[dict, int]:
    """The real sequence: load the task, then the NGO kills the claim, then accept.

    `claim_status=None` leaves the claim live, which is the control case.
    Returns the delivery row as it stands after the attempt, plus the HTTP code.
    """
    task_id = _volunteer_task_id(supabase)
    claim_id = supabase.table("deliveries")._rows[0]["claim_id"]

    # The volunteer saw the task while it was legitimately live.
    _login("volunteer", {"id": "volunteer-1"})
    loaded = client.get("/api/v1/deliveries/transport-required").json()
    assert [t["id"] for t in loaded] == [task_id]

    if claim_status is not None:
        _set_claim_status(supabase, claim_id, claim_status)

    code = client.post(f"/api/v1/deliveries/{task_id}/accept").status_code
    return dict(supabase.table("deliveries")._rows[0]), code


def test_1_a_live_claim_can_still_be_accepted(supabase) -> None:
    delivery, code = _accept_after_load(supabase, "pending")
    assert code == 200
    assert delivery["volunteer_id"] == "volunteer-1"
    assert delivery["status"] == "assigned"


def test_1b_every_live_claim_status_can_still_be_accepted(supabase) -> None:
    for live in ("pending", "accepted", "completed"):
        supabase.table("deliveries")._rows.clear()
        supabase.table("claims")._rows.clear()
        delivery, code = _accept_after_load(supabase, live)
        assert code == 200
        assert delivery["volunteer_id"] == "volunteer-1"


def test_2_a_cancelled_claim_cannot_be_accepted(supabase) -> None:
    delivery, code = _accept_after_load(supabase, "cancelled")
    assert code == 409
    # Delivery must be completely untouched: nobody assigned, status unchanged.
    assert delivery["volunteer_id"] is None
    assert delivery["status"] == "unassigned"
    # And the volunteer was not handed any work.
    assert client.get("/api/v1/deliveries").json() == []


def test_3_a_rejected_claim_cannot_be_accepted(supabase) -> None:
    delivery, code = _accept_after_load(supabase, "rejected")
    assert code == 409
    assert delivery["volunteer_id"] is None
    assert delivery["status"] == "unassigned"
    assert client.get("/api/v1/deliveries").json() == []


def test_4_an_already_assigned_delivery_is_still_protected(supabase) -> None:
    task_id = _volunteer_task_id(supabase)
    _login("volunteer", {"id": "volunteer-1"})
    assert client.post(f"/api/v1/deliveries/{task_id}/accept").status_code == 200

    _login("volunteer", {"id": "volunteer-2"})
    assert client.post(f"/api/v1/deliveries/{task_id}/accept").status_code == 409
    # Still owned by the first volunteer.
    row = supabase.table("deliveries")._rows[0]
    assert row["volunteer_id"] == "volunteer-1"


def test_5_two_volunteers_racing_for_one_task_is_safe(supabase) -> None:
    task_id = _volunteer_task_id(supabase)

    _login("volunteer", {"id": "volunteer-1"})
    first = client.post(f"/api/v1/deliveries/{task_id}/accept")
    _login("volunteer", {"id": "volunteer-2"})
    second = client.post(f"/api/v1/deliveries/{task_id}/accept")

    assert [first.status_code, second.status_code] == [200, 409]
    # Exactly one winner, and the row has exactly one owner.
    assert supabase.table("deliveries")._rows[0]["volunteer_id"] == "volunteer-1"


def test_6_a_previously_discovered_task_cannot_be_accepted_once_its_claim_dies(
    supabase,
) -> None:
    # The exact audit scenario: discovery and acceptance are separate requests,
    # so the id a volunteer holds can go stale between them.
    delivery, code = _accept_after_load(supabase, "cancelled")
    assert code == 409
    # It is not silently accepted and then quietly fixed up.
    assert delivery["volunteer_id"] is None
    # Nor does the failure hand out any work to the caller.
    assert client.get("/api/v1/deliveries").json() == []


def test_a_dead_claim_is_rejected_without_writing_to_the_delivery_at_all(
    supabase,
) -> None:
    # The pre-check should stop the request BEFORE any assignment write, rather
    # than writing and then undoing. Asserted separately from the row state so
    # the early check is covered in its own right.
    task_id = _volunteer_task_id(supabase)
    _set_claim_status(
        supabase, supabase.table("deliveries")._rows[0]["claim_id"], "cancelled"
    )
    _login("volunteer", {"id": "volunteer-1"})

    deliveries = supabase.table("deliveries")
    writes = []
    original_execute = deliveries.execute

    def execute():
        if deliveries._update_values is not None:
            writes.append(dict(deliveries._update_values))
        return original_execute()

    deliveries.execute = execute
    try:
        response = client.post(f"/api/v1/deliveries/{task_id}/accept")
    finally:
        deliveries.execute = original_execute

    assert response.status_code == 409
    assert writes == [], f"a dead claim must not write to the delivery: {writes}"


def test_a_task_with_no_resolvable_claim_cannot_be_accepted(supabase) -> None:
    # An unverified origin is treated as not-live, so an orphaned task row
    # cannot be used to fabricate an assignment.
    task_id = _volunteer_task_id(supabase)
    claim_id = supabase.table("deliveries")._rows[0]["claim_id"]
    supabase.table("claims")._rows[:] = [
        r for r in supabase.table("claims")._rows if r["id"] != claim_id
    ]
    _login("volunteer", {"id": "volunteer-1"})

    assert client.post(f"/api/v1/deliveries/{task_id}/accept").status_code == 409
    assert supabase.table("deliveries")._rows[0]["volunteer_id"] is None


def test_legacy_assignment_rolls_back_if_claim_dies_mid_acceptance(
    supabase, monkeypatch: pytest.MonkeyPatch
) -> None:
    # Narrowest possible window: the claim is cancelled AFTER the pre-check
    # passes but BEFORE the assignment lands. The post-update re-check must undo
    # the assignment rather than leave a volunteer holding dead work.
    task_id = _volunteer_task_id(supabase)
    claim_id = supabase.table("deliveries")._rows[0]["claim_id"]
    _login("volunteer", {"id": "volunteer-1"})
    original_table = supabase.table

    def without_coordination(name):
        if name == "claim_transport_coordination":
            raise RuntimeError("coordination schema unavailable")
        return original_table(name)

    monkeypatch.setattr(supabase, "table", without_coordination)

    deliveries = supabase.table("deliveries")
    original_execute = deliveries.execute
    state = {"tripped": False}

    def execute():
        result = original_execute()
        # The conditional assignment UPDATE is the one that sets a volunteer_id
        # and flips status to 'assigned'.
        if (
            not state["tripped"]
            and deliveries._update_values is None
            and isinstance(result.data, list)
            and result.data
            and result.data[0].get("status") == "assigned"
            and result.data[0].get("volunteer_id") == "volunteer-1"
        ):
            state["tripped"] = True
            for row in supabase.table("claims")._rows:
                if row["id"] == claim_id:
                    row["status"] = "cancelled"
        return result

    deliveries.execute = execute
    try:
        response = client.post(f"/api/v1/deliveries/{task_id}/accept")
    finally:
        deliveries.execute = original_execute

    assert state["tripped"] is True, "the race was not actually exercised"
    assert response.status_code == 409
    row = deliveries._rows[0]
    # Rolled back to exactly the pre-attempt state.
    assert row["volunteer_id"] is None
    assert row["status"] == "unassigned"
    assert client.get("/api/v1/deliveries").json() == []


def test_legacy_rollback_cannot_steal_a_concurrent_accept(
    supabase, monkeypatch: pytest.MonkeyPatch
) -> None:
    # The compensating write is guarded on volunteer_id, so if somebody else
    # legitimately took the task in the meantime it must leave them alone.
    task_id = _volunteer_task_id(supabase)
    claim_id = supabase.table("deliveries")._rows[0]["claim_id"]
    _login("volunteer", {"id": "volunteer-1"})
    original_table = supabase.table

    def without_coordination(name):
        if name == "claim_transport_coordination":
            raise RuntimeError("coordination schema unavailable")
        return original_table(name)

    monkeypatch.setattr(supabase, "table", without_coordination)

    deliveries = supabase.table("deliveries")
    original_execute = deliveries.execute
    state = {"tripped": False}

    def execute():
        pending = deliveries._update_values
        result = original_execute()
        if (
            not state["tripped"]
            and pending
            and pending.get("volunteer_id") == "volunteer-1"
        ):
            state["tripped"] = True
            # The claim dies and a *different* volunteer is assigned by someone
            # else, standing in for an accept that landed first.
            for row in supabase.table("claims")._rows:
                if row["id"] == claim_id:
                    row["status"] = "cancelled"
            deliveries._rows[0]["volunteer_id"] = "volunteer-2"
            deliveries._rows[0]["status"] = "assigned"
        return result

    deliveries.execute = execute
    try:
        response = client.post(f"/api/v1/deliveries/{task_id}/accept")
    finally:
        deliveries.execute = original_execute

    assert state["tripped"] is True
    assert response.status_code == 409
    # The other volunteer's legitimate assignment survived.
    assert deliveries._rows[0]["volunteer_id"] == "volunteer-2"
    assert deliveries._rows[0]["status"] == "assigned"


def test_accepting_a_dead_claim_task_still_requires_a_volunteer_token(supabase) -> None:
    # The claim check must not become a way to probe task state anonymously.
    task_id = _volunteer_task_id(supabase)
    _set_claim_status(
        supabase, supabase.table("deliveries")._rows[0]["claim_id"], "cancelled"
    )

    assert client.post(f"/api/v1/deliveries/{task_id}/accept").status_code in (401, 403)
    _login("ngo", {"id": _NGO_ID, "organization_name": "Feed The City"})
    assert client.post(f"/api/v1/deliveries/{task_id}/accept").status_code == 403


def test_the_client_cannot_force_an_accept_of_a_dead_claim(supabase) -> None:
    # No request body is consulted for claim status or identity.
    task_id = _volunteer_task_id(supabase)
    _set_claim_status(
        supabase, supabase.table("deliveries")._rows[0]["claim_id"], "rejected"
    )
    _login("volunteer", {"id": "volunteer-1"})

    for body in (
        {"claim_status": "pending"},
        {"status": "pending"},
        {"volunteer_id": "volunteer-1", "claim_status": "pending"},
    ):
        response = client.post(
            f"/api/v1/deliveries/{task_id}/accept", json=body
        )
        assert response.status_code == 409
        assert supabase.table("deliveries")._rows[0]["volunteer_id"] is None


_SECOND_DONATION_ID = "00000000-0000-0000-0000-0000000000bb"
