"""Durable, sequential NGO offers for newly matched donations."""

from __future__ import annotations

import logging
from math import isfinite
from datetime import datetime, timezone
from time import monotonic

from app.services import notification_service

logger = logging.getLogger("sahaay.donation_offers")

_MATCH_RETRY_INTERVAL_SECONDS = 300.0
_MATCH_SCAN_PAGE_SIZE = 20
_MATCH_PER_SWEEP_LIMIT = 3
_match_retry_after: dict[str, float] = {}
_match_scan_offset = 0

_SCORE_FIELDS = (
    "distance_km",
    "distance_source",
    "distance_score",
    "quantity_fit_score",
    "dietary_compatibility_score",
    "pickup_time_feasibility_score",
    "restaurant_reliability_score",
    "final_score",
    "provider_vehicle_available",
    "vehicle_compatibility",
    "vehicle_compatibility_label",
    "vehicle_compatibility_detail",
    "volunteer_transport_required",
)


def _ranked_candidate_rows(ranked_ngos: list[dict]) -> list[dict]:
    """Convert the already-validated ranking into durable, minimal records."""
    candidates = []
    seen: set[str] = set()
    for match_rank, item in enumerate(ranked_ngos, start=1):
        ngo_id = str(item.get("ngo_id") or "")
        if not ngo_id or ngo_id in seen:
            continue
        score = item.get("final_score")
        try:
            score = float(score)
        except (TypeError, ValueError, OverflowError):
            continue
        if not isfinite(score) or not 0 <= score <= 100:
            continue
        ai_rank = item.get("rank")
        if not isinstance(ai_rank, int) or ai_rank < 1:
            continue
        seen.add(ngo_id)
        candidates.append(
            {
                "ngo_id": ngo_id,
                "match_rank": match_rank,
                "ai_rank": ai_rank,
                "final_score": score,
                "score_details": {field: item.get(field) for field in _SCORE_FIELDS},
            }
        )
    return candidates


def _rpc_result(response) -> dict:
    data = getattr(response, "data", None)
    if isinstance(data, list):
        data = data[0] if data else None
    return data if isinstance(data, dict) else {}


def _notify_offer(client, *, offer: dict, donation: dict | None = None) -> None:
    """Notify only the NGO that owns the current active offer."""
    try:
        donation_id = offer.get("donation_id")
        ngo_id = offer.get("ngo_id")
        if not donation_id or not ngo_id:
            return
        donation = donation or _load_donation(client, donation_id)
        user_id = notification_service.user_id_for_ngo(client, ngo_id)
        title, message = notification_service.donation_notification_copy(
            "ngo_offer", (donation or {}).get("food_name")
        )
        notification_service.notify(
            client,
            user_id,
            title=title,
            message=message,
            notif_type="donation_offer",
            related_donation_id=donation_id,
            data={"screen": "my_offers"},
        )
    except Exception as exc:  # noqa: BLE001
        logger.warning("Could not notify NGO about donation offer: %s", exc)


def _load_donation(client, donation_id: str) -> dict | None:
    try:
        response = (
            client.table("donations")
            .select("*")
            .eq("id", str(donation_id))
            .maybe_single()
            .execute()
        )
        return getattr(response, "data", None)
    except Exception:  # noqa: BLE001
        return None


def _notify_provider_exhausted(client, donation_id: str) -> None:
    try:
        donation = _load_donation(client, donation_id)
        if not donation:
            return
        user_id = notification_service.user_id_for_provider(
            client, donation.get("provider_id")
        )
        title, message = notification_service.donation_notification_copy(
            "provider_exhausted", donation.get("food_name")
        )
        notification_service.notify(
            client,
            user_id,
            title=title,
            message=message,
            notif_type="donation_offers_exhausted",
            related_donation_id=donation_id,
            data={"screen": "my_donations"},
        )
    except Exception as exc:  # noqa: BLE001
        logger.warning("Could not notify provider that offers are exhausted: %s", exc)


