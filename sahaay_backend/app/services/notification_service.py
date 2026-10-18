"""Server-side notification pipeline for real business events.

Every SAHAAY notification follows the same ordering, and the ordering is the
point:

    business event (router/service)
        -> persist a row in `notifications`   (the source of truth)
        -> best-effort FCM push to that user's registered device tokens
        -> Flutter reads/paginates the table via GET /api/v1/notifications
        -> mark read via PATCH /api/v1/notifications/{id}/read

Design rules enforced here:

* The RECIPIENT is always derived server-side from database relationships
  (`providers.user_id`, `ngos.user_id`, `volunteers.user_id` — never from a
  request body field).
* Nothing in this module ever raises. FCM being unconfigured, an unreachable
  Firebase API, or a transient database error must never roll back or fail the
  business transaction that triggered the event.
* The push happens only AFTER the record has been persisted, so an FCM push can
  never exist without a durable row behind it (the table is what the app
  renders; the push is a wake-up).
* Duplicate suppression: the same (user, type, donation, title) tuple is only
  ever inserted once, so repeated identical events (re-published tasks, repeated
  status pokes) cannot spam a user. Different titles on the same donation —
  e.g. two different NGOs claiming — are different events and are both kept.
* No notification is ever sent for merely viewing or ranking data; only the
  event functions below exist, and each is called from a real state change.
"""

from __future__ import annotations

import logging
import re

from app.services.profile_completion import ngo_profile_is_complete

try:  # FCM push is optional in this build; the durable row is the source of truth.
    from app.services import fcm_sender
except ImportError:  # pragma: no cover - push transport absent
    fcm_sender = None

logger = logging.getLogger("sahaay.notifications")

_UNSAFE_COPY_PATTERNS = (
    re.compile(r"\b[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\b", re.IGNORECASE),
    re.compile(r"\b(?:don|ngo|claim|offer|user|prov|delivery|vol|notif)-[a-z0-9_-]+\b", re.IGNORECASE),
    re.compile(
        r"\b(?:donation|ngo|claim|offer|user|provider|delivery|notification)"
        r"\s+(?:id|uuid)\s*[:=#]?\s*[a-z0-9_-]+\b",
        re.IGNORECASE,
    ),
    re.compile(r"\b(?:id|identifier|uuid|token)\s*[:=#]\s*[a-z0-9_-]+\b", re.IGNORECASE),
    re.compile(r"\b\d{12,}\b"),
    re.compile(r"\beyJ[a-zA-Z0-9_-]{10,}\.[a-zA-Z0-9_-]{10,}(?:\.[a-zA-Z0-9_-]+)?\b"),
    re.compile(r"\b[a-zA-Z0-9_-]{32,}\b"),
    re.compile(r"[\[\]{}]"),
    re.compile(r"\b[a-zA-Z_]*(?:Error|Exception)\b"),
    re.compile(r"\b(?:request|correlation|trace|log)\s*(?:id|identifier)\b", re.IGNORECASE),
    re.compile(
        r"\b(traceback|exception|apierror|postgrest|sqlstate|stack trace|"
        r"internal server error|debug|supabase|firebase|http\s*[45]\d\d)\b",
        re.IGNORECASE,
    ),
)


def _safe_notification_copy(value: str, fallback: str, *, max_length: int) -> str:
    """Keep diagnostic identifiers and machine output out of user-visible copy."""
    text = " ".join(str(value).split())
    if (
        not text
        or len(text) > max_length
        or any(pattern.search(text) for pattern in _UNSAFE_COPY_PATTERNS)
    ):
        return fallback
    return text


def safe_notification_copy(title: str, message: str) -> tuple[str, str]:
    """Return readable copy, replacing opaque or technical content with a safe fallback."""
    return (
        _safe_notification_copy(title, "SAHAAY update", max_length=120),
        _safe_notification_copy(
            message,
            "There is an update about your donation. Open SAHAAY to see the latest status.",
            max_length=500,
        ),
    )


