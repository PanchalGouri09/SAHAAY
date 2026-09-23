"""
Integration-behavior tests for the Phase-2 AI features exposed through the
Main SAHAAY backend (app/routers/ai_features.py):

    NGO Matching, Auto-Escalation, Provider Reliability, Acknowledgment PDF.

Boundaries mocked (test-only):
  * AI HTTP transport -> httpx.MockTransport, so the REAL typed AIClient runs
    end to end. The escalation handler mirrors the real service rule; other
    handlers return the service's real response shapes.
  * Supabase -> recording fake seeded with REAL-shaped rows (donations,
    ngos, claims, feedback). Nothing touches a live DB.
  * Auth -> dependency_overrides on get_current_profile.

These tests verify wiring: which AI endpoint is called, what real data is
mapped, and how AI unavailable / invalid / missing-data cases are surfaced
without corrupting state. They do not judge AI "science".
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


def _ngo_profile() -> dict:
    return {"id": "ngo-user-1", "role": "ngo", "ngos": [{"id": "ngo-1"}]}


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

    def update(self, values: dict) -> "_FakeTable":
        self._update_values = values
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
# AI transport (mirrors the real service contracts)
# ---------------------------------------------------------------------------
class _AIHandler:
    def __init__(self, *, raise_connect: bool = False, invalid: dict | None = None) -> None:
        self.requests: list[httpx.Request] = []
        self.raise_connect = raise_connect
        self.invalid = invalid or {}

    @property
    def paths_hit(self) -> list[str]:
        return [r.url.path for r in self.requests]

    def handler(self, request: httpx.Request) -> httpx.Response:
        self.requests.append(request)
        if self.raise_connect:
            raise httpx.ConnectError("connection refused to AI")
        path = request.url.path

        if path == "/api/v1/reliability/calculate":
            if self.invalid.get("reliability"):
                return httpx.Response(200, json=self.invalid["reliability"])
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
            if self.invalid.get("match"):
                return httpx.Response(200, json=self.invalid["match"])
            body = json.loads(request.content)
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

        if path == "/api/v1/escalation/check":
            if self.invalid.get("escalation"):
                return httpx.Response(200, json=self.invalid["escalation"])
            body = json.loads(request.content)
            status = body["current_ngo_status"]
            offer = datetime.fromisoformat(body["offer_sent_at"].replace("Z", "+00:00"))
            elapsed = (datetime.now(timezone.utc) - offer).total_seconds() / 60.0
            idx = body["current_ngo_index"]
            ngo_ids = body["ranked_ngo_ids"]
            if status == "accepted":
                action, next_id, next_idx = "accepted", None, None
            elif status == "rejected" or (status == "pending" and elapsed >= 15):
                nxt = idx + 1
                if nxt >= len(ngo_ids):
                    action, next_id, next_idx = "no_ngos_left", None, None
                else:
                    action, next_id, next_idx = "escalate", ngo_ids[nxt], nxt
            else:
                action, next_id, next_idx = "keep_waiting", None, None
            return httpx.Response(
                200,
                json={
                    "donation_id": body["donation_id"],
                    "action": action,
                    "next_ngo_id": next_id,
                    "next_ngo_index": next_idx,
                    "minutes_elapsed": round(elapsed, 2),
                    "message": f"action: {action}",
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
    monkeypatch.setattr("app.routers.donations.get_supabase_client", lambda: fake)
    ai = _AIHandler()
    app.dependency_overrides[get_current_profile] = lambda: _provider_profile()
    app.dependency_overrides[get_ai_client] = lambda: AIClient(
        base_url="http://ai.test",
        timeout=5.0,
        transport=httpx.MockTransport(ai.handler),
    )
    yield SimpleNamespace(fake=fake, ai=ai)
    app.dependency_overrides.clear()


def _seed_donation(fake, **overrides) -> dict:
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
    fake.seed("donations", [row])
    return row


def _seed_ngo(fake, ngo_id: str, *, with_hours: bool = True, **overrides) -> dict:
    row = {
        "id": ngo_id,
        "organization_name": f"NGO {ngo_id}",
        "latitude": 18.53,
        "longitude": 73.86,
        "food_capacity": 50.0,
        "preferred_food_types": ["vegetarian", "vegan"],
        "verified": True,
    }
    if with_hours:
        row.update({"available_from": "07:00", "available_to": "22:00"})
    row.update(overrides)
    fake.seed("ngos", [row])
    return row


# ===========================================================================
# NGO MATCHING
# ===========================================================================
def test_match_calls_ai_with_real_data_mapped(ctx) -> None:
    _seed_donation(ctx.fake)
    _seed_ngo(ctx.fake, "ngo-1")
    _seed_ngo(ctx.fake, "ngo-2")
    ctx.fake.seed(
        "claims", [{"id": "c1", "donation_id": "don-1", "ngo_id": "ngo-1", "status": "accepted"}]
    )

    response = client_session.post("/api/v1/donations/don-1/match")

    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "ok"
    assert len(body["ranked_ngos"]) == 2
    assert "/api/v1/matching/rank-ngos" in ctx.ai.paths_hit

    match_request = next(
        r for r in ctx.ai.requests if r.url.path == "/api/v1/matching/rank-ngos"
    )
    payload = json.loads(match_request.content)
    donation = payload["donation"]
    assert donation["donation_id"] == "don-1"
    assert donation["restaurant_id"] == _PROVIDER_ID
    assert donation["quantity_kg"] == 10.0
    assert donation["dietary_type"] == "veg"
    assert donation["pickup_time"] == "18:30"
    assert donation["restaurant_latitude"] == 18.52
    candidates = {c["ngo_id"]: c for c in payload["candidate_ngos"]}
    assert set(candidates) == {"ngo-1", "ngo-2"}
    assert candidates["ngo-1"]["name"] == "NGO ngo-1"
    assert candidates["ngo-1"]["max_capacity_kg"] == 50.0
    assert candidates["ngo-1"]["dietary_accepted"] == ["veg", "vegan"]
    # NGO IDs come from the database, never from the client.
    assert "ngo_id" in payload["candidate_ngos"][0]


def test_match_insufficient_data_without_ngo_operating_hours(ctx) -> None:
    _seed_donation(ctx.fake)
    _seed_ngo(ctx.fake, "ngo-1", with_hours=False)

    response = client_session.post("/api/v1/donations/don-1/match")

    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "insufficient_data"
    assert "hours" in body["reason"]
    assert "/api/v1/matching/rank-ngos" not in ctx.ai.paths_hit


def test_match_ai_unavailable_returns_503(ctx) -> None:
    _seed_donation(ctx.fake)
    _seed_ngo(ctx.fake, "ngo-1")
    ctx.ai.raise_connect = True

    response = client_session.post("/api/v1/donations/don-1/match")

    assert response.status_code == 503


def test_match_invalid_ai_response_returns_502(ctx) -> None:
    _seed_donation(ctx.fake)
    _seed_ngo(ctx.fake, "ngo-1")
    ctx.ai.invalid["match"] = {"unexpected": True}

    response = client_session.post("/api/v1/donations/don-1/match")

    assert response.status_code == 502


def test_match_non_owner_provider_returns_403(ctx) -> None:
    _seed_donation(ctx.fake, provider_id="provider-OTHER")

    response = client_session.post("/api/v1/donations/don-1/match")

    assert response.status_code == 403


def test_match_requires_provider_role(ctx) -> None:
    app.dependency_overrides[get_current_profile] = _ngo_profile
    _seed_donation(ctx.fake)
    _seed_ngo(ctx.fake, "ngo-1")

    response = client_session.post("/api/v1/donations/don-1/match")

    assert response.status_code == 403


# ===========================================================================
# AUTO-ESCALATION
# ===========================================================================
def _seed_claims(ctx, rows: list[dict]) -> None:
    ctx.fake.seed("claims", rows)


def test_escalation_passes_real_claim_state_to_ai(ctx) -> None:
    _seed_donation(ctx.fake)
    now = datetime.now(timezone.utc)
    _seed_claims(
        ctx,
        [
            {
                "id": "c1",
                "donation_id": "don-1",
                "ngo_id": "ngo-1",
                "status": "pending",
                "claimed_at": (now - timedelta(minutes=2)).isoformat(),
                "created_at": now.isoformat(),
            },
            {
                "id": "c2",
                "donation_id": "don-1",
                "ngo_id": "ngo-2",
                "status": "pending",
                "claimed_at": now.isoformat(),
                "created_at": now.isoformat(),
            },
        ],
    )

    response = client_session.post("/api/v1/donations/don-1/escalation-check")

    assert response.status_code == 200
    body = response.json()
    assert body["action"] == "keep_waiting"
    assert body["current_ngo_id"] == "ngo-1"

    esc_req = next(
        r for r in ctx.ai.requests if r.url.path == "/api/v1/escalation/check"
    )
    payload = json.loads(esc_req.content)
    assert payload["donation_id"] == "don-1"
    assert payload["ranked_ngo_ids"] == ["ngo-1", "ngo-2"]
    assert payload["current_ngo_index"] == 0
    assert payload["current_ngo_status"] == "pending"
    assert payload["offer_sent_at"]
    # No state change while waiting.
    assert ctx.fake.tables["claims"][0]["status"] == "pending"


def test_escalation_times_out_and_escalates_to_next_ngo(ctx) -> None:
    _seed_donation(ctx.fake)
    now = datetime.now(timezone.utc)
    _seed_claims(
        ctx,
        [
            {
                "id": "c1",
                "donation_id": "don-1",
                "ngo_id": "ngo-1",
                "status": "pending",
                "claimed_at": (now - timedelta(hours=2)).isoformat(),
                "created_at": now.isoformat(),
            },
            {
                "id": "c2",
                "donation_id": "don-1",
                "ngo_id": "ngo-2",
                "status": "pending",
                "claimed_at": now.isoformat(),
                "created_at": now.isoformat(),
            },
        ],
    )

    response = client_session.post("/api/v1/donations/don-1/escalation-check")

    assert response.status_code == 200
    body = response.json()
    assert body["action"] == "escalate"
    assert body["next_ngo_id"] == "ngo-2"
    assert body["next_ngo_index"] == 1
    # The stale offer is rejected using existing claim columns.
    claim = ctx.fake.tables["claims"][0]
    assert claim["status"] == "rejected"
    assert "Auto-escalated" in claim["rejection_reason"]


def test_escalation_accepted_claim_is_not_mutated(ctx) -> None:
    _seed_donation(ctx.fake)
    now = datetime.now(timezone.utc)
    _seed_claims(
        ctx,
        [
            {
                "id": "c1",
                "donation_id": "don-1",
                "ngo_id": "ngo-1",
                "status": "accepted",
                "claimed_at": now.isoformat(),
                "accepted_at": now.isoformat(),
                "created_at": now.isoformat(),
            },
        ],
    )

    response = client_session.post("/api/v1/donations/don-1/escalation-check")

    assert response.status_code == 200
    assert response.json()["action"] == "accepted"
    assert ctx.fake.tables["claims"][0]["status"] == "accepted"


def test_escalation_no_claims_returns_no_claims_without_ai(ctx) -> None:
    _seed_donation(ctx.fake)

    response = client_session.post("/api/v1/donations/don-1/escalation-check")

    assert response.status_code == 200
    assert response.json()["action"] == "no_claims"
    assert "/api/v1/escalation/check" not in ctx.ai.paths_hit


def test_escalation_ai_unavailable_returns_503(ctx) -> None:
    _seed_donation(ctx.fake)
    now = datetime.now(timezone.utc)
    _seed_claims(
        ctx,
        [{"id": "c1", "donation_id": "don-1", "ngo_id": "ngo-1", "status": "pending",
          "claimed_at": now.isoformat(), "created_at": now.isoformat()}],
    )
    ctx.ai.raise_connect = True

    response = client_session.post("/api/v1/donations/don-1/escalation-check")

    assert response.status_code == 503


def test_escalation_invalid_ai_response_returns_502(ctx) -> None:
    _seed_donation(ctx.fake)
    now = datetime.now(timezone.utc)
    _seed_claims(
        ctx,
        [{"id": "c1", "donation_id": "don-1", "ngo_id": "ngo-1", "status": "pending",
          "claimed_at": now.isoformat(), "created_at": now.isoformat()}],
    )
    ctx.ai.invalid["escalation"] = {"unexpected": True}

    response = client_session.post("/api/v1/donations/don-1/escalation-check")

    assert response.status_code == 502


def test_escalation_non_owner_returns_403(ctx) -> None:
    _seed_donation(ctx.fake, provider_id="provider-OTHER")
    now = datetime.now(timezone.utc)
    _seed_claims(ctx, [{"id": "c1", "donation_id": "don-1", "ngo_id": "ngo-1",
                        "status": "pending", "claimed_at": now.isoformat(),
                        "created_at": now.isoformat()}])

    response = client_session.post("/api/v1/donations/don-1/escalation-check")

    assert response.status_code == 403


# ===========================================================================
# RELIABILITY
# ===========================================================================
def test_reliability_uses_real_provider_history(ctx) -> None:
    ctx.fake.seed(
        "donations",
        [
            {"id": "d1", "provider_id": _PROVIDER_ID, "status": "delivered"},
            {"id": "d2", "provider_id": _PROVIDER_ID, "status": "completed"},
            {"id": "d3", "provider_id": _PROVIDER_ID, "status": "cancelled"},
        ],
    )
    ctx.fake.seed(
        "claims",
        [
            {"donation_id": "d1", "status": "accepted"},
            {"donation_id": "d2", "status": "completed"},
        ],
    )
    ctx.fake.seed(
        "feedback",
        [{"donation_id": "d1", "rating": 4}, {"donation_id": "d2", "rating": 5}],
    )

    response = client_session.get("/api/v1/providers/me/reliability")

    assert response.status_code == 200
    body = response.json()
    assert body["restaurant_id"] == _PROVIDER_ID
    assert body["reliability_score"] == 91.5
    assert body["grade"] == "Excellent"

    reliability_req = next(
        r for r in ctx.ai.requests if r.url.path == "/api/v1/reliability/calculate"
    )
    payload = json.loads(reliability_req.content)
    assert payload["restaurant_id"] == _PROVIDER_ID
    assert payload["total_donations_offered"] == 3
    assert payload["total_donations_completed"] == 2
    assert payload["total_donations_accepted"] == 2
    assert payload["total_cancellations"] == 1
    assert payload["average_ngo_rating"] == 4.5


def test_reliability_without_feedback_uses_zero_rating(ctx) -> None:
    ctx.fake.seed("donations", [{"id": "d1", "provider_id": _PROVIDER_ID, "status": "completed"}])

    response = client_session.get("/api/v1/providers/me/reliability")

    assert response.status_code == 200
    reliability_req = next(
        r for r in ctx.ai.requests if r.url.path == "/api/v1/reliability/calculate"
    )
    payload = json.loads(reliability_req.content)
    assert payload["average_ngo_rating"] == 0.0


def test_reliability_ai_unavailable_returns_503(ctx) -> None:
    ctx.fake.seed("donations", [{"id": "d1", "provider_id": _PROVIDER_ID, "status": "completed"}])
    ctx.ai.raise_connect = True

    response = client_session.get("/api/v1/providers/me/reliability")

    assert response.status_code == 503


def test_reliability_invalid_ai_response_returns_502(ctx) -> None:
    ctx.fake.seed("donations", [{"id": "d1", "provider_id": _PROVIDER_ID, "status": "completed"}])
    ctx.ai.invalid["reliability"] = {"foo": "bar"}

    response = client_session.get("/api/v1/providers/me/reliability")

    assert response.status_code == 502


def test_reliability_requires_provider_role(ctx) -> None:
    ctx.fake.seed("donations", [{"id": "d1", "provider_id": _PROVIDER_ID, "status": "completed"}])
    app.dependency_overrides[get_current_profile] = _ngo_profile

    response = client_session.get("/api/v1/providers/me/reliability")

    assert response.status_code == 403


# ===========================================================================
# ACKNOWLEDGMENT PDF
# ===========================================================================
def _seed_completed_donations_for_ack(ctx) -> None:
    _seed_donation(ctx.fake, status="completed")
    ctx.fake.seed(
        "claims",
        [{"id": "c1", "donation_id": "don-1", "ngo_id": "ngo-1", "status": "completed"}],
    )
    _seed_ngo(ctx.fake, "ngo-1", with_hours=False, organization_name="Hope NGO")


def test_ack_generate_returns_pdf_to_owner(ctx) -> None:
    _seed_completed_donations_for_ack(ctx)

    response = client_session.post("/api/v1/donations/don-1/acknowledgment/generate")

    assert response.status_code == 200
    assert response.headers["content-type"].startswith("application/pdf")
    assert response.content.startswith(b"%PDF-1.4")
    assert "/api/v1/donation/generate-acknowledgment" in ctx.ai.paths_hit
    assert "/api/v1/donation/download/don-1" in ctx.ai.paths_hit


def test_ack_generate_requires_completed_donation(ctx) -> None:
    _seed_donation(ctx.fake, status="available")

    response = client_session.post("/api/v1/donations/don-1/acknowledgment/generate")

    assert response.status_code == 400
    assert "completed" in response.json()["detail"]


def test_ack_generate_requires_completed_claim(ctx) -> None:
    _seed_donation(ctx.fake, status="completed")
    _seed_ngo(ctx.fake, "ngo-1", with_hours=False)

    response = client_session.post("/api/v1/donations/don-1/acknowledgment/generate")

    assert response.status_code == 400
    assert "completed claim" in response.json()["detail"]
    assert "/api/v1/donation/generate-acknowledgment" not in ctx.ai.paths_hit


def test_ack_generate_non_owner_returns_403(ctx) -> None:
    _seed_donation(ctx.fake, provider_id="provider-OTHER", status="completed")
    ctx.fake.seed("claims", [{"id": "c1", "donation_id": "don-1", "ngo_id": "ngo-1",
                              "status": "completed"}])

    response = client_session.post("/api/v1/donations/don-1/acknowledgment/generate")

    assert response.status_code == 403


def test_ack_generate_requires_provider_role(ctx) -> None:
    _seed_donation(ctx.fake, status="completed")
    ctx.fake.seed("claims", [{"id": "c1", "donation_id": "don-1", "ngo_id": "ngo-1",
                              "status": "completed"}])
    _seed_ngo(ctx.fake, "ngo-1", with_hours=False)
    app.dependency_overrides[get_current_profile] = _ngo_profile

    response = client_session.post("/api/v1/donations/don-1/acknowledgment/generate")

    assert response.status_code == 403


def test_ack_generate_ai_unavailable_returns_503(ctx) -> None:
    _seed_completed_donations_for_ack(ctx)
    ctx.ai.raise_connect = True

    response = client_session.post("/api/v1/donations/don-1/acknowledgment/generate")

    assert response.status_code == 503


def test_ack_download_owner_returns_pdf(ctx) -> None:
    _seed_donation(ctx.fake, status="completed")

    response = client_session.get("/api/v1/donations/don-1/acknowledgment")

    assert response.status_code == 200
    assert response.content.startswith(b"%PDF-1.4")


def test_ack_download_non_owner_returns_403(ctx) -> None:
    _seed_donation(ctx.fake, provider_id="provider-OTHER")

    response = client_session.get("/api/v1/donations/don-1/acknowledgment")

    assert response.status_code == 403