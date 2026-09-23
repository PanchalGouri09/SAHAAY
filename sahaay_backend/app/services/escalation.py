"""
Shared auto-escalation logic for SAHAAY donations.

This single code path is used by BOTH the provider-triggered escalation check
(POST /api/v1/donations/{donation_id}/escalation-check) and the background
escalation scheduler. Keeping them in one function guarantees the manual and
automatic paths behave identically.

Honesty rules:
* the offer sequence comes only from real claims rows (arrival order).
* the response window (`offer_sent_at`) is derived from existing claim columns:
  accepted_at, then claimed_at, then created_at. Nothing is invented.
* escalation only ever rejects the current claim that is still `pending` — a
  row guard prevents double-escalation of an already rejected claim.
* the AI service remains the sole decision maker; this module only maps real
  state onto the AI contract and applies the decision safely.
* a claim is only rejected when the donation is still eligible (status
  'available' and not past its expiry_time). Once a donation is claimed,
  expired, cancelled or completed it is never escalated by the scheduler.
"""

from __future__ import annotations

from datetime import datetime, timezone

from app.schemas.ai import EscalationCheckRequest

_NO_CLAIMS_MESSAGE = (
    "This donation has no NGO claims yet, so there is nothing to escalate."
)
_NO_CURRENT_MESSAGE = "No claim is currently waiting for a response."


def parse_utc(value) -> datetime | None:
    """Tolerant parse of a PostgreSQL timestamp to an aware datetime.

    Returns None when the value is missing or malformed — callers treat that
    as "cannot verify", never as an invented deadline."""
    if value is None:
        return None
    if isinstance(value, datetime):
        return value if value.tzinfo else value.replace(tzinfo=timezone.utc)
    try:
        return datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except (TypeError, ValueError):
        return None


def is_expired(donation: dict, *, now: datetime | None = None) -> bool:
    """True when the donation's expiry_time has passed. A missing or malformed
    expiry_time is treated as NOT expired (we never invent a deadline)."""
    expiry = parse_utc(donation.get("expiry_time"))
    if expiry is None:
        return False
    now = now or datetime.now(timezone.utc)
    return expiry <= now


def eligible_for_escalation(donation: dict, *, now: datetime | None = None) -> bool:
    """A donation is only escalated while it is still being offered:
    status 'available' and not past its expiry_time."""
    if donation.get("status") != "available":
        return False
    return not is_expired(donation, now=now)


def _claims_of(client, donation_id: str) -> list[dict]:
    return (
        client.table("claims")
        .select("*")
        .eq("donation_id", donation_id)
        .execute()
        .data
        or []
    )


def _ranked_claims(claims: list[dict]) -> list[dict]:
    return sorted(
        claims,
        key=lambda c: c.get("created_at") or c.get("claimed_at") or datetime.min.isoformat(),
    )


def find_escalation_candidates(client, *, now: datetime | None = None) -> list[dict]:
    """Donations that currently need an escalation check:
    still being offered ('available', not expired) AND holding at least one
    pending claim (an NGO that has not answered yet)."""
    now = now or datetime.now(timezone.utc)
    donations = (
        client.table("donations")
        .select("*")
        .eq("status", "available")
        .execute()
        .data
        or []
    )
    ids = [d["id"] for d in donations if not is_expired(d, now=now)]
    if not ids:
        return []
    pending_claims = (
        client.table("claims")
        .select("donation_id")
        .in_("donation_id", ids)
        .eq("status", "pending")
        .execute()
        .data
        or []
    )
    pending_ids = {c["donation_id"] for c in pending_claims}
    return [d for d in donations if d["id"] in pending_ids]