def donation_notification_copy(
    event: str,
    food_name: str | None = None,
    organization_name: str | None = None,
) -> tuple[str, str]:
    """Return concise, recipient-appropriate copy for donation offer events."""
    food = _safe_notification_copy(food_name or "", "", max_length=100)
    named_food = f" {food}" if food else ""
    organization = _safe_notification_copy(
        organization_name or "", "", max_length=100
    )

    if event == "ngo_offer":
        title = "A food donation is available"
        body = (
            f"{food} is available for pickup. Review the details and respond "
            "before the offer expires."
            if food
            else "A food donation is available for pickup. Review the details and "
            "respond before the offer expires."
        )
    elif event == "provider_accepted":
        title = "Your donation has been accepted!"
        accepting_ngo = organization or "An NGO"
        body = (
            f"{accepting_ngo} has accepted your{named_food} donation. Open SAHAAY to view "
            "the handover details."
        )
    elif event == "ngo_accepted":
        title = "Donation confirmed"
        body = (
            f"Your claim for {food} is confirmed. Open SAHAAY to view pickup and "
            "handover details."
            if food
            else "Your claim is confirmed. Open SAHAAY to view pickup and handover "
            "details."
        )
    elif event == "provider_no_match":
        title = "No NGO match yet"
        body = (
            f"We couldn't find an eligible NGO for your{named_food} donation. "
            "Open SAHAAY to review your options."
        )
    elif event == "provider_exhausted":
        title = "No NGO match yet"
        body = (
            f"We couldn't find another eligible NGO for your{named_food} donation. "
            "Open SAHAAY to review your options."
        )
    elif event == "provider_declined":
        title = "Finding your next NGO match"
        body = (
            f"An NGO declined the offer for {food}. We're offering it to the next "
            "eligible NGO."
            if food
            else "An NGO declined the offer. We're offering it to the next eligible "
            "NGO."
        )
    elif event == "provider_timed_out":
        title = "Finding your next NGO match"
        body = (
            f"The offer for {food} expired after no response. "
            "We're offering it to the next "
            "eligible NGO."
            if food
            else "The offer expired after no response. "
            "We're offering the donation to the next "
            "eligible NGO."
        )
    elif event == "provider_closed":
        title = "Offer closed"
        body = (
            f"The offer for {food} was closed because the donation is no longer "
            "available."
            if food
            else "The offer was closed because the donation is no longer available."
        )
    elif event == "ngo_response_window_closed":
        title = "Offer response window closed"
        body = (
            f"The response period for your{named_food} claim has ended. Open SAHAAY "
            "to review the latest status."
        )
    else:
        raise ValueError(f"Unsupported donation notification event: {event}")

    return title, body


# ---------------------------------------------------------------------------
# Recipient resolution (server-side identity chain only)
# ---------------------------------------------------------------------------
def user_id_for_provider(client, provider_id) -> str | None:
    """users.id owning a providers row, or None when it cannot be resolved."""
    if not provider_id:
        return None
    try:
        row = (
            client.table("providers")
            .select("user_id")
            .eq("id", str(provider_id))
            .maybe_single()
            .execute()
        )
        data = getattr(row, "data", None)
        if not data:
            return None
        return data.get("user_id")
    except Exception:  # noqa: BLE001
        return None


def user_id_for_ngo(client, ngo_id) -> str | None:
    """users.id owning an ngos row, or None when it cannot be resolved."""
    if not ngo_id:
        return None
    try:
        row = (
            client.table("ngos")
            .select("user_id")
            .eq("id", str(ngo_id))
            .maybe_single()
            .execute()
        )
        data = getattr(row, "data", None)
        if not data:
            return None
        return data.get("user_id")
    except Exception:  # noqa: BLE001
        return None


def ngo_display_name(client, ngo_id) -> str | None:
    """Return a safe public organization name when it is available."""
    if not ngo_id:
        return None
    try:
        row = (
            client.table("ngos")
            .select("organization_name")
            .eq("id", str(ngo_id))
            .maybe_single()
            .execute()
        )
        data = getattr(row, "data", None)
        if not data:
            return None
        name = _safe_notification_copy(
            data.get("organization_name") or "", "", max_length=100
        )
        return name or None
    except Exception:  # noqa: BLE001
        return None


