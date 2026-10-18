from __future__ import annotations

import asyncio
import threading

from fastapi.testclient import TestClient

from app import main
from app.scheduler import donation_offer_scheduler as scheduler_module


def test_main_lifespan_starts_and_stops_offer_scheduler(monkeypatch):
    events = []

    class _Scheduler:
        def __init__(self, **_kwargs):
            pass

        def start(self):
            events.append("start")

        async def stop(self):
            events.append("stop")

    monkeypatch.setattr(main, "DonationOfferScheduler", _Scheduler)
    monkeypatch.setattr(main, "EscalationScheduler", _Scheduler)
    monkeypatch.setattr(main.settings, "donation_offer_scheduler_enabled", True)
    monkeypatch.setattr(main.settings, "escalation_scheduler_enabled", True)

    with TestClient(main.app):
        assert events == ["start", "start"]

    assert events == ["start", "start", "stop", "stop"]


def test_offer_scheduler_sweeps_persisted_deadlines_after_restart(monkeypatch):
    client = object()
    calls = []
    first_sweep = threading.Event()
    restarted_sweep = threading.Event()

    def sweep(actual_client):
        calls.append(actual_client)
        (first_sweep if len(calls) == 1 else restarted_sweep).set()
        return {"checked": 1, "advanced": 1}

    monkeypatch.setattr(scheduler_module, "get_supabase_client", lambda: client)
    monkeypatch.setattr(scheduler_module, "expire_due_offers", sweep)
    monkeypatch.setattr(
        scheduler_module,
        "get_ai_client",
        lambda: object(),
    )
    monkeypatch.setattr(
        scheduler_module,
        "match_unranked_donations",
        lambda actual_client, _ai_client: {
            "scanned": 0,
            "attempted": 0,
            "offered": 0,
        }
        if actual_client is client
        else None,
    )

    async def exercise_restart():
        first = scheduler_module.DonationOfferScheduler(interval_seconds=3600)
        first.start()
        assert await asyncio.to_thread(first_sweep.wait, 2)
        await first.stop()
        assert not first.running

        restarted = scheduler_module.DonationOfferScheduler(interval_seconds=3600)
        restarted.start()
        assert await asyncio.to_thread(restarted_sweep.wait, 2)
        await restarted.stop()
        assert not restarted.running

    asyncio.run(exercise_restart())
    assert calls == [client, client]


def test_offer_scheduler_sweep_runs_expiry_and_automatic_matching(monkeypatch):
    client = object()
    ai_client = object()
    events = []
    monkeypatch.setattr(
        scheduler_module,
        "expire_due_offers",
        lambda actual_client: events.append(("expire", actual_client))
        or {"checked": 2, "advanced": 1},
    )
    monkeypatch.setattr(
        scheduler_module,
        "match_unranked_donations",
        lambda actual_client, actual_ai_client: events.append(
            ("match", actual_client, actual_ai_client)
        )
        or {"scanned": 5, "attempted": 2, "offered": 1},
    )

    result = scheduler_module.DonationOfferScheduler._run_sweep(client, ai_client)

    assert result == {
        "expiry": {"checked": 2, "advanced": 1},
        "matching": {"scanned": 5, "attempted": 2, "offered": 1},
    }
    assert events == [
        ("expire", client),
        ("match", client, ai_client),
    ]
