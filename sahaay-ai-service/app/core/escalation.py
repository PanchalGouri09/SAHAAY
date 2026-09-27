"""
Auto-escalation logic.

The main backend calls this API periodically (e.g. via a cron job or
scheduled task) for every donation that is currently "pending" with an
NGO. This module decides whether to keep waiting, escalate to the next
NGO in the ranked list, confirm acceptance, or report that no NGOs are
left.

NOTE: This module is stateless — it does NOT store timers itself. The
main backend's database is the source of truth for `offer_sent_at` and
`current_ngo_index`; this service just applies the escalation rule to
whatever state is passed in. This keeps the AI service simple and
avoids having two systems disagree about donation state.
"""

from datetime import datetime, timezone

from app.config import ESCALATION_TIMEOUT_MINUTES
from app.models.schemas import EscalationCheckRequest, EscalationCheckResponse, EscalationStatus


def check_escalation(payload: EscalationCheckRequest) -> EscalationCheckResponse:
    timeout_minutes = payload.timeout_minutes or ESCALATION_TIMEOUT_MINUTES

    offer_sent_at = payload.offer_sent_at
    if offer_sent_at.tzinfo is None:
        offer_sent_at = offer_sent_at.replace(tzinfo=timezone.utc)
    now = datetime.now(timezone.utc)

    minutes_elapsed = round((now - offer_sent_at).total_seconds() / 60.0, 2)

    # Case 1: NGO already accepted — nothing to escalate.
    if payload.current_ngo_status == EscalationStatus.accepted:
        return EscalationCheckResponse(
            donation_id=payload.donation_id,
            action="accepted",
            minutes_elapsed=minutes_elapsed,
            message="Current NGO has already accepted this donation. No escalation needed.",
        )

    # Case 2: NGO explicitly rejected, or timeout has passed while still pending.
    should_escalate = (
        payload.current_ngo_status == EscalationStatus.rejected
        or (
            payload.current_ngo_status == EscalationStatus.pending
            and minutes_elapsed >= timeout_minutes
        )
    )

    if not should_escalate:
        remaining = round(timeout_minutes - minutes_elapsed, 2)
        return EscalationCheckResponse(
            donation_id=payload.donation_id,
            action="keep_waiting",
            minutes_elapsed=minutes_elapsed,
            message=f"Still within response window. {remaining} minute(s) remaining before escalation.",
        )

    next_index = payload.current_ngo_index + 1

    if next_index >= len(payload.ranked_ngo_ids):
        return EscalationCheckResponse(
            donation_id=payload.donation_id,
            action="no_ngos_left",
            minutes_elapsed=minutes_elapsed,
            message="All ranked NGOs have been exhausted. Manual intervention needed by the restaurant/admin.",
        )

    next_ngo_id = payload.ranked_ngo_ids[next_index]
    reason = "timed out" if payload.current_ngo_status == EscalationStatus.pending else "rejected the donation"

    return EscalationCheckResponse(
        donation_id=payload.donation_id,
        action="escalate",
        next_ngo_id=next_ngo_id,
        next_ngo_index=next_index,
        minutes_elapsed=minutes_elapsed,
        message=f"Current NGO {reason}. Escalating offer to next-ranked NGO ({next_ngo_id}).",
    )