def user_id_for_volunteer(client, volunteer_id) -> str | None:
    """users.id owning a volunteers row, or None when it cannot be resolved."""
    if not volunteer_id:
        return None
    try:
        row = (
            client.table("volunteers")
            .select("user_id")
            .eq("id", str(volunteer_id))
            .maybe_single()
            .execute()
        )
        data = getattr(row, "data", None)
        if not data:
            return None
        return data.get("user_id")
    except Exception:  # noqa: BLE001
        return None


# ---------------------------------------------------------------------------
# Persistence + push primitives
# ---------------------------------------------------------------------------
def _already_notified(
    client,
    *,
    user_id: str,
    notif_type: str | None,
    related_donation_id,
    title: str,
) -> bool:
    """True when an identical (user, type, donation, title) row exists."""
    try:
        query = client.table("notifications").select("id").eq("user_id", user_id)
        if related_donation_id is not None:
            query = query.eq("related_donation_id", str(related_donation_id))
        if notif_type is not None:
            query = query.eq("type", notif_type)
        else:
            query = query.is_("type", None)
        query = query.eq("title", title)
        rows = getattr(query.execute(), "data", None) or []
        return bool(rows)
    except Exception:  # noqa: BLE001
        # If the duplicate check itself cannot run, the caller still tries the
        # insert; the insert path is separately guarded.
        return False


def notify(
    client,
    user_id: str | None,
    *,
    title: str,
    message: str,
    notif_type: str | None = None,
    related_donation_id=None,
    data: dict | None = None,
    dedupe: bool = True,
) -> dict | None:
    """Persists one notification for a resolved recipient, then pushes it.

    Returns the persisted row (or None when skipped/failed). NEVER raises:
    every stage is guarded so a notification problem can never break the
    business operation that produced the event.
    """
    if not user_id or not title or not message:
        return None
    title, message = safe_notification_copy(title, message)
    try:
        if dedupe and related_donation_id is not None and notif_type is not None:
            if _already_notified(
                client,
                user_id=user_id,
                notif_type=notif_type,
                related_donation_id=related_donation_id,
                title=title,
            ):
                return None
        response = (
            client.table("notifications")
            .insert(
                {
                    "user_id": str(user_id),
                    "title": title,
                    "message": message,
                    "type": notif_type,
                    "related_donation_id": (
                        str(related_donation_id)
                        if related_donation_id is not None
                        else None
                    ),
                    "is_read": False,
                }
            )
            .select()
            .execute()
        )
        rows = getattr(response, "data", None) or []
        row = rows[0] if rows else None
    except Exception as exc:  # noqa: BLE001
        logger.warning(
            "Failed to persist notification for user %s (%s): %s",
            user_id,
            notif_type,
            exc,
        )
        # Without a durable row there is nothing for the app to render or mark
        # read, so the push is deliberately skipped rather than sending an
        # orphan message.
        return None

    supplied_data = data if isinstance(data, dict) else {}
    payload = {"type": str(notif_type or "info")}
    if related_donation_id is not None:
        payload["donation_id"] = str(related_donation_id)
    screen = supplied_data.get("screen")
    if isinstance(screen, str) and screen in {
        "browse",
        "deliveries",
        "donation_claims",
        "donation_detail",
        "donation_history",
        "my_claims",
        "my_donations",
        "my_offers",
    }:
        payload["screen"] = str(screen)
    receipt_ready = supplied_data.get("receipt_ready")
    if isinstance(receipt_ready, (bool, str)) and receipt_ready in (
        True,
        False,
        "true",
        "false",
    ):
        payload["receipt_ready"] = str(receipt_ready).lower()
    if fcm_sender is not None:
        try:
            fcm_sender.send_push_notification_to_user(
                user_id, title, message, data=payload
            )
        except Exception as exc:  # noqa: BLE001
            # FCM unconfigured/unreachable: the record is already durable, so the
            # business transaction is untouched and the app will still show the
            # notification when it next reads the table.
            logger.info(
                "FCM push skipped for user %s (%s): %s", user_id, notif_type, exc
            )
    return row


def notify_many(client, user_ids, **kwargs) -> list[dict]:
    """Notify several resolved recipients about the same event."""
    results = []
    for user_id in dict.fromkeys(u for u in (user_ids or []) if u):
        row = notify(client, user_id, **kwargs)
        if row is not None:
            results.append(row)
    return results


