"""
Escalation scheduler + shared-escalation-service tests.

Covers the automatic-escalation task both at the scheduler level (asyncio
lifecycle, sweep selection, idempotency) and at the shared-service level
(the SAME code path the manual endpoint and scheduler both use).

The AI service is stubbed to mirror its real rule (>=15 minutes since
offer_sent_at => escalate past keep_waiting), so these tests exercise real
timing logic without any sleeping. No background task is ever spawned in
these tests (the lifespan only runs inside `with TestClient(app)`).
"""

from __future__ import annotations

import asyncio
from datetime import datetime, timedelta, timezone

import pytest

from app.schemas.ai import EscalationCheckResponse
from app.services.ai_client import AIServiceUnavailableError
from app.services.escalation import (
    assess_donation_escalation,
    find_escalation_candidates,
    run_escalation_sweep,
)
from app.scheduler.escalation_scheduler import EscalationScheduler


# ---------------------------------------------------------------------------
# Fakes
# ---------------------------------------------------------------------------
class _FakeTable:
    def __init__(self, rows: list[dict]) -> None:
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
            return type("R", (), {"data": rows[0] if rows else {}})()
        if self._single == "maybe":
            if not rows:
                return None
            return type("R", (), {"data": rows[0]})()
        if self._single == "single":
            return type("R", (), {"data": rows[0] if rows else {}})()
        return type("R", (), {"data": rows})()


class _FakeSupabase:
    def __init__(self) -> None:
        self.tables: dict[str, list[dict]] = {}

    def table(self, name: str) -> _FakeTable:
        return _FakeTable(self.tables.setdefault(name, []))

    def seed(self, name: str, rows: list[dict]) -> None:
        self.tables.setdefault(name, []).extend(list(rows))


class _StubAI:
    """Mirrors the real AI escalation rule: escalate once offer_sent_at is
    >= 15 minutes old (past keep_waiting), else keep_waiting."""

    ACTION_TIMEOUT_MINUTES = 15.0
    NOW = datetime.now(timezone.utc)

    def __init__(self, *, error: Exception | None = None) -> None:
        self.error = error
        self.requests: list = []

    def check_escalation(self, payload):
        self.requests.append(payload)
        if self.error is not None:
            raise self.error
        offer = payload.offer_sent_at
        if offer.tzinfo is None:
            offer = offer.replace(tzinfo=timezone.utc)
        elapsed = (datetime.now(timezone.utc) - offer).total_seconds() / 60.0
        idx = payload.current_ngo_index
        ngo_ids = payload.ranked_ngo_ids
        if payload.current_ngo_status == "accepted":
            return EscalationCheckResponse(
                donation_id=payload.donation_id,
                action="accepted",
                minutes_elapsed=round(elapsed, 2),
                message="action: accepted",
            )
        if elapsed >= self.ACTION_TIMEOUT_MINUTES:
            nxt = idx + 1
            if nxt < len(ngo_ids):
                return EscalationCheckResponse(
                    donation_id=payload.donation_id,
                    action="escalate",
                    next_ngo_id=ngo_ids[nxt],
                    next_ngo_index=nxt,
                    minutes_elapsed=round(elapsed, 2),
                    message="action: escalate",
                )
            return EscalationCheckResponse(
                donation_id=payload.donation_id,
                action="no_ngos_left",
                minutes_elapsed=round(elapsed, 2),
                message="action: no_ngos_left",
            )
        return EscalationCheckResponse(
            donation_id=payload.donation_id,
            action="keep_waiting",
            minutes_elapsed=round(elapsed, 2),
            message="action: keep_waiting",
        )


def _now_iso(ago_minutes: float = 0.0) -> str:
    return (datetime.now(timezone.utc) - timedelta(minutes=ago_minutes)).isoformat()


def _donation(donation_id: str = "don-1", **overrides) -> dict:
    row = {
        "id": donation_id,
        "provider_id": "provider-1",
        "status": "available",
        "expiry_time": (datetime.now(timezone.utc) + timedelta(days=1)).isoformat(),
    }
    row.update(overrides)
    return row


