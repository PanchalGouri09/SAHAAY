"""Escalation scheduler: an asyncio background loop over the shared service.

The scheduler is intentionally dumb and safe:
* It re-uses `app.services.escalation` — the same logic as the manual
  endpoint — so automatic and manual escalation can never diverge.
* The sweep runs in a worker thread (`asyncio.to_thread`) because the
  Supabase and AI clients are synchronous/blocking.
* One failing donation is isolated and logged; the loop keeps going.
* A single process runs one loop. The loop only starts from the FastAPI
  lifespan, never at import time, so tests (which build TestClient without
  entering the lifespan) never spawn background tasks.
"""

from __future__ import annotations

import asyncio
import logging
from typing import Callable

from app.services.ai_client import get_ai_client
from app.services.escalation import run_escalation_sweep
from app.supabase_client import get_supabase_client

logger = logging.getLogger("sahaay.scheduler")


def scheduler_sweep(client, ai_client) -> dict:
    """Standalone sweep wrapper used by the scheduler loop.

    Kept separate from `run_escalation_sweep` so tests can drive a single
    sweep with fully fake clients, while production wiring happens in
    `EscalationScheduler._run` via `get_supabase_client`/`get_ai_client`."""
    return run_escalation_sweep(client, ai_client)


class EscalationScheduler:
    """Asyncio background loop that periodically runs an escalation sweep."""

    def __init__(
        self,
        interval_seconds: float = 60.0,
        sweep: Callable[..., dict] | None = None,
    ) -> None:
        self._interval = max(1.0, float(interval_seconds))
        self._sweep = sweep or scheduler_sweep
        self._stop_event: asyncio.Event | None = None
        self._task: asyncio.Task | None = None
        self._started_on: str | None = None

    @property
    def running(self) -> bool:
        return self._task is not None and not self._task.done()

    def start(self, *, run_now: bool = False) -> None:
        """Starts the background loop. Safe to call twice (no duplicate loop).

        `run_now` runs one sweep immediately on the calling thread (used by
        tests / manual verification); the loop then continues on its cadence."""
        if self.running:
            return
        self._stop_event = asyncio.Event()
        if run_now:
            try:
                self._sweep(get_supabase_client(), get_ai_client())
            except Exception as exc:  # noqa: BLE001
                logger.exception("Immediate escalation sweep failed: %s", exc)
        self._task = asyncio.create_task(self._run(), name="escalation-scheduler")
        self._started_on = "lifespan"
        logger.info("Escalation scheduler started (interval=%ss)", self._interval)

    async def stop(self) -> None:
        """Stops the background loop and waits for it to finish."""
        if not self.running:
            return
        if self._stop_event:
            self._stop_event.set()
        task, self._task = self._task, None
        try:
            await asyncio.wait_for(asyncio.shield(task), timeout=10.0)
        except asyncio.TimeoutError:
            task.cancel()
        except Exception:  # noqa: BLE001
            logger.exception("Escalation scheduler shutdown error")
        logger.info("Escalation scheduler stopped.")

    async def _run(self) -> None:
        while self._stop_event is not None and not self._stop_event.is_set():
            await self._tick()
            if self._stop_event is None or self._stop_event.is_set():
                break
            try:
                await asyncio.wait_for(self._stop_event.wait(), timeout=self._interval)
            except asyncio.TimeoutError:
                continue

    async def _tick(self) -> dict:
        try:
            outcome = await asyncio.to_thread(self._sweep, get_supabase_client(), get_ai_client())
            logger.info(
                "Escalation sweep: checked=%s escalated=%s",
                outcome.get("checked"),
                outcome.get("escalated"),
            )
            return outcome
        except Exception as exc:  # noqa: BLE001
            logger.exception("Escalation sweep failed: %s", exc)
            return {"checked": 0, "escalated": 0, "results": []}


def make_scheduler() -> EscalationScheduler:
    """Builds the scheduler from server settings (used by the lifespan)."""
    from app.config import get_settings

    settings = get_settings()
    return EscalationScheduler(interval_seconds=settings.escalation_scheduler_interval_seconds)