# ---------------------------------------------------------------------------
# Business events
#
# Each function composes its message ONLY from real database facts and
# resolves its recipients server-side. Every function is best-effort and never
# raises.
# ---------------------------------------------------------------------------
def donation_created(client, *, donation: dict, provider_row: dict | None) -> None:
    """A new donation was really created -> notify eligible verified NGOs in the same
    city as the provider (the relevance rule this app already stores:
    `ngos.city` / `providers.city`).

    Ranking/matching output is NEVER used as a recipient list — matching is a
    view, not a business event, and an AI ranking alone is not a claim.
    """
    try:
        city = (provider_row or {}).get("city")
        if not city:
            return
        food_name = donation.get("food_name") or "a donation"
        quantity = donation.get("quantity")
        unit = donation.get("unit") or ""
        provider_name = (provider_row or {}).get("organization_name") or "A food provider"
        rows = (
            client.table("ngos")
            .select("*")
            .eq("city", city)
            .execute()
        )
        targets = getattr(rows, "data", None) or []
        user_ids = list(
            dict.fromkeys(
                str(ngo["user_id"]) for ngo in targets if ngo.get("user_id")
            )
        )
        user_rows = (
            client.table("users")
            .select("id,role,full_name,email,phone")
            .in_("id", user_ids)
            .execute()
            .data
            or []
        ) if user_ids else []
        users_by_id = {str(user["id"]): user for user in user_rows}
        for ngo in targets:
            if not ngo_profile_is_complete(
                users_by_id.get(str(ngo.get("user_id"))), ngo
            ):
                continue
            notify(
                client,
                ngo.get("user_id"),
                title=f"New donation near you: {food_name}",
                message=(
                    f"{provider_name} posted {quantity} {unit} of {food_name}. "
                    "Open Find Food to claim it."
                ),
                notif_type="new_nearby_donation",
                related_donation_id=donation.get("id"),
                data={"screen": "browse"},
            )
    except Exception as exc:  # noqa: BLE001
        logger.warning("donation_created notification failed: %s", exc)


def claim_created(client, *, donation: dict | None, ngo_row: dict | None) -> None:
    """A new claim starts delivery coordination -> its provider is told."""
    try:
        if not donation:
            return
        provider_user = user_id_for_provider(client, donation.get("provider_id"))
        ngo_name = (ngo_row or {}).get("organization_name") or "An NGO"
        food_name = donation.get("food_name") or "your donation"
        notify(
            client,
            provider_user,
            title=f"{ngo_name} claimed {food_name}",
            message=(
                f"{ngo_name} submitted a claim for {food_name}. Open the claim "
                "to confirm who will handle transport."
            ),
            notif_type="claim_submitted",
            related_donation_id=donation.get("id"),
            data={"screen": "donation_claims"},
        )
    except Exception as exc:  # noqa: BLE001
        logger.warning("claim_created notification failed: %s", exc)


def transport_coordination_started(
    client, *, donation: dict | None, claim: dict, ngo_row: dict | None
) -> None:
    """Prompt the claiming NGO once, after a persisted coordination row exists."""
    try:
        donation = donation or {}
        ngo_user = (ngo_row or {}).get("user_id") or user_id_for_ngo(
            client, claim.get("ngo_id")
        )
        food = donation.get("food_name") or "this donation"
        notify(
            client,
            ngo_user,
            title=f"Delivery details needed: {food}",
            message="Confirm whether your organization will pick up this donation.",
            notif_type="transport_coordination",
            related_donation_id=donation.get("id"),
            data={"screen": "my_claims"},
        )
    except Exception as exc:  # noqa: BLE001
        logger.warning("transport_coordination_started notification failed: %s", exc)


def transport_response_received(
    client,
    *,
    donation: dict | None,
    claim: dict,
    coordination: dict,
    acting_role: str,
) -> None:
    """Tell the other participant a response was persisted, without exposing codes."""
    try:
        donation = donation or {}
        food = donation.get("food_name") or "the donation"
        recipient = (
            user_id_for_ngo(client, claim.get("ngo_id"))
            if acting_role == "provider"
            else user_id_for_provider(client, donation.get("provider_id"))
        )
        if not recipient:
            return
        choice = coordination.get(f"{acting_role}_response")
        message = (
            f"The {acting_role} will handle transport for {food}."
            if choice == "yes"
            else f"The {acting_role} cannot handle transport for {food}."
        )
        notify(
            client,
            recipient,
            title=f"Transport response received: {food}",
            message=message,
            notif_type="transport_coordination",
            related_donation_id=donation.get("id"),
            data={"screen": "donation_detail"},
        )
    except Exception as exc:  # noqa: BLE001
        logger.warning("transport_response_received notification failed: %s", exc)