def _claim(claim_id: str, donation_id: str, ngo_id: str, ago_minutes: float = 2.0, **overrides) -> dict:
    row = {
        "id": claim_id,
        "donation_id": donation_id,
        "ngo_id": ngo_id,
        "status": "pending",
        "claimed_at": _now_iso(ago_minutes),
        "created_at": _now_iso(ago_minutes),
    }
    row.update(overrides)
    return row


def _build(client, ai) -> None:
    """Standard two-NGO-two-claim setup used by most cases."""
    client.seed("donations", [_donation()])
    client.seed(
        "claims",
        [
            _claim("c1", "don-1", "ngo-1", ago_minutes=120.0),
            _claim("c2", "don-1", "ngo-2", ago_minutes=1.0),
        ],
    )


# ===========================================================================
# Scheduler lifecycle (no real waiting)
# ===========================================================================
def test_scheduler_starts_and_stops():
    calls: list[int] = []

    def fake_sweep(client, ai_client) -> dict:
        calls.append(1)
        return {"checked": 0, "escalated": 0, "results": []}

    from app.scheduler.escalation_scheduler import EscalationScheduler as _E

    async def scenario():
        scheduler = _E(interval_seconds=60.0, sweep=fake_sweep)
        assert not scheduler.running
        scheduler.start()
        assert scheduler.running
        scheduler.start()  # duplicate start must NOT launch a second loop
        assert scheduler.running
        await scheduler.stop()
        assert not scheduler.running
        assert len(calls) <= 1  # a single sweep may (or may not) have run

    asyncio.run(scenario())


def test_scheduler_runs_a_real_sweep_via_tick(monkeypatch):
    from app.scheduler import escalation_scheduler as sched_mod

    client = _FakeSupabase()
    ai = _StubAI()
    _build(client, ai)
    monkeypatch.setattr(sched_mod, "get_supabase_client", lambda: client)
    monkeypatch.setattr(sched_mod, "get_ai_client", lambda: ai)

    async def scenario():
        scheduler = EscalationScheduler(
            interval_seconds=60.0,
            sweep=lambda c, a: run_escalation_sweep(c, a),
        )
        outcome = await scheduler._tick()
        assert outcome["checked"] == 1
        assert outcome["escalated"] == 1
        assert client.tables["claims"][0]["status"] == "rejected"

    asyncio.run(scenario())


# ===========================================================================
# Candidate selection
# ===========================================================================
def test_candidate_selection_stale_pending_claim_detected():
    client = _FakeSupabase()
    _build(client, _StubAI())
    candidates = find_escalation_candidates(client)
    assert [d["id"] for d in candidates] == ["don-1"]


def test_candidate_selection_skips_donation_with_no_pending_claim():
    client = _FakeSupabase()
    client.seed("donations", [_donation()])
    client.seed("claims", [_claim("c1", "don-1", "ngo-1", status="accepted")])
    assert find_escalation_candidates(client) == []


def test_candidate_selection_skips_expired_donation():
    client = _FakeSupabase()
    client.seed(
        "donations",
        [_donation("don-1", expiry_time=(datetime.now(timezone.utc) - timedelta(hours=1)).isoformat())],
    )
    client.seed("claims", [_claim("c1", "don-1", "ngo-1", ago_minutes=120.0)])
    assert find_escalation_candidates(client) == []


def test_candidate_selection_skips_completed_donation():
    client = _FakeSupabase()
    client.seed("donations", [_donation("don-1", status="completed")])
    client.seed("claims", [_claim("c1", "don-1", "ngo-1", ago_minutes=120.0)])
    assert find_escalation_candidates(client) == []


