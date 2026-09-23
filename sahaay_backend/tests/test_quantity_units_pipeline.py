"""
STEP 4: Quantity/unit semantics end-to-end payload tests.

Proves the rule "servings NEVER silently become kilograms":
  * match_ngos builds DonationInput.quantity_kg ONLY from a real weight unit
    (kg as-is, grams /1000). Serving counts, missing units, and unsupported
    units return explicit insufficient_data and the AI ranking endpoint is
    never called.
  * the acknowledgment PDF generator only states a kg weight when the unit is
    a real weight; otherwise it returns 400.
  * surplus prediction uses the provider-supplied food_prepared_kg /
    food_sold_kg verbatim (never the donation quantity), both-or-neither is
    enforced, and persisted values are unchanged.

Every case asserts the ACTUAL JSON payload that reached the AI service
(recorded via httpx.MockTransport through the REAL typed AIClient).

Mocks (test-only): Supabase -> recording fake; auth -> dependency_overrides;
AI transport -> httpx.MockTransport running the real typed AIClient.
"""

from __future__ import annotations

import json
from datetime import datetime, timedelta, timezone
from types import SimpleNamespace

import httpx
import pytest
from fastapi.testclient import TestClient

from app.dependencies import get_current_profile
from app.main import app
from app.services.ai_client import AIClient, get_ai_client

client_session = TestClient(app)

_PROVIDER_ID = "provider-FAKE-001"


def _provider_profile() -> dict:
    return {
        "id": "user-FAKE-001",
        "role": "provider",
        "providers": [
            {
                "id": _PROVIDER_ID,
                "organization_name": "Tasty Kitchen",
                "latitude": 18.52,
                "longitude": 73.85,
            }
        ],
    }


# ---------------------------------------------------------------------------
# Fake Supabase (recording, filterable, mutable) for the match/ack routes
# ---------------------------------------------------------------------------
class _FakeTable:
    def __init__(self, name: str, rows: list[dict]) -> None:
        self._name = name
        self._rows = rows
        self._filters: list[tuple] = []
        self._single: str | None = None
        self._update_values: dict | None = None

    def select(self, *cols: str) -> "_FakeTable":
        return self

    def eq(self, key: str, value: object) -> "_FakeTable":
        self._filters.append(("eq", key, value))
        return self

    def in_(self, key: str, values: list) -> "_FakeTable":
        self._filters.append(("in", key, values))
        return self

    def maybe_single(self) -> "_FakeTable":
        self._single = "maybe"
        return self

    def single(self) -> "_FakeTable":
        self._single = "single"
        return self

    def __getattr__(self, item):
        return lambda *a, **k: self

    def _filtered(self) -> list[dict]:
        rows = list(self._rows)
        for kind, key, value in self._filters:
            if kind == "eq":
                rows = [r for r in rows if r.get(key) == value]
            elif kind == "in":
                rows = [r for r in rows if r.get(key) in set(value)]
        return rows

    def execute(self):
        rows = self._filtered()
        if self._update_values is not None:
            for row in rows:
                row.update(self._update_values)
            return SimpleNamespace(data=rows[0] if rows else {})
        if self._single == "maybe":
            if not rows:
                return None
            return SimpleNamespace(data=rows[0])
        if self._single == "single":
            return SimpleNamespace(data=rows[0] if rows else {})
        return SimpleNamespace(data=rows)


class _FakeSupabase:
    def __init__(self) -> None:
        self.tables: dict[str, list[dict]] = {}

    def table(self, name: str) -> _FakeTable:
        return _FakeTable(name, self.tables.setdefault(name, []))

    def seed(self, name: str, rows: list[dict]) -> None:
        self.tables.setdefault(name, []).extend(list(rows))