def transport_responsibility_assigned(
    client, *, donation: dict | None, claim: dict, coordination: dict
) -> None:
    """Notify both claim participants about the first affirmative response."""
    try:
        donation = donation or {}
        food = donation.get("food_name") or "the donation"
        role = coordination.get("responsible_role")
        responsible = "the provider" if role == "provider" else "the NGO"
        recipients = [
            user_id_for_provider(client, donation.get("provider_id")),
            user_id_for_ngo(client, claim.get("ngo_id")),
        ]
        notify_many(
            client,
            recipients,
            title=f"Transport arranged: {food}",
            message=f"{responsible} is handling transport. Open the claim to see the saved contact.",
            notif_type="transport_coordination",
            related_donation_id=donation.get("id"),
            data={"screen": "donation_detail"},
        )
    except Exception as exc:  # noqa: BLE001
        logger.warning("transport_responsibility_assigned notification failed: %s", exc)


def transport_responsibility_confirmed(
    client,
    *,
    donation: dict | None,
    claim: dict,
    coordination: dict,
    responding_role: str,
) -> None:
    """Tell the second affirmative responder which party won the race."""
    try:
        donation = donation or {}
        food = donation.get("food_name") or "the donation"
        winner = coordination.get("responsible_role")
        recipient = (
            user_id_for_provider(client, donation.get("provider_id"))
            if responding_role == "provider"
            else user_id_for_ngo(client, claim.get("ngo_id"))
        )
        if not recipient:
            return
        responsible = "the provider" if winner == "provider" else "the NGO"
        notify(
            client,
            recipient,
            title=f"Transport already arranged: {food}",
            message=(
                f"{responsible.capitalize()} confirmed transport first. "
                "Open the claim to see the saved contact."
            ),
            notif_type="transport_coordination",
            related_donation_id=donation.get("id"),
            data={"screen": "donation_detail"},
        )
    except Exception as exc:  # noqa: BLE001
        logger.warning("transport_responsibility_confirmed notification failed: %s", exc)


def transport_volunteer_search_started(
    client, *, donation: dict | None, claim: dict
) -> None:
    """Tell both participants that a persisted volunteer task is now open."""
    try:
        donation = donation or {}
        food = donation.get("food_name") or "the donation"
        recipients = [
            user_id_for_provider(client, donation.get("provider_id")),
            user_id_for_ngo(client, claim.get("ngo_id")),
        ]
        notify_many(
            client,
            recipients,
            title=f"Searching for volunteers: {food}",
            message="Both organizations declined transport. A volunteer task is now available.",
            notif_type="transport_coordination",
            related_donation_id=donation.get("id"),
            data={"screen": "donation_detail"},
        )
    except Exception as exc:  # noqa: BLE001
        logger.warning("transport_volunteer_search_started notification failed: %s", exc)


_PROVIDER_CLAIM_MESSAGES = {
    "rejected": (
        "claim_rejected",
        "Claim not accepted",
        "An NGO's claim for {food} was not accepted. Open SAHAAY to review "
        "the latest status.",
    ),
    "cancelled": (
        "claim_cancelled",
        "Claim withdrawn",
        "An NGO withdrew its claim for {food}. Open SAHAAY to review the "
        "donation's status.",
    ),
    "completed": (
        "claim_completed",
        "Donation completed",
        "The handover for {food} has been marked complete.",
    ),
}