def assess_donation_escalation(
    client,
    ai_client,
    donation: dict,
    *,
    now: datetime | None = None,
) -> dict:
    """Runs ONE escalation check for a donation and applies the decision.

    Returns the same response dictionary for both the manual endpoint and the
    scheduler. AI transport/validation failures propagate unchanged
    (AIServiceUnavailableError / AIServiceHTTPError / ValidationError) so each
    caller decides how to surface them.

    Idempotency: an 'escalate' decision only rejects the current claim while it
    is still pending (row-level guard). Once rejected, no second update or
    second escalation can touch it."""
    now = now or datetime.now(timezone.utc)
    donation_id = donation["id"]

    claims = _ranked_claims(_claims_of(client, donation_id))
    if not claims:
        return {
            "donation_id": donation_id,
            "action": "no_claims",
            "message": _NO_CLAIMS_MESSAGE,
        }

    ranked_ngo_ids = [str(c["ngo_id"]) for c in claims]
    current_index = next(
        (
            i
            for i, c in enumerate(claims)
            if c.get("status") in {"pending", "accepted"}
        ),
        None,
    )
    if current_index is None:
        first = claims[0].get("status")
        action = "accepted" if first in {"accepted", "completed"} else "no_ngos_left"
        return {
            "donation_id": donation_id,
            "action": action,
            "message": _NO_CURRENT_MESSAGE,
            "ranked_ngo_ids": ranked_ngo_ids,
        }

    current_claim = claims[current_index]
    offer_sent_at = current_claim.get("accepted_at") or current_claim.get(
        "claimed_at"
    ) or current_claim.get("created_at")
    parsed_offer = parse_utc(offer_sent_at)

    payload = EscalationCheckRequest(
        donation_id=donation_id,
        ranked_ngo_ids=ranked_ngo_ids,
        current_ngo_index=current_index,
        current_ngo_status=current_claim["status"],
        offer_sent_at=parsed_offer or now,
    )
    result = ai_client.check_escalation(payload)

    response = {
        "donation_id": result.donation_id,
        "action": result.action,
        "current_ngo_id": str(current_claim["ngo_id"]),
        "next_ngo_id": result.next_ngo_id,
        "next_ngo_index": result.next_ngo_index,
        "minutes_elapsed": result.minutes_elapsed,
        "message": result.message,
    }
    if result.action == "escalate" and eligible_for_escalation(donation, now=now):
        client.table("claims").update(
            {
                "status": "rejected",
                "rejection_reason": (
                    f"Auto-escalated: {result.message} "
                    f"(escalation checked at {datetime.now(timezone.utc).isoformat()})."
                ),
            }
        ).eq("id", current_claim["id"]).eq("donation_id", donation_id).eq(
            "status", "pending"
        ).execute()
    return response


def escalate_donation(client, ai_client, donation_id: str, *, now: datetime | None = None) -> dict:
    """Runs the shared escalation check for a single donation.

    Wraps AI failures as a controllable result so an automatic sweep can log a
    failed donation without aborting the sweep. Raises nothing the scheduler
    cannot handle."""
    donation = (
        client.table("donations")
        .select("*")
        .eq("id", donation_id)
        .maybe_single()
        .execute()
    )
    if donation is None:
        return {"donation_id": donation_id, "action": "not_found", "message": "Donation not found."}
    return assess_donation_escalation(client, ai_client, donation.data, now=now)


def run_escalation_sweep(client, ai_client, *, now: datetime | None = None) -> dict:
    """Escalates every eligible donation that needs it.

    One failing donation (AI unreachable, malformed row, transient DB error)
    is isolated by the try/except and never blocks the other donations."""
    now = now or datetime.now(timezone.utc)
    candidates = find_escalation_candidates(client, now=now)
    results = []
    for donation in candidates:
        try:
            results.append(
                {"donation_id": donation["id"], **assess_donation_escalation(client, ai_client, donation, now=now)}
            )
        except Exception as exc:  # noqa: BLE001
            results.append(
                {
                    "donation_id": donation["id"],
                    "action": "error",
                    "message": str(exc),
                }
            )
    return {
        "checked": len(candidates),
        "escalated": sum(1 for r in results if r.get("action") == "escalate"),
        "results": results,
    }