# ---------------------------------------------------------------------------
# AI transport — records every request so payloads can be asserted verbatim
# ---------------------------------------------------------------------------
class _AIHandler:
    def __init__(self) -> None:
        self.requests: list[httpx.Request] = []
        self.ranked_override: list[dict] | None = None

    @property
    def paths_hit(self) -> list[str]:
        return [r.url.path for r in self.requests]

    def _match_request(self, path: str) -> dict:
        return next(
            json.loads(r.content) for r in self.requests if r.url.path == path
        )

    def handler(self, request: httpx.Request) -> httpx.Response:
        self.requests.append(request)
        path = request.url.path
        if path == "/api/v1/reliability/calculate":
            body = json.loads(request.content)
            return httpx.Response(
                200,
                json={
                    "restaurant_id": body["restaurant_id"],
                    "reliability_score": 91.5,
                    "grade": "Excellent",
                    "breakdown": {"completion": 40, "rating": 30, "accepted": 21.5},
                },
            )
        if path == "/api/v1/matching/rank-ngos":
            body = json.loads(request.content)
            candidates = body["candidate_ngos"]
            if self.ranked_override is not None:
                ranked = self.ranked_override
            else:
                ranked = [
                    {
                        "ngo_id": c["ngo_id"],
                        "ngo_name": c["name"],
                        "distance_km": 3.0,
                        "distance_source": "straight_line",
                        "distance_score": 90.0,
                        "quantity_fit_score": 80.0,
                        "dietary_compatibility_score": 100.0,
                        "pickup_time_feasibility_score": 100.0,
                        "restaurant_reliability_score": body["donation"][
                            "restaurant_reliability_score"
                        ],
                        "final_score": 87.5,
                        "rank": i + 1,
                    }
                    for i, c in enumerate(candidates)
                ]
            return httpx.Response(
                200,
                json={
                    "donation_id": body["donation"]["donation_id"],
                    "ranked_ngos": ranked,
                    "weights_used": {},
                },
            )
        if path == "/api/v1/donation/generate-acknowledgment":
            body = json.loads(request.content)
            return httpx.Response(
                200,
                json={
                    "donation_id": body["donation_id"],
                    "pdf_filename": f"acknowledgment_{body['donation_id']}.pdf",
                    "file_path": f"/tmp/acknowledgment_{body['donation_id']}.pdf",
                    "message": "Acknowledgment PDF generated successfully.",
                },
            )
        if path.startswith("/api/v1/donation/download/"):
            return httpx.Response(
                200,
                content=b"%PDF-1.4 fake acknowledgment",
                headers={"content-type": "application/pdf"},
            )
        return httpx.Response(404, json={"detail": "not found"})


# ---------------------------------------------------------------------------
# Fixture
# ---------------------------------------------------------------------------
@pytest.fixture
def ctx(monkeypatch: pytest.MonkeyPatch):
    fake = _FakeSupabase()
    monkeypatch.setattr("app.routers.ai_features.get_supabase_client", lambda: fake)
    ai = _AIHandler()
    app.dependency_overrides[get_current_profile] = lambda: _provider_profile()
    app.dependency_overrides[get_ai_client] = lambda: AIClient(
        base_url="http://ai.test",
        timeout=5.0,
        transport=httpx.MockTransport(ai.handler),
    )
    yield SimpleNamespace(fake=fake, ai=ai)
    app.dependency_overrides.clear()


def _donation(**overrides) -> dict:
    future = (datetime.now(timezone.utc) + timedelta(days=1)).isoformat()
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
        "expiry_time": future,
        "latitude": 18.52,
        "longitude": 73.85,
    }
    row.update(overrides)
    return row


def _ngo(ngo_id: str = "ngo-1", **overrides) -> dict:
    row = {
        "id": ngo_id,
        "organization_name": f"NGO {ngo_id}",
        "city": "Pune",
        "address": "12 NGO Road",
        "phone": "+91-1234567890",
        "latitude": 18.53,
        "longitude": 73.86,
        "food_capacity": 50,
        "preferred_food_types": ["vegetarian", "vegan"],
        "verified": True,
        "available_from": "07:00",
        "available_to": "22:00",
    }
    row.update(overrides)
    return row


# ===========================================================================
# REQUIRED CASE: 10 servings NEVER becomes quantity_kg = 10
# ===========================================================================
def test_match_10_servings_never_sent_as_kg(ctx) -> None:
    ctx.fake.seed("donations", [_donation(quantity=10.0, unit="servings")])
    ctx.fake.seed("ngos", [_ngo(), _ngo("ngo-2")])

    response = client_session.post("/api/v1/donations/don-1/match")

    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "insufficient_data"
    assert "servings" in body["reason"]
    assert "/api/v1/matching/rank-ngos" not in ctx.ai.paths_hit
    assert "/api/v1/reliability/calculate" not in ctx.ai.paths_hit


# ===========================================================================
# REQUIRED CASE: matching with kg sends the exact kilogram payload
# ===========================================================================
@pytest.mark.parametrize("quantity,expected_kg", [(10.0, 10.0), (10.5, 10.5)])
def test_match_kg_donation_sends_exact_kg(ctx, quantity, expected_kg) -> None:
    ctx.fake.seed("donations", [_donation(quantity=quantity, unit="kg")])
    ctx.fake.seed("ngos", [_ngo(), _ngo("ngo-2")])

    response = client_session.post("/api/v1/donations/don-1/match")

    assert response.status_code == 200
    assert response.json()["status"] == "ok"
    payload = ctx.ai._match_request("/api/v1/matching/rank-ngos")
    assert payload["donation"]["quantity_kg"] == expected_kg