def claim_status_changed(
    client,
    *,
    claim: dict,
    new_status: str,
    donation: dict | None = None,
    other_pending_ngo_ids: list[str] | None = None,
) -> None:
    """A claim really changed status through PATCH /claims.

    * accepted/rejected/cancelled/completed -> the provider is told (their
      donation is what changed hands).
    * accepted additionally -> every NGO whose claim was pending on this
      donation is told ITS OWN claim was rejected (the DB trigger rejects the
      others when one is accepted). Recipients come from the pre-update
      snapshot of real pending claims, never from the request.
    """
    try:
        donation = donation or _donation_by_id(client, claim.get("donation_id"))
        if not donation:
            return
        food_name = donation.get("food_name") or "your donation"
        provider_user = user_id_for_provider(client, donation.get("provider_id"))
        if new_status == "accepted":
            title, message = donation_notification_copy(
                "provider_accepted",
                donation.get("food_name"),
                ngo_display_name(client, claim.get("ngo_id")),
            )
            notify(
                client,
                provider_user,
                title=title,
                message=message,
                notif_type="donation_claimed",
                related_donation_id=donation.get("id"),
                data={"screen": "donation_claims"},
            )
            ngo_user = user_id_for_ngo(client, claim.get("ngo_id"))
            title, message = donation_notification_copy(
                "ngo_accepted", donation.get("food_name")
            )
            notify(
                client,
                ngo_user,
                title=title,
                message=message,
                notif_type="donation_claimed",
                related_donation_id=donation.get("id"),
                data={"screen": "my_claims"},
            )

        mapping = _PROVIDER_CLAIM_MESSAGES.get(new_status)
        if mapping is not None and provider_user:
            notif_type, title_tmpl, message_tmpl = mapping
            notify(
                client,
                provider_user,
                title=title_tmpl.format(food=food_name),
                message=message_tmpl.format(food=food_name),
                notif_type=notif_type,
                related_donation_id=donation.get("id"),
                data={"screen": "donation_claims"},
            )

        if new_status == "accepted" and other_pending_ngo_ids:
            for ngo_id in other_pending_ngo_ids:
                ngo_user = user_id_for_ngo(client, ngo_id)
                notify(
                    client,
                    ngo_user,
                    title="Claim not selected",
                    message=(
                        f"Another NGO's claim for {food_name} was accepted first. "
                        "Open SAHAAY to review other available donations."
                    ),
                    notif_type="claim_rejected",
                    related_donation_id=donation.get("id"),
                    data={"screen": "my_claims"},
                )
    except Exception as exc:  # noqa: BLE001
        logger.warning("claim_status_changed notification failed: %s", exc)


def claim_escalation_rejected(
    client, *, donation: dict | None, claim: dict, reason: str | None = None
) -> None:
    """Auto-escalation really rejected a pending claim -> that claim's NGO.

    Only called when the escalation update actually changed a row, so a
    keep_waiting decision or a scheduler sweep that escalates nothing never
    notifies anyone.
    """
    try:
        if not donation or not claim:
            return
        ngo_user = user_id_for_ngo(client, claim.get("ngo_id"))
        title, message = donation_notification_copy(
            "ngo_response_window_closed", donation.get("food_name")
        )
        notify(
            client,
            ngo_user,
            title=title,
            message=message,
            notif_type="claim_rejected",
            related_donation_id=donation.get("id"),
            data={"screen": "my_claims"},
        )
    except Exception as exc:  # noqa: BLE001
        logger.warning("claim_escalation_rejected notification failed: %s", exc)


def volunteer_transport_assigned(
    client, *, delivery: dict, claim: dict | None, donation: dict | None
) -> None:
    """A REAL volunteer accepted a transport task -> the claiming NGO and the
    provider are told (pickup happens at the provider, drop-off at the NGO)."""
    try:
        donation = donation or _donation_by_id(client, delivery.get("donation_id"))
        if not claim and delivery.get("claim_id"):
            claim = _claim_by_id(client, delivery.get("claim_id"))
        food_name = (donation or {}).get("food_name") or "the donation"
        recipients = []
        if claim:
            recipients.append(user_id_for_ngo(client, claim.get("ngo_id")))
        if donation:
            recipients.append(
                user_id_for_provider(client, donation.get("provider_id"))
            )
        notify_many(
            client,
            recipients,
            title=f"Volunteer assigned: {food_name}",
            message=(
                "A volunteer accepted the transport task and will move "
                f"{food_name} from the provider to the NGO."
            ),
            notif_type="volunteer_assigned",
            related_donation_id=(donation or {}).get("id") or delivery.get("donation_id"),
            data={"screen": "deliveries"},
        )
    except Exception as exc:  # noqa: BLE001
        logger.warning("volunteer_transport_assigned notification failed: %s", exc)


