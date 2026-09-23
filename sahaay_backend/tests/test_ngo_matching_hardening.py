"""
STEP 3: NGO matching production hardening tests.

Covers the honesty/robustness rules added to POST /api/v1/donations/{id}/match:
  * only 'available', non-expired donations are matched
  * the pickup time is NEVER invented ("12:00" default was removed)
  * the AI's ranked NGO IDs are validated against the eligible candidate set:
    unknown IDs dropped, duplicates deduped, empty ranking surfaces as ok+empty
  * each ranked NGO is enriched with its REAL ngos row under 'ngo', while the
    AI-estimated scores stay at the top level

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
# Fake Supabase (recording, filterable, mutable)
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
# AI transport — rank-ngos is CONTROLLABLE so edge cases can be forced
# ---------------------------------------------------------------------------
class _AIHandler:
    def __init__(self) -> None:
        self.requests: list[httpx.Request] = []
        self.ranked_override: list[dict] | None = None

    @property
    def paths_hit(self) -> list[str]:
        return [r.url.path for r in self.requests]

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
        return httpx.Response(404, json={"detail": "not found"})


# ---------------------------------------------------------------------------
# Fixture + seeds
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
# Donation eligibility
# ===========================================================================
def test_match_completed_donation_returns_insufficient_data(ctx) -> None:
    ctx.fake.seed("donations", [_donation(status="completed")])
    ctx.fake.seed("ngos", [_ngo(), _ngo("ngo-2")])

    response = client_session.post("/api/v1/donations/don-1/match")

    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "insufficient_data"
    assert "available" in body["reason"]
    assert "/api/v1/matching/rank-ngos" not in ctx.ai.paths_hit
    assert "/api/v1/reliability/calculate" not in ctx.ai.paths_hit


def test_match_expired_donation_returns_insufficient_data(ctx) -> None:
    past = (datetime.now(timezone.utc) - timedelta(hours=1)).isoformat()
    ctx.fake.seed("donations", [_donation(expiry_time=past)])
    ctx.fake.seed("ngos", [_ngo(), _ngo("ngo-2")])

    response = client_session.post("/api/v1/donations/don-1/match")

    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "insufficient_data"
    assert "expiry" in body["reason"]
    assert "/api/v1/matching/rank-ngos" not in ctx.ai.paths_hit


# ===========================================================================
# No invented pickup time / quantity / location
# ===========================================================================
def test_match_missing_pickup_deadline_returns_insufficient_data(ctx) -> None:
    ctx.fake.seed("donations", [_donation(pickup_deadline=None)])
    ctx.fake.seed("ngos", [_ngo()])

    response = client_session.post("/api/v1/donations/don-1/match")

    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "insufficient_data"
    assert "pickup" in body["reason"]
    assert "/api/v1/matching/rank-ngos" not in ctx.ai.paths_hit


def test_match_malformed_pickup_deadline_returns_insufficient_data(ctx) -> None:
    ctx.fake.seed("donations", [_donation(pickup_deadline="not-a-date")])
    ctx.fake.seed("ngos", [_ngo()])

    response = client_session.post("/api/v1/donations/don-1/match")

    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "insufficient_data"
    assert "pickup" in body["reason"]


def test_match_zero_quantity_returns_insufficient_data(ctx) -> None:
    ctx.fake.seed("donations", [_donation(quantity=0)])
    ctx.fake.seed("ngos", [_ngo()])

    response = client_session.post("/api/v1/donations/don-1/match")

    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "insufficient_data"
    assert "quantity" in body["reason"]


def test_match_missing_donation_fields_returns_insufficient_data(ctx) -> None:
    # Neither the provider profile nor the donation carries coordinates.
    app.dependency_overrides[get_current_profile] = lambda: {
        "id": "user-FAKE-001",
        "role": "provider",
        "providers": [
            {
                "id": _PROVIDER_ID,
                "organization_name": "Tasty Kitchen",
            }
        ],
    }
    ctx.fake.seed("donations", [_donation(latitude=None, longitude=None)])
    ctx.fake.seed("ngos", [_ngo()])

    response = client_session.post("/api/v1/donations/don-1/match")

    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "insufficient_data"
    assert "location" in body["reason"]


# ===========================================================================
# AI ranking validation
# ===========================================================================
def test_match_unknown_ngo_id_from_ai_is_dropped(ctx) -> None:
    ctx.fake.seed("donations", [_donation()])
    ctx.fake.seed("ngos", [_ngo("ngo-real")])
    ctx.ai.ranked_override = [
        {
            "ngo_id": "ngo-real",
            "ngo_name": "NGO ngo-real",
            "distance_km": 1.0,
            "distance_source": "straight_line",
            "distance_score": 99.0,
            "quantity_fit_score": 90.0,
            "dietary_compatibility_score": 100.0,
            "pickup_time_feasibility_score": 100.0,
            "restaurant_reliability_score": 91.5,
            "final_score": 95.0,
            "rank": 1,
        },
        {
            "ngo_id": "ngo-NOT-SENT",
            "ngo_name": "Impostor NGO",
            "distance_km": 0.5,
            "distance_source": "straight_line",
            "distance_score": 99.0,
            "quantity_fit_score": 90.0,
            "dietary_compatibility_score": 100.0,
            "pickup_time_feasibility_score": 100.0,
            "restaurant_reliability_score": 91.5,
            "final_score": 99.0,
            "rank": 0,
        },
    ]

    response = client_session.post("/api/v1/donations/don-1/match")

    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "ok"
    ids = [item["ngo_id"] for item in body["ranked_ngos"]]
    assert ids == ["ngo-real"]


def test_match_duplicate_ngo_id_from_ai_is_deduped(ctx) -> None:
    ctx.fake.seed("donations", [_donation()])
    ctx.fake.seed("ngos", [_ngo("ngo-a"), _ngo("ngo-b")])
    ctx.ai.ranked_override = [
        {
            "ngo_id": "ngo-a",
            "ngo_name": "NGO ngo-a",
            "distance_km": 1.0,
            "distance_source": "straight_line",
            "distance_score": 99.0,
            "quantity_fit_score": 90.0,
            "dietary_compatibility_score": 100.0,
            "pickup_time_feasibility_score": 100.0,
            "restaurant_reliability_score": 91.5,
            "final_score": 95.0,
            "rank": 1,
        },
        {
            "ngo_id": "ngo-a",
            "ngo_name": "NGO ngo-a DUPLICATE",
            "distance_km": 9.0,
            "distance_source": "straight_line",
            "distance_score": 10.0,
            "quantity_fit_score": 10.0,
            "dietary_compatibility_score": 10.0,
            "pickup_time_feasibility_score": 10.0,
            "restaurant_reliability_score": 10.0,
            "final_score": 10.0,
            "rank": 2,
        },
    ]

    response = client_session.post("/api/v1/donations/don-1/match")

    assert response.status_code == 200
    body = response.json()
    ids = [item["ngo_id"] for item in body["ranked_ngos"]]
    assert ids == ["ngo-a"]
    assert body["ranked_ngos"][0]["final_score"] == 95.0


def test_match_empty_ranking_from_ai_returns_ok_with_empty_list(ctx) -> None:
    ctx.fake.seed("donations", [_donation()])
    ctx.fake.seed("ngos", [_ngo("ngo-a")])
    ctx.ai.ranked_override = []

    response = client_session.post("/api/v1/donations/don-1/match")

    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "ok"
    assert body["ranked_ngos"] == []


# ===========================================================================
# Enrichment with real NGO rows
# ===========================================================================
def test_match_ranked_ngo_enriched_with_real_fields(ctx) -> None:
    ctx.fake.seed("donations", [_donation()])
    ctx.fake.seed(
        "ngos",
        [
            _ngo(
                "ngo-1",
                organization_name="Helping Hands Trust",
                city="Pune",
                address="12 NGO Road",
                phone="+91-1234567890",
                food_capacity=80,
                preferred_food_types=["vegetarian"],
            )
        ],
    )

    response = client_session.post("/api/v1/donations/don-1/match")

    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "ok"
    item = body["ranked_ngos"][0]
    assert item["ngo_id"] == "ngo-1"
    assert item["final_score"] == 87.5
    assert item["distance_km"] == 3.0
    assert item["rank"] == 1
    assert item["ngo"]["organization_name"] == "Helping Hands Trust"
    assert item["ngo"]["city"] == "Pune"
    assert item["ngo"]["address"] == "12 NGO Road"
    assert item["ngo"]["phone"] == "+91-1234567890"
    assert item["ngo"]["verified"] is True
    assert item["ngo"]["food_capacity"] == 80
    assert item["ngo"]["preferred_food_types"] == ["vegetarian"]
    assert item["ngo"]["available_from"] == "07:00"
    assert item["ngo"]["available_to"] == "22:00"


def test_match_unverified_ngo_excluded_from_candidates(ctx) -> None:
    # A non-verified NGO is never a candidate — the AI is not even called,
    # and its identity is never surfaced to the provider.
    ctx.fake.seed("donations", [_donation()])
    ctx.fake.seed("ngos", [_ngo("ngo-1", verified=False)])

    response = client_session.post("/api/v1/donations/don-1/match")

    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "insufficient_data"
    assert "/api/v1/matching/rank-ngos" not in ctx.ai.paths_hit