def test_match_grams_convert_si_to_kg(ctx) -> None:
    ctx.fake.seed("donations", [_donation(quantity=5000.0, unit="g")])
    ctx.fake.seed("ngos", [_ngo(), _ngo("ngo-2")])

    response = client_session.post("/api/v1/donations/don-1/match")

    assert response.status_code == 200
    assert response.json()["status"] == "ok"
    payload = ctx.ai._match_request("/api/v1/matching/rank-ngos")
    assert payload["donation"]["quantity_kg"] == 5.0


# ===========================================================================
# REQUIRED CASE: missing unit / unsupported unit -> no kg, no AI call
# ===========================================================================
def test_match_missing_unit_returns_insufficient_data(ctx) -> None:
    row = _donation()
    row.pop("unit", None)
    ctx.fake.seed("donations", [row])
    ctx.fake.seed("ngos", [_ngo(), _ngo("ngo-2")])

    response = client_session.post("/api/v1/donations/don-1/match")

    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "insufficient_data"
    assert "kg" in body["reason"]
    assert "/api/v1/matching/rank-ngos" not in ctx.ai.paths_hit


def test_match_unsupported_unit_returns_insufficient_data(ctx) -> None:
    ctx.fake.seed("donations", [_donation(unit="plates")])
    ctx.fake.seed("ngos", [_ngo(), _ngo("ngo-2")])

    response = client_session.post("/api/v1/donations/don-1/match")

    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "insufficient_data"
    assert "plates" in body["reason"]
    assert "/api/v1/matching/rank-ngos" not in ctx.ai.paths_hit


# ===========================================================================
# REQUIRED CASE: zero / negative quantity
# ===========================================================================
def test_match_zero_quantity_returns_insufficient_data(ctx) -> None:
    ctx.fake.seed("donations", [_donation(quantity=0)])
    ctx.fake.seed("ngos", [_ngo(), _ngo("ngo-2")])

    response = client_session.post("/api/v1/donations/don-1/match")

    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "insufficient_data"
    assert "quantity" in body["reason"]
    assert "/api/v1/matching/rank-ngos" not in ctx.ai.paths_hit


def test_match_negative_quantity_returns_insufficient_data(ctx) -> None:
    ctx.fake.seed("donations", [_donation(quantity=-3.0)])
    ctx.fake.seed("ngos", [_ngo(), _ngo("ngo-2")])

    response = client_session.post("/api/v1/donations/don-1/match")

    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "insufficient_data"
    assert "quantity" in body["reason"]
    assert "/api/v1/matching/rank-ngos" not in ctx.ai.paths_hit


# ===========================================================================
# Acknowledgment PDF must never state a servings count as kg
# ===========================================================================
def _seed_completed_food_for_ack(ctx) -> None:
    ctx.fake.seed("donations", [_donation(status="completed")])
    ctx.fake.seed(
        "claims",
        [{"id": "c1", "donation_id": "don-1", "ngo_id": "ngo-1", "status": "completed"}],
    )
    ctx.fake.seed("ngos", [_ngo("ngo-1", organization_name="Hope NGO")])


def test_ack_with_kg_donation_states_real_kg(ctx) -> None:
    _seed_completed_food_for_ack(ctx)

    response = client_session.post("/api/v1/donations/don-1/acknowledgment/generate")

    assert response.status_code == 200
    assert response.content.startswith(b"%PDF-1.4")
    payload = ctx.ai._match_request("/api/v1/donation/generate-acknowledgment")
    assert payload["quantity_kg"] == 10.0


def test_ack_with_servings_donation_rejected_without_inventing_kg(ctx) -> None:
    ctx.fake.seed("donations", [_donation(status="completed", unit="servings")])
    ctx.fake.seed(
        "claims",
        [{"id": "c1", "donation_id": "don-1", "ngo_id": "ngo-1", "status": "completed"}],
    )
    ctx.fake.seed("ngos", [_ngo("ngo-1", organization_name="Hope NGO")])

    response = client_session.post("/api/v1/donations/don-1/acknowledgment/generate")

    assert response.status_code == 400
    assert "/api/v1/donation/generate-acknowledgment" not in ctx.ai.paths_hit


# ===========================================================================
# Surplus prediction: uses the PROVIDER's prepared/sold kg verbatim — never
# the donation quantity — and never runs unless BOTH kg inputs are supplied.
# ===========================================================================
class _CreateFakeTable:
    def __init__(self, name: str, log: list[tuple]) -> None:
        self._name = name
        self._log = log
        self._pending: dict | None = None
        self._update_vals: dict | None = None

    def insert(self, values: dict) -> "_CreateFakeTable":
        self._log.append(("insert", self._name, values))
        self._pending = dict(values)
        return self

    def update(self, values: dict) -> "_CreateFakeTable":
        self._log.append(("update", self._name, values))
        self._update_vals = values
        return self

    def select(self, *cols: str) -> "_CreateFakeTable":
        return self

    def eq(self, key: str, value: object) -> "_CreateFakeTable":
        return self

    def single(self) -> "_CreateFakeTable":
        return self

    def execute(self):
        row = self._pending or {}
        row.setdefault("id", "don-row-1" if self._name == "donations" else "pred-row-1")
        if self._update_vals:
            row.update(self._update_vals)
        return type("R", (), {"data": [row]})()

    def __getattr__(self, item):
        return lambda *a, **k: self