_DELIVERY_MESSAGES = {
    "picked_up": (
        "pickup_updated",
        "Picked up: {food}",
        "{food} has been picked up for delivery.",
    ),
    "in_transit": (
        "pickup_updated",
        "On the way: {food}",
        "{food} is on the way to the receiving organization.",
    ),
    "delivered": (
        "delivery_completed",
        "Delivered: {food}",
        "Delivery of {food} is complete.",
    ),
    "failed": (
        "delivery_failed",
        "Delivery could not be completed: {food}",
        "Delivery of {food} could not be completed.",
    ),
    "cancelled": (
        "delivery_failed",
        "Delivery cancelled: {food}",
        "Delivery of {food} was cancelled.",
    ),
}


def delivery_status_changed(
    client,
    *,
    delivery: dict,
    new_status: str,
    failure_reason: str | None = None,
) -> None:
    """A delivery status really transitioned.

    Recipients are derived from the delivery's own relationships:
    * picked_up / in_transit  -> the claiming NGO (they are waiting for food)
    * delivered               -> NGO + provider (the donation is now completed)
    * failed/cancelled        -> NGO + provider, quoting the real failure reason

    Any other status (e.g. a no-op update) notifies nobody.
    """
    try:
        mapping = _DELIVERY_MESSAGES.get(new_status)
        if mapping is None:
            return
        notif_type, title_tmpl, message_tmpl = mapping
        claim = _claim_by_id(client, delivery.get("claim_id"))
        donation = _donation_by_id(client, delivery.get("donation_id"))
        food_name = (donation or {}).get("food_name") or "the donation"
        recipients = []
        if claim:
            recipients.append(user_id_for_ngo(client, claim.get("ngo_id")))
        if new_status in {"delivered", "failed", "cancelled"} and donation:
            recipients.append(
                user_id_for_provider(client, donation.get("provider_id"))
            )
        message = message_tmpl.format(food=food_name)
        if new_status in {"failed", "cancelled"} and failure_reason:
            detail = _safe_notification_copy(failure_reason, "", max_length=240)
            if detail:
                message = f"{message} Reason: {detail}"
        notify_many(
            client,
            recipients,
            title=title_tmpl.format(food=food_name),
            message=message,
            notif_type=notif_type,
            related_donation_id=(donation or {}).get("id") or delivery.get("donation_id"),
            data={"screen": "deliveries"},
        )
    except Exception as exc:  # noqa: BLE001
        logger.warning("delivery_status_changed notification failed: %s", exc)


def handover_verified(
    client, *, donation: dict | None, claim: dict | None
) -> None:
    """Notify both authorized participants after the persisted handover succeeds."""
    try:
        donation = donation or _donation_by_id(client, (claim or {}).get("donation_id"))
        if not donation:
            return
        recipients = [user_id_for_provider(client, donation.get("provider_id"))]
        ngo_user = user_id_for_ngo(client, (claim or {}).get("ngo_id"))
        if ngo_user and ngo_user not in recipients:
            recipients.append(ngo_user)
        food_name = donation.get("food_name") or "your donation"
        notify_many(
            client,
            recipients,
            title=f"Handover verified: {food_name}",
            message=f"The handover code was verified for {food_name}.",
            notif_type="handover_verified",
            related_donation_id=donation.get("id"),
            data={"screen": "donation_detail"},
        )
    except Exception as exc:  # noqa: BLE001
        logger.warning("handover_verified notification failed: %s", exc)


def handover_completed(client, *, donation: dict | None, claim: dict | None) -> None:
    """Notify both parties when verification succeeded but receipt storage failed."""
    try:
        donation = donation or {}
        claim = claim or {}
        food = donation.get("food_name") or "your donation"
        recipients = [user_id_for_provider(client, donation.get("provider_id"))]
        ngo_user = user_id_for_ngo(client, claim.get("ngo_id"))
        if ngo_user and ngo_user not in recipients:
            recipients.append(ngo_user)
        for user_id in recipients:
            notify(
                client, user_id,
                title=f"Donation completed: {food}",
                message="The handover code was verified. The receipt is still being prepared; check donation history shortly.",
                notif_type="handover_completed",
                related_donation_id=donation.get("id"),
                data={"screen": "donation_history", "receipt_ready": "false"},
            )
    except Exception as exc:  # noqa: BLE001
        logger.warning("handover_completed notification failed: %s", exc)