# ===========================================================================
# Shared service behaviour (used by BOTH endpoint and scheduler)
# ===========================================================================
def test_fresh_claim_is_kept_waiting_and_not_mutated():
    client = _FakeSupabase()
    ai = _StubAI()
    client.seed("donations", [_donation()])
    client.seed("claims", [_claim("c1", "don-1", "ngo-1", ago_minutes=2.0)])
    outcome = run_escalation_sweep(client, ai)
    assert outcome["checked"] == 1
    assert outcome["escalated"] == 0
    assert outcome["results"][0]["action"] == "keep_waiting"
    assert client.tables["claims"][0]["status"] == "pending"


def test_stale_claim_is_escalated_and_rejected():
    client = _FakeSupabase()
    ai = _StubAI()
    _build(client, ai)
    outcome = run_escalation_sweep(client, ai)
    assert outcome["escalated"] == 1
    assert outcome["results"][0]["action"] == "escalate"
    claim = client.tables["claims"][0]
    assert claim["status"] == "rejected"
    assert "Auto-escalated" in claim["rejection_reason"]


def test_accepted_claim_is_not_mutated():
    client = _FakeSupabase()
    ai = _StubAI()
    client.seed("donations", [_donation()])
    client.seed("claims", [_claim("c1", "don-1", "ngo-1", ago_minutes=120.0, status="accepted")])
    # Accepted claim -> candidate filter removes it (no pending), so a sweep
    # never touches it; a direct manual-style check also reports 'accepted'
    # without rejecting anything.
    donation = client.tables["donations"][0]
    result = assess_donation_escalation(client, ai, donation)
    assert result["action"] == "accepted"
    assert client.tables["claims"][0]["status"] == "accepted"


def test_escalation_does_not_happen_twice():
    client = _FakeSupabase()
    ai = _StubAI()
    _build(client, ai)
    first = run_escalation_sweep(client, ai)
    assert first["escalated"] == 1
    second = run_escalation_sweep(client, ai)
    assert second["checked"] == 1  # c2 is still pending (fresh) -> candidate
    assert second["escalated"] == 0
    assert second["results"][0]["action"] == "keep_waiting"
    assert client.tables["claims"][0]["status"] == "rejected"


def test_no_double_rejection_when_claim_updates_are_replayed():
    client = _FakeSupabase()
    ai = _StubAI()
    _build(client, ai)
    run_escalation_sweep(client, ai)
    reason = client.tables["claims"][0]["rejection_reason"]
    assess_donation_escalation(client, ai, client.tables["donations"][0])
    assert client.tables["claims"][0]["rejection_reason"] == reason
    assert client.tables["claims"][0]["status"] == "rejected"


def test_multiple_donations_processed_independently():
    client = _FakeSupabase()
    ai = _StubAI()
    client.seed(
        "donations",
        [_donation("don-1"), _donation("don-2")],
    )
    client.seed(
        "claims",
        [
            _claim("c1", "don-1", "ngo-1", ago_minutes=120.0),
            _claim("c2", "don-1", "ngo-2", ago_minutes=1.0),
            _claim("c3", "don-2", "ngo-3", ago_minutes=90.0),
            _claim("c4", "don-2", "ngo-4", ago_minutes=1.0),
        ],
    )
    outcome = run_escalation_sweep(client, ai)
    assert outcome["checked"] == 2
    assert outcome["escalated"] == 2
    by_id = {c["id"]: c for c in client.tables["claims"]}
    assert by_id["c1"]["status"] == "rejected"
    assert by_id["c3"]["status"] == "rejected"


def test_ai_failure_is_isolated_and_does_not_block_other_donations():
    client = _FakeSupabase()
    client.seed("donations", [_donation("don-1"), _donation("don-2")])
    client.seed(
        "claims",
        [
            _claim("c1", "don-1", "ngo-1", ago_minutes=120.0),
            _claim("c3", "don-2", "ngo-2", ago_minutes=90.0),
        ],
    )
    failing = _StubAI(error=AIServiceUnavailableError())
    outcome = run_escalation_sweep(client, failing, now=datetime.now(timezone.utc))
    assert outcome["checked"] == 2
    assert outcome["escalated"] == 0
    assert all(r["action"] == "error" for r in outcome["results"])
    assert client.tables["claims"][0]["status"] == "pending"