def _notify_provider_no_match(client, donation_id: str) -> None:
    try:
        donation = _load_donation(client, donation_id)
        if not donation:
            return
        user_id = notification_service.user_id_for_provider(
            client, donation.get("provider_id")
        )
        title, message = notification_service.donation_notification_copy(
            "provider_no_match", donation.get("food_name")
        )
        notification_service.notify(
            client,
            user_id,
            title=title,
            message=message,
            notif_type="donation_no_match",
            related_donation_id=donation_id,
            data={"screen": "my_donations"},
        )
    except Exception as exc:  # noqa: BLE001
        logger.warning("Could not notify provider that no match was found: %s", exc)


def _notify_provider_offer_advanced(
    client, *, donation_id: str, outcome: str
) -> None:
    donation = _load_donation(client, donation_id)
    if not donation:
        return
    user_id = notification_service.user_id_for_provider(
        client, donation.get("provider_id")
    )
    event = "provider_declined" if outcome == "declined" else "provider_timed_out"
    title, message = notification_service.donation_notification_copy(
        event, donation.get("food_name")
    )
    notification_service.notify(
        client,
        user_id,
        title=title,
        message=message,
        notif_type="donation_offer",
        related_donation_id=donation_id,
        data={"screen": "my_donations"},
        dedupe=False,
    )


def _notify_provider_offer_closed(client, donation_id: str) -> None:
    donation = _load_donation(client, donation_id)
    if not donation:
        return
    user_id = notification_service.user_id_for_provider(
        client, donation.get("provider_id")
    )
    title, message = notification_service.donation_notification_copy(
        "provider_closed", donation.get("food_name")
    )
    notification_service.notify(
        client,
        user_id,
        title=title,
        message=message,
        notif_type="donation_offer",
        related_donation_id=donation_id,
        data={"screen": "my_donations"},
    )


def persist_ranked_candidates(client, *, donation_id: str, ranked_ngos: list[dict]) -> dict:
    """Atomically persist the candidate ranking and create its first offer."""
    candidates = _ranked_candidate_rows(ranked_ngos)
    response = client.rpc(
        "start_donation_offer_sequence",
        {"p_donation_id": str(donation_id), "p_candidates": candidates},
    ).execute()
    result = _rpc_result(response)
    offer = result.get("offer")
    if result.get("status") == "offered" and isinstance(offer, dict):
        _notify_offer(client, offer=offer)
    elif result.get("status") == "no_candidates":
        _notify_provider_no_match(client, donation_id)
    return result


def auto_start_offers_for_donation(
    client, *, donation: dict, profile: dict, ai_client
) -> dict:
    """Use the existing provider eligibility/ranking path after creation."""
    from app.routers.ai_features import _calculate_ngos_match

    result = _calculate_ngos_match(str(donation["id"]), profile, ai_client)
    if result.get("status") != "ok":
        return {
            "status": result.get("status", "skipped"),
            "reason": result.get("reason"),
        }
    return persist_ranked_candidates(
        client,
        donation_id=str(donation["id"]),
        ranked_ngos=result.get("ranked_ngos") or [],
    )