def ngo_demo_verification_changed(
    client, *, ngo: dict, verified: bool
) -> None:
    """Notify an NGO only after its matching-eligibility status actually changes."""
    try:
        user_id = ngo.get("user_id") or user_id_for_ngo(client, ngo.get("id"))
        if verified:
            title = "SAHAAY account verification complete"
            message = (
                "Your organization is eligible for SAHAAY matching. "
                "This does not represent legal NGO verification."
            )
        else:
            title = "SAHAAY account verification needs attention"
            message = (
                "Your account verification is pending because a required contact "
                "or profile detail is missing. Review your profile in SAHAAY."
            )
        notify(
            client,
            user_id,
            title=title,
            message=message,
            notif_type="ngo_demo_verification",
            data={"screen": "profile"},
            dedupe=False,
        )
    except Exception as exc:  # noqa: BLE001
        logger.warning("ngo_demo_verification notification failed: %s", exc)


def contact_phone_updated(
    client,
    *,
    user_id: str | None,
    previous_phone: str | None,
) -> None:
    """Record an in-app contact update without implying phone ownership."""
    try:
        normalized_old = normalize_phone_for_notification(previous_phone)
        title = (
            "Phone number added"
            if normalized_old is None
            else "Phone number updated"
        )
        notify(
            client,
            user_id,
            title=title,
            message=(
                "Your contact phone number was saved. Its format is valid, "
                "but phone ownership has not been verified."
            ),
            # NULL is explicitly supported by notifications.type's existing
            # schema constraint; this event needs no database migration.
            notif_type=None,
            data={"screen": "profile"},
            dedupe=False,
        )
    except Exception as exc:  # noqa: BLE001
        logger.warning("contact phone update notification failed: %s", exc)


def normalize_phone_for_notification(value: str | None) -> str | None:
    from app.services.phone_number import normalize_indian_mobile_number

    return normalize_indian_mobile_number(value)


def acknowledgment_ready(
    client, *, donation: dict | None, provider_user_id: str | None = None,
    claim: dict | None = None,
) -> None:
    """A persisted completion receipt is ready for both real participants."""
    try:
        donation = donation or {}
        recipients = [provider_user_id or user_id_for_provider(
            client, donation.get("provider_id")
        )]
        claim = claim or {}
        ngo_user_id = user_id_for_ngo(client, claim.get("ngo_id"))
        if ngo_user_id and ngo_user_id not in recipients:
            recipients.append(ngo_user_id)
        food_name = donation.get("food_name") or "your donation"
        for user_id in recipients:
            notify(
                client,
                user_id,
                title=f"Donation completed: {food_name}",
                message="The handover was verified. Your donation receipt is ready to download from donation history.",
                notif_type="acknowledgment_ready",
                related_donation_id=donation.get("id"),
                data={"screen": "donation_history", "receipt_ready": "true"},
            )
    except Exception as exc:  # noqa: BLE001
        logger.warning("acknowledgment_ready notification failed: %s", exc)


# ---------------------------------------------------------------------------
# Internal row lookups shared by the event functions (all best-effort)
# ---------------------------------------------------------------------------
def _donation_by_id(client, donation_id) -> dict | None:
    if not donation_id:
        return None
    try:
        row = (
            client.table("donations")
            .select("*")
            .eq("id", str(donation_id))
            .maybe_single()
            .execute()
        )
        return getattr(row, "data", None) or None
    except Exception:  # noqa: BLE001
        return None


def _claim_by_id(client, claim_id) -> dict | None:
    if not claim_id:
        return None
    try:
        row = (
            client.table("claims")
            .select("*")
            .eq("id", str(claim_id))
            .maybe_single()
            .execute()
        )
        return getattr(row, "data", None) or None
    except Exception:  # noqa: BLE001
        return None