def test_ai_failure_partial_keeps_working_donation_processed():
    client = _FakeSupabase()
    client.seed("donations", [_donation("don-1"), _donation("don-2")])
    client.seed(
        "claims",
        [
            _claim("c1", "don-1", "ngo-1", ago_minutes=120.0),
            _claim("c2", "don-1", "ngo-2", ago_minutes=1.0),
            _claim("c3", "don-2", "ngo-3", ago_minutes=90.0),
            _claim("c4", "don-2", "ngo-4", ago_minutes=1.0),
        ],
    )
    good = _StubAI()
    # First donation hits the failing AI, second hits the live AI.
    class _MixedAI:
        def __init__(self):
            self.requests = []

        def check_escalation(self, payload):
            self.requests.append(payload)
            if payload.donation_id == "don-1":
                raise AIServiceUnavailableError()
            return good.check_escalation(payload)

    outcome = run_escalation_sweep(client, _MixedAI(), now=datetime.now(timezone.utc))
    assert outcome["checked"] == 2
    assert outcome["escalated"] == 1
    assert outcome["results"][0]["action"] == "error"
    assert outcome["results"][1]["action"] == "escalate"
    assert client.tables["claims"][0]["status"] == "pending"  # don-1 untouched
    assert client.tables["claims"][2]["status"] == "rejected"  # don-2 escalated


def test_missing_rows_do_not_crash_and_no_claims_short_circuits():
    client = _FakeSupabase()
    ai = _StubAI()
    outcome = run_escalation_sweep(client, ai)
    assert outcome == {"checked": 0, "escalated": 0, "results": []}

    client.seed("donations", [_donation()])
    result = assess_donation_escalation(client, ai, client.tables["donations"][0])
    assert result["action"] == "no_claims"
    assert ai.requests == []


def test_missing_claim_timestamps_fallback_safely():
    client = _FakeSupabase()
    ai = _StubAI()
    client.seed("donations", [_donation()])
    client.seed(
        "claims",
        [{"id": "c1", "donation_id": "don-1", "ngo_id": "ngo-1", "status": "pending"}],
    )
    outcome = run_escalation_sweep(client, ai)
    # Missing timestamps -> offer_sent_at falls back to now -> still waiting.
    assert outcome["checked"] == 1
    assert outcome["escalated"] == 0


def test_last_ngo_returns_no_ngos_left_without_mutation():
    client = _FakeSupabase()
    ai = _StubAI()
    client.seed("donations", [_donation()])
    client.seed("claims", [_claim("c1", "don-1", "ngo-1", ago_minutes=120.0)])
    result = run_escalation_sweep(client, ai)
    assert result["results"][0]["action"] == "no_ngos_left"
    assert client.tables["claims"][0]["status"] == "pending"


# ===========================================================================
# Manual endpoint uses the SAME shared logic as the scheduler
# ===========================================================================
def test_manual_endpoint_and_scheduler_share_the_same_service():
    import app.routers.ai_features as router_mod
    import app.services.escalation as service_mod

    assert router_mod.assess_donation_escalation is service_mod.assess_donation_escalation
    assert service_mod.run_escalation_sweep is not None  # scheduler entry point