class _CreateFakeSupabase:
    def __init__(self) -> None:
        self.log: list[tuple] = []

    def table(self, name: str) -> _CreateFakeTable:
        return _CreateFakeTable(name, self.log)


def _create_ai_handler() -> _AIHandler:
    ai = _AIHandler()

    def handler(request: httpx.Request) -> httpx.Response:
        ai.requests.append(request)
        path = request.url.path
        if path == "/api/v1/prediction/predict-surplus":
            body = json.loads(request.content)
            return httpx.Response(
                200,
                json={
                    "predicted_surplus_kg": 12.5,
                    "preparation_recommendation": "Prepare a bit less next time",
                    "recommended_prepare_kg": 40.0,
                    "input_echo": {
                        **body,
                        "date": "2026-08-28",
                    },
                    "model_version": "v1",
                },
            )
        if path == "/api/v1/safety/verify":
            return httpx.Response(
                200,
                json={
                    "donation_id": "pending-1",
                    "verdict": "Eligible",
                    "hours_since_preparation": 2.0,
                    "reasons": [],
                },
            )
        return httpx.Response(404, json={"detail": "not found"})

    ai.handler = handler  # type: ignore[method-assign]
    return ai


@pytest.fixture
def create_ctx(monkeypatch: pytest.MonkeyPatch):
    fake = _CreateFakeSupabase()
    monkeypatch.setattr("app.routers.donations.get_supabase_client", lambda: fake)
    ai = _create_ai_handler()
    app.dependency_overrides[get_current_profile] = lambda: _provider_profile()
    app.dependency_overrides[get_ai_client] = lambda: AIClient(
        base_url="http://ai.test",
        timeout=5.0,
        transport=httpx.MockTransport(ai.handler),
    )
    yield SimpleNamespace(fake=fake, ai=ai)
    app.dependency_overrides.clear()


def _create_payload(**overrides) -> dict:
    payload = {
        "food_name": "Vegetable Rice",
        "food_category": "Cooked Meals",
        "quantity": 10.0,
        "unit": "kg",
        "veg_type": "vegetarian",
        "food_image_url": "https://project.supabase.co/storage/v1/object/public/donations/food-photos/provider-FAKE-001/photo.png",
        "storage_condition": "refrigerated",
        "prepared_at": "2026-08-28T12:00:00Z",
        "expiry_time": "2026-08-28T20:00:00Z",
        "pickup_deadline": "2026-08-28T18:00:00Z",
        "pickup_address": "123 MG Road, Pune",
    }
    payload.update(overrides)
    return payload


def test_create_with_prepared_and_sold_kg_sends_both_verbatim(create_ctx) -> None:
    response = client_session.post(
        "/api/v1/donations",
        json=_create_payload(food_prepared_kg=50.0, food_sold_kg=38.0),
    )

    assert response.status_code == 200
    payload = create_ctx.ai._match_request("/api/v1/prediction/predict-surplus")
    assert payload["food_prepared_kg"] == 50.0
    assert payload["food_sold_kg"] == 38.0
    # the donation quantity is NEVER used as the prediction input
    assert payload["food_prepared_kg"] != 10.0


def test_create_prepared_kg_without_sold_kg_is_rejected(create_ctx) -> None:
    response = client_session.post(
        "/api/v1/donations", json=_create_payload(food_prepared_kg=50.0)
    )

    assert response.status_code == 422
    assert not [op for op in create_ctx.fake.log if op[1] == "donations"]
    assert "/api/v1/prediction/predict-surplus" not in create_ctx.ai.paths_hit


def test_create_sold_kg_exceeding_prepared_kg_is_rejected(create_ctx) -> None:
    response = client_session.post(
        "/api/v1/donations",
        json=_create_payload(food_prepared_kg=20.0, food_sold_kg=50.0),
    )

    assert response.status_code == 422
    assert not [op for op in create_ctx.fake.log if op[1] == "donations"]


def test_create_without_kg_inputs_never_calls_prediction(create_ctx) -> None:
    response = client_session.post("/api/v1/donations", json=_create_payload())

    assert response.status_code == 200
    assert response.json().get("prediction") is None
    assert "/api/v1/prediction/predict-surplus" not in create_ctx.ai.paths_hit