def match_unranked_donations(
    client, ai_client, *, force_retry: bool = False
) -> dict:
    """Retry open donations, extending saved rankings without reordering them.

    Creation normally starts matching immediately. This bounded sweep recovers
    from transient AI/database failures. Profile changes use ``force_retry`` to
    consider every open donation, including existing rankings; the database RPC
    appends newly eligible candidates while preserving all previous ranks.
    """
    global _match_scan_offset

    now_utc = datetime.now(timezone.utc).isoformat()
    pages: list[list[dict]] = []
    offset = 0 if force_retry else _match_scan_offset
    while True:
        donations = (
            client.table("donations")
            .select("id,provider_id")
            .eq("status", "available")
            .gt("expiry_time", now_utc)
            .order("created_at", desc=force_retry)
            .range(offset, offset + _MATCH_SCAN_PAGE_SIZE - 1)
            .execute()
            .data
            or []
        )
        if donations:
            pages.append(donations)
        if not force_retry or len(donations) < _MATCH_SCAN_PAGE_SIZE:
            if not force_retry:
                _match_scan_offset = (
                    0
                    if len(donations) < _MATCH_SCAN_PAGE_SIZE
                    else _match_scan_offset + _MATCH_SCAN_PAGE_SIZE
                )
            break
        offset += _MATCH_SCAN_PAGE_SIZE

    if not pages:
        return {"scanned": 0, "attempted": 0, "offered": 0}

    retry_now = monotonic()
    if len(_match_retry_after) > 5000:
        for key, value in list(_match_retry_after.items()):
            if value <= retry_now:
                del _match_retry_after[key]
    attempted = 0
    offered = 0
    scanned = 0

    for page in pages:
        scanned += len(page)
        donation_ids = [str(row["id"]) for row in page if row.get("id")]
        for donation in page:
            donation_id = str(donation.get("id") or "")
            provider_id = str(donation.get("provider_id") or "")
            if (
                not donation_id
                or not provider_id
                or (
                    not force_retry
                    and _match_retry_after.get(donation_id, 0) > retry_now
                )
                or (
                    not force_retry
                    and attempted >= _MATCH_PER_SWEEP_LIMIT
                )
            ):
                continue

            _match_retry_after[donation_id] = retry_now + _MATCH_RETRY_INTERVAL_SECONDS
            attempted += 1
            try:
                response = (
                    client.table("providers")
                    .select("*")
                    .eq("id", provider_id)
                    .maybe_single()
                    .execute()
                )
                provider = getattr(response, "data", None)
                if not provider:
                    logger.warning(
                        "Automatic matching skipped donation without provider profile"
                    )
                    continue
                result = auto_start_offers_for_donation(
                    client,
                    donation=donation,
                    profile={
                        "id": provider.get("user_id"),
                        "role": "provider",
                        "providers": [provider],
                    },
                    ai_client=ai_client,
                )
                if result.get("status") == "offered":
                    offered += 1
                elif result.get("status") in {"no_candidates", "insufficient_data"}:
                    logger.info(
                        "Automatic matching deferred donation status=%s",
                        result.get("status"),
                    )
            except Exception as exc:  # noqa: BLE001
                logger.warning(
                    "Automatic matching failed error_type=%s",
                    type(exc).__name__,
                )

    return {
        "scanned": scanned,
        "attempted": attempted,
        "offered": offered,
    }


def _notify_response_result(client, result: dict) -> None:
    if not result.get("changed"):
        return

    donation_id = result.get("donation_id")
    if result.get("status") == "accepted":
        claim = result.get("claim")
        if claim:
            notification_service.claim_status_changed(
                client,
                claim=claim,
                new_status="accepted",
                donation=_load_donation(client, donation_id) if donation_id else None,
                other_pending_ngo_ids=result.get("other_pending_ngo_ids") or [],
            )
        return

    if result.get("status") == "expired" and donation_id:
        _notify_provider_offer_closed(client, str(donation_id))
        return

    next_offer = result.get("next_offer")
    if isinstance(next_offer, dict):
        if result.get("status") in {"declined", "timed_out"} and donation_id:
            _notify_provider_offer_advanced(
                client,
                donation_id=str(donation_id),
                outcome=str(result["status"]),
            )
        _notify_offer(client, offer=next_offer)
    elif result.get("status") in {"declined", "timed_out", "exhausted"} and donation_id:
        _notify_provider_exhausted(client, str(donation_id))


def respond_to_offer(
    client, *, offer_id: str, ngo_id: str | None, decision: str
) -> dict:
    """Delegate the transition to the database's row-locking RPC."""
    response = client.rpc(
        "respond_to_donation_offer",
        {
            "p_offer_id": str(offer_id),
            # PostgreSQL expects NULL for provider/scheduler timeouts; the
            # literal string "None" is not a valid UUID and makes the RPC fail.
            "p_ngo_id": str(ngo_id) if ngo_id is not None else None,
            "p_decision": decision,
        },
    ).execute()
    result = _rpc_result(response)
    _notify_response_result(client, result)
    return result


def expire_due_offers(client, *, limit: int = 100) -> dict:
    """Advance expired offers using the database clock and row-locking RPC."""
    response = client.rpc(
        "expire_due_donation_offers", {"p_limit": limit}
    ).execute()
    result = _rpc_result(response)
    transitions = result.get("results") or []
    for transition in transitions:
        if isinstance(transition, dict):
            _notify_response_result(client, transition)
    return {
        "checked": int(result.get("checked") or 0),
        "advanced": int(result.get("advanced") or 0),
    }