def test_manual_endpoint_still_applies_same_escalation_as_scheduler():
    from fastapi.testclient import TestClient

    from app.dependencies import get_current_profile
    from app.main import app

    client = _FakeSupabase()
    client.seed(
        "donations",
        [
            {
                "id": "don-1",
                "provider_id": "provider-1",
                "status": "available",
                "expiry_time": (datetime.now(timezone.utc) + timedelta(days=1)).isoformat(),
            }
        ],
    )
    client.seed(
        "claims",
        [
            _claim("c1", "don-1", "ngo-1", ago_minutes=120.0),
            _claim("c2", "don-1", "ngo-2", ago_minutes=1.0),
        ],
    )

    profile = {"id": "user-1", "role": "provider", "providers": [{"id": "provider-1"}]}

    import httpx

    from app.services.ai_client import AIClient

    app.dependency_overrides[get_current_profile] = lambda: profile

    class _Transport:
        def __init__(self):
            self.requests = []

        def handle_request(self, request: httpx.Request) -> httpx.Response:
            self.requests.append(request)
            import json

            body = json.loads(request.content)
            offer = datetime.fromisoformat(body["offer_sent_at"].replace("Z", "+00:00"))
            elapsed = (datetime.now(timezone.utc) - offer).total_seconds() / 60.0
            from fastapi import status

            next_id = None
            next_idx = None
            if elapsed >= 15:
                if body["current_ngo_index"] + 1 < len(body["ranked_ngo_ids"]):
                    action = "escalate"
                    next_id = body["ranked_ngo_ids"][body["current_ngo_index"] + 1]
                    next_idx = body["current_ngo_index"] + 1
                else:
                    action = "no_ngos_left"
            else:
                action = "keep_waiting"
            return httpx.Response(
                status.HTTP_200_OK,
                json={
                    "donation_id": body["donation_id"],
                    "action": action,
                    "next_ngo_id": next_id,
                    "next_ngo_index": next_idx,
                    "minutes_elapsed": round(elapsed, 2),
                    "message": f"action: {action}",
                },
            )

    transport = _Transport()

    import app.routers.ai_features as router_mod
    import app.supabase_client as supabase_mod

    original_get = router_mod.get_supabase_client
    original_supabase = supabase_mod.get_supabase_client
    router_mod.get_supabase_client = lambda: client
    supabase_mod.get_supabase_client = lambda: client
    try:
        from app.services.ai_client import get_ai_client

        app.dependency_overrides[get_ai_client] = lambda: AIClient(
            base_url="http://ai.test", timeout=5.0, transport=httpx.MockTransport(transport.handle_request)
        )
        with TestClient(app) as test_client:
            response = test_client.post("/api/v1/donations/don-1/escalation-check")
            assert response.status_code == 200
            body = response.json()
            assert body["action"] == "escalate"
            assert client.tables["claims"][0]["status"] == "rejected"
            assert "Auto-escalated" in client.tables["claims"][0]["rejection_reason"]
    finally:
        router_mod.get_supabase_client = original_get
        supabase_mod.get_supabase_client = original_supabase
        app.dependency_overrides.clear()


def test_manual_endpoint_non_owner_still_403():
    from fastapi.testclient import TestClient

    from app.dependencies import get_current_profile
    from app.main import app

    client = _FakeSupabase()
    client.seed(
        "donations",
        [
            {
                "id": "don-1",
                "provider_id": "provider-OTHER",
                "status": "available",
                "expiry_time": (datetime.now(timezone.utc) + timedelta(days=1)).isoformat(),
            }
        ],
    )
    client.seed("claims", [_claim("c1", "don-1", "ngo-1", ago_minutes=120.0)])
    profile = {"id": "user-1", "role": "provider", "providers": [{"id": "provider-1"}]}
    app.dependency_overrides[get_current_profile] = lambda: profile

    import app.routers.ai_features as router_mod
    import app.supabase_client as supabase_mod

    orig_router = router_mod.get_supabase_client
    orig_supabase = supabase_mod.get_supabase_client
    router_mod.get_supabase_client = lambda: client
    supabase_mod.get_supabase_client = lambda: client
    try:
        with TestClient(app) as test_client:
            response = test_client.post("/api/v1/donations/don-1/escalation-check")
            assert response.status_code == 403
    finally:
        router_mod.get_supabase_client = orig_router
        supabase_mod.get_supabase_client = orig_supabase
        app.dependency_overrides.clear()