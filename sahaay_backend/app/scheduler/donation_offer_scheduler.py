"""Restart-safe polling of persisted NGO-offer deadlines."""

from __future__ import annotations

import asyncio
import logging

from app.services.ai_client import get_ai_client
from app.services.donation_offers import (
    expire_due_offers,
    match_unranked_donations,
)
from app.supabase_client import get_supabase_client

logger = logging.getLogger("sahaay.offer_scheduler")


class DonationOfferScheduler:
    def __init__(self, interval_seconds: float = 60.0) -> None:
        self._interval = max(1.0, float(interval_seconds))
        self._stop_event: asyncio.Event | None = None
        self._task: asyncio.Task | None = None

    @property
    def running(self) -> bool:
        return self._task is not None and not self._task.done()

    def start(self) -> None:
        if self.running:
            return
        self._stop_event = asyncio.Event()
        self._task = asyncio.create_task(self._run(), name="donation-offer-scheduler")
        logger.info("Donation-offer scheduler started (interval=%ss)", self._interval)

    async def stop(self) -> None:
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
            logger.exception("Donation-offer scheduler shutdown error")

    async def _run(self) -> None:
        while self._stop_event is not None and not self._stop_event.is_set():
            try:
                client = get_supabase_client()
                outcomes = await asyncio.to_thread(
                    self._run_sweep, client
                )
                logger.info(
                    "Donation workflow sweep: checked=%s advanced=%s "
                    "matching_attempted=%s matching_offered=%s",
                    outcomes["expiry"].get("checked"),
                    outcomes["expiry"].get("advanced"),
                    outcomes["matching"].get("attempted", 0),
                    outcomes["matching"].get("offered", 0),
                )
            except Exception as exc:  # noqa: BLE001
                logger.error(
                    "Donation-offer sweep failed (error_type=%s)",
                    type(exc).__name__,
                )
            if self._stop_event is None or self._stop_event.is_set():
                break
            try:
                await asyncio.wait_for(self._stop_event.wait(), timeout=self._interval)
            except asyncio.TimeoutError:
                continue

    @staticmethod
    def _run_sweep(client, ai_client=None) -> dict:
        expiry = expire_due_offers(client)
        try:
            matching = match_unranked_donations(
                client, ai_client if ai_client is not None else get_ai_client()
            )
        except Exception as exc:  # noqa: BLE001
            logger.error(
                "Automatic matching sweep failed (error_type=%s)",
                type(exc).__name__,
            )
            matching = {"error": type(exc).__name__}
        return {
            "expiry": expiry,
            "matching": matching,
        }
