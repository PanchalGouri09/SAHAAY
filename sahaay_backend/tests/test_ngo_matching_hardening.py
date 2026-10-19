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
import logging
from datetime import datetime, timedelta, timezone
from types import SimpleNamespace

import httpx
import pytest
from fastapi import HTTPException
from pydantic import ValidationError
from fastapi.testclient import TestClient

from app.dependencies import get_current_profile
from app.main import app
from app.routers import ai_features
from app.schemas.ai import NGOScoreBreakdown
from app.services.ai_client import AIClient, get_ai_client
from app.services import donation_offers as offer_service

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

    def or_(self, expression: str) -> "_FakeTable":
        self._filters.append(("or", expression))
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
        for filter_item in self._filters:
            kind = filter_item[0]
            if kind == "or":
                value = filter_item[1]
                alternatives = []
                for clause in value.split(","):
                    field, operator, raw = clause.split(".", 2)
                    if operator == "eq":
                        expected = raw == "true" if raw in {"true", "false"} else raw
                        alternatives.append((field, expected))
                rows = [
                    row
                    for row in rows
                    if any(
                        row.get(field) == expected
                        for field, expected in alternatives
                    )
                ]
                continue
            _, key, value = filter_item
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
        if name == "ngos":
            for row in rows:
                user_id = row.get("user_id") or f"user-{row['id']}"
                row.setdefault("user_id", user_id)
                self.tables.setdefault("users", []).append(
                    {
                        "id": user_id,
                        "role": "ngo",
                        "full_name": f"Contact {row['id']}",
                        "email": f"{row['id']}@example.org",
                        "phone": "+91 9876543210",
                    }
                )
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

    def persist(_client, *, donation_id, ranked_ngos):
        candidates = offer_service._ranked_candidate_rows(ranked_ngos)
        fake.seed(
            "donation_match_candidates",
            [{**candidate, "donation_id": donation_id} for candidate in candidates],
        )
        return {"status": "offered"}

    monkeypatch.setattr(
        offer_service,
        "persist_ranked_candidates",
        persist,
    )
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
        "food_category": "Cooked Meals",
        "quantity": 10.0,
        "unit": "kg",
        "veg_type": "vegetarian",
        "pickup_deadline": "2026-09-30T13:00:00+00:00",
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
        "user_id": f"user-{ngo_id}",
        "organization_name": f"NGO {ngo_id}",
        "city": "Pune",
        "address": "12 NGO Road",
        "phone": "+91-1234567890",
        "latitude": 18.53,
        "longitude": 73.86,
        "food_capacity": 50,
        "max_capacity_kg": 50,
        # Food categories (SAHAAY vocabulary) are separate from dietary prefs.
        "preferred_food_types": ["Cooked Meals"],
        "dietary_preferences": ["vegetarian"],
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
            "rank": 2,
        },
    ]

    response = client_session.post("/api/v1/donations/don-1/match")

    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "ok"
    ids = [item["ngo_id"] for item in body["ranked_ngos"]]
    assert ids == ["ngo-real"]


def test_match_incomplete_ai_ranking_is_rejected(ctx) -> None:
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

    assert response.status_code == 502
    assert "incomplete" in response.json()["detail"]


def test_match_empty_ranking_for_eligible_candidates_is_rejected(ctx) -> None:
    ctx.fake.seed("donations", [_donation()])
    ctx.fake.seed("ngos", [_ngo("ngo-a")])
    ctx.ai.ranked_override = []

    response = client_session.post("/api/v1/donations/don-1/match")

    assert response.status_code == 502
    assert "incomplete" in response.json()["detail"]


def test_other_food_category_matches_only_ngos_that_accept_other(ctx) -> None:
    ctx.fake.seed("donations", [_donation(food_category="Other")])
    ctx.fake.seed("ngos", [_ngo("ngo-other", preferred_food_types=["Other"])])

    response = client_session.post("/api/v1/donations/don-1/match")

    assert response.status_code == 200
    assert response.json()["ranked_ngos"][0]["ngo_id"] == "ngo-other"


def test_matching_endpoint_persists_and_starts_ranked_offers(ctx, monkeypatch) -> None:
    ctx.fake.seed("donations", [_donation()])
    ctx.fake.seed("ngos", [_ngo("ngo-a"), _ngo("ngo-b")])
    saved = []

    def persist(_client, *, donation_id, ranked_ngos):
        saved.append({"donation_id": donation_id, "ranked_ngos": ranked_ngos})
        candidates = offer_service._ranked_candidate_rows(ranked_ngos)
        ctx.fake.seed(
            "donation_match_candidates",
            [{**candidate, "donation_id": donation_id} for candidate in candidates],
        )
        return {"status": "offered"}

    monkeypatch.setattr(
        offer_service,
        "persist_ranked_candidates",
        persist,
    )

    response = client_session.post("/api/v1/donations/don-1/match")

    assert response.status_code == 200
    assert response.json()["offer_sequence"] == {"status": "offered"}
    assert len(saved) == 1
    assert [row["match_rank"] for row in saved[0]["ranked_ngos"]] == [1, 2]


@pytest.mark.parametrize(
    ("donation_type", "accepted_types", "expected"),
    [
        ("veg", ["vegetarian"], True),
        ("vegan", ["vegetarian"], True),
        ("veg", ["vegan"], False),
        ("non_veg", ["vegetarian"], False),
        ("any", ["vegetarian"], False),
        ("any", ["vegetarian", "non_vegetarian"], True),
        ("non_veg", ["any"], True),
    ],
)
def test_dietary_compatibility_is_explicit(donation_type, accepted_types, expected):
    from app.routers.ai_features import _dietary_accepted, _dietary_compatible

    accepted = _dietary_accepted(accepted_types)
    assert _dietary_compatible(donation_type, accepted) is expected


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
                preferred_food_types=["Cooked Meals"],
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
    assert item["distance_source"] == "straight_line"
    assert item["rank"] == 1
    assert item["ngo"]["organization_name"] == "Helping Hands Trust"
    assert item["ngo"]["city"] == "Pune"
    assert item["ngo"]["address"] == "12 NGO Road"
    assert item["ngo"]["phone"] == "+91-1234567890"
    assert item["ngo"]["verified"] is True
    assert item["ngo"]["food_capacity"] == 80
    assert item["ngo"]["max_capacity_kg"] == 50
    assert item["ngo"]["preferred_food_types"] == ["Cooked Meals"]
    assert item["ngo"]["available_from"] == "07:00"
    assert item["ngo"]["available_to"] == "22:00"


@pytest.mark.parametrize(
    "legacy_flag",
    [False, None, "missing"],
)
def test_complete_ngo_is_candidate_independent_of_legacy_verification(
    ctx, legacy_flag
) -> None:
    ctx.fake.seed("donations", [_donation()])
    ngo = _ngo("ngo-1", demo_verified=False)
    if legacy_flag == "missing":
        ngo.pop("verified")
    else:
        ngo["verified"] = legacy_flag
    ctx.fake.seed(
        "ngos",
        [ngo],
    )

    response = client_session.post("/api/v1/donations/don-1/match")

    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "ok"
    assert [item["ngo_id"] for item in body["ranked_ngos"]] == ["ngo-1"]
    assert "/api/v1/matching/rank-ngos" in ctx.ai.paths_hit


def test_legacy_demo_flag_does_not_make_incomplete_ngo_matchable(ctx) -> None:
    ctx.fake.seed("donations", [_donation()])
    ctx.fake.seed("ngos", [_ngo("ngo-demo", demo_verified=True, latitude=None)])

    response = client_session.post("/api/v1/donations/don-1/match")

    assert response.status_code == 200
    assert response.json()["status"] == "insufficient_data"
    assert "/api/v1/matching/rank-ngos" not in ctx.ai.paths_hit


def test_profile_complete_ngo_is_candidate_without_any_legacy_flag(ctx) -> None:
    ctx.fake.seed("donations", [_donation()])
    ngo = _ngo("ngo-1")
    ngo.pop("verified")
    ngo.pop("demo_verified", None)
    ctx.fake.seed("ngos", [ngo])

    matched = client_session.post("/api/v1/donations/don-1/match")

    assert matched.status_code == 200
    assert matched.json()["status"] == "ok"
    assert [item["ngo_id"] for item in matched.json()["ranked_ngos"]] == ["ngo-1"]
    assert "verified" not in ctx.fake.tables["ngos"][0]
    assert len(ctx.fake.tables["donation_match_candidates"]) == 1


def test_candidate_query_failure_logs_stage_without_exception_message(caplog) -> None:
    class FailedQuery:
        def select(self, *_args):
            return self

        def execute(self):
            raise RuntimeError("sensitive query response must not be logged")

    class FailedClient:
        def table(self, _name):
            return FailedQuery()

    with caplog.at_level(logging.ERROR, logger="sahaay.matching"):
        with pytest.raises(HTTPException) as error:
            ai_features._ngo_candidates(
                FailedClient(),
                pickup_time="12:00",
                quantity_kg=1.0,
                dietary_type="veg",
                food_category="meals",
            )

    assert error.value.status_code == 503
    assert "stage=ngo_profiles error_type=RuntimeError" in caplog.text
    assert "sensitive query response" not in caplog.text


def test_match_keeps_valid_zero_coordinates(ctx) -> None:
    provider = _provider_profile()
    provider["providers"][0].update(latitude=0.0, longitude=0.0)
    app.dependency_overrides[get_current_profile] = lambda: provider
    ctx.fake.seed("donations", [_donation(latitude=18.52, longitude=73.85)])
    ctx.fake.seed("ngos", [_ngo("ngo-zero", latitude=0.0, longitude=0.0)])

    response = client_session.post("/api/v1/donations/don-1/match")

    assert response.status_code == 200
    assert response.json()["status"] == "ok"
    request = next(
        request
        for request in ctx.ai.requests
        if request.url.path == "/api/v1/matching/rank-ngos"
    )
    payload = json.loads(request.content)
    assert payload["donation"]["restaurant_latitude"] == 0.0
    assert payload["donation"]["restaurant_longitude"] == 0.0
    assert payload["candidate_ngos"][0]["latitude"] == 0.0
    assert payload["candidate_ngos"][0]["longitude"] == 0.0


def test_match_response_schema_rejects_missing_or_out_of_range_scores() -> None:
    score = {
        "ngo_id": "ngo-1",
        "ngo_name": "Helping Hands",
        "distance_km": 2.5,
        "distance_source": "straight_line",
        "distance_score": 90.0,
        "quantity_fit_score": 80.0,
        "dietary_compatibility_score": 100.0,
        "pickup_time_feasibility_score": 100.0,
        "restaurant_reliability_score": 88.0,
        "final_score": 91.0,
        "rank": 1,
    }
    parsed = NGOScoreBreakdown.model_validate(score)
    assert parsed.model_dump()["final_score"] == 91.0
    with pytest.raises(ValidationError):
        NGOScoreBreakdown.model_validate({**score, "final_score": 101.0})
    with pytest.raises(ValidationError):
        NGOScoreBreakdown.model_validate(
            {key: value for key, value in score.items() if key != "final_score"}
        )