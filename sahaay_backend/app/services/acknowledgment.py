"""Donation-completion acknowledgment PDFs (real data, persisted reference).

Flow (production):

    delivery status -> 'delivered'  (volunteer PATCH /deliveries/{id}/status)
        -> record_delivery_impact trigger writes impact_records AND sets
           donations.status = 'completed'   (the ONLY real completion signal)
        -> auto_generate_acknowledgment()  (this module, best-effort)
             -> POST the AI service's existing ReportLab endpoint
                /api/v1/donation/generate-acknowledgment
             -> download the PDF bytes back through the AIClient
             -> upload them to the existing Supabase storage bucket
             -> persist donations.acknowledgment_pdf_url + generated_at
        -> provider notified that the PDF is ready

    Flutter never talks to the AI service: it downloads the saved PDF from the
    main backend (GET /api/v1/donations/{id}/acknowledgment), which serves the
    persisted copy first and falls back to the AI service's own local copy.

Honesty rules (enforced here, not in the client):
* Only a genuinely completed donation (status 'completed'/'delivered') can
  produce a completion PDF — a mere claim is never enough.
* The quantity must be recorded in a real weight unit (kg/g). Serving counts
  are never converted into kilograms, so those donations are refused with an
  explicit reason instead of a fabricated weight.
* Every optional fact (handover verification/photo, delivery completion time,
  impact numbers, volunteer involvement) is read from the real rows and passed
  through as None when missing — the PDF renders "Not available" for None.
* A volunteer is only named when deliveries.volunteer_id really points at a
  volunteers row, and the name comes from that volunteer's users.full_name.
* Storage/persistence failures are reported honestly (`persisted: False`)
  rather than pretended away, and auto generation NEVER raises: a broken PDF
  pipeline must not fail the delivery update that completed the donation.
"""

from __future__ import annotations

import logging

from app.config import get_settings
from app.schemas.ai import DonationAcknowledgmentRequest
from app.services.ai_client import get_ai_client
from app.routers.donations import _ensure_storage_bucket

logger = logging.getLogger("sahaay.acknowledgment")

#: The only statuses that represent an actually completed donation. This mirrors
#: app/routers/ai_features.py::_COMPLETED_DONATION_STATUSES.
COMPLETED_DONATION_STATUSES = frozenset({"completed", "delivered"})

#: Only these units are genuinely convertible to kilograms (SI-accurate).
#: There is intentionally NO servings/plates entry — SAHAAY has no documented
#: conversion from a serving count to a physical weight.
_WEIGHT_UNIT_TO_KG = {
    "kg": 1.0,
    "kgs": 1.0,
    "kilogram": 1.0,
    "kilograms": 1.0,
    "g": 0.001,
    "gram": 0.001,
    "grams": 0.001,
    "gm": 0.001,
}

_STORAGE_PREFIX = "acknowledgments"


class AcknowledgmentError(Exception):
    """An honest refusal to generate a PDF, with a user-facing reason."""


def quantity_kg_of(donation: dict) -> float | None:
    """Resolves the donation's quantity into genuine kilograms.

    Only weight units convert. Missing/empty/serving-count values return None
    so callers surface an explicit refusal instead of inventing a weight.
    """
    quantity = donation.get("quantity")
    if quantity is None:
        return None
    try:
        value = float(quantity)
    except (TypeError, ValueError):
        return None
    if value <= 0:
        return None
    unit = str(donation.get("unit") or "").strip().lower()
    factor = _WEIGHT_UNIT_TO_KG.get(unit)
    if factor is None:
        return None
    return value * factor


def _row(client, table: str, columns: str, **filters) -> dict | None:
    """Small guarded single-row reader; None when missing or unreadable."""
    try:
        query = client.table(table).select(columns)
        for key, value in filters.items():
            query = query.eq(key, value)
        response = query.maybe_single().execute()
        return getattr(response, "data", None) or None
    except Exception:  # noqa: BLE001
        return None


def _rows(client, table: str, columns: str, **filters) -> list[dict]:
    try:
        query = client.table(table).select(columns)
        for key, value in filters.items():
            query = query.eq(key, value)
        return getattr(query.execute(), "data", None) or []
    except Exception:  # noqa: BLE001
        return []


def _parse_ts(value):
    if value is None or value == "":
        return None
    from datetime import datetime, timezone

    if isinstance(value, datetime):
        return value if value.tzinfo else value.replace(tzinfo=timezone.utc)
    try:
        parsed = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except (TypeError, ValueError):
        return None
    return parsed if parsed.tzinfo else parsed.replace(tzinfo=timezone.utc)


def _completed_claim(client, donation_id) -> dict | None:
    """The real claim behind this donation: a completed claim if one exists,
    otherwise an accepted one. None when the donation has no such claim."""
    claims = _rows(client, "claims", "*", donation_id=str(donation_id))
    return next(
        (c for c in claims if c.get("status") == "completed"),
        next((c for c in claims if c.get("status") == "accepted"), None),
    )


def _volunteer_facts(client, donation_id) -> tuple[bool | None, str | None]:
    """(volunteer_transport_used, volunteer_name) derived from real rows.

    used=True  -> deliveries.volunteer_id points at a real volunteers row.
    used=False -> a delivery exists but no volunteer ever took it (or none
                  needed one) — truthful: no volunteer transported this food.
    name       -> that volunteer's users.full_name, or None when unresolved
                  (the PDF then prints "Not available" — never a fake name).
    """
    deliveries = _rows(
        client, "deliveries", "id,volunteer_id", donation_id=str(donation_id)
    )
    if not deliveries:
        return False, None
    volunteer_id = deliveries[0].get("volunteer_id")
    if not volunteer_id:
        return False, None
    volunteer = _row(client, "volunteers", "user_id", id=str(volunteer_id))
    if not volunteer or not volunteer.get("user_id"):
        return True, None
    user = _row(client, "users", "full_name", id=str(volunteer["user_id"]))
    name = (user or {}).get("full_name")
    return True, (name or None)


def build_acknowledgment_request(
    client, donation: dict, restaurant_name: str | None = None
) -> DonationAcknowledgmentRequest:
    """Builds the AI contract from REAL database rows only.

    `restaurant_name` may carry the provider organization name from the
    authenticated profile join (server-derived from the same providers row via
    the Firebase token); it is only used when the direct providers-row lookup
    finds nothing, so neither source can invent a name.

    Raises AcknowledgmentError with an honest reason when the PDF cannot be
    truthfully produced (missing provider/claim/NGO, non-weight quantity).
    """
    if not donation:
        raise AcknowledgmentError("Donation not found.")

    provider = _row(
        client, "providers", "organization_name", id=str(donation.get("provider_id"))
    )
    restaurant_name = (provider or {}).get("organization_name") or restaurant_name
    if not restaurant_name:
        raise AcknowledgmentError(
            "Provider record is missing an organization name, so an acknowledgment "
            "cannot be generated."
        )

    claim = _completed_claim(client, donation.get("id"))
    if claim is None:
        raise AcknowledgmentError(
            "A completed claim is required to generate an acknowledgment."
        )
    ngo = _row(client, "ngos", "organization_name", id=str(claim.get("ngo_id")))
    if not ngo or not ngo.get("organization_name"):
        raise AcknowledgmentError(
            "NGO record for the claim is missing, so an acknowledgment cannot be "
            "generated."
        )

    quantity_kg = quantity_kg_of(donation)
    if quantity_kg is None:
        unit_label = str(donation.get("unit") or "").strip().lower()
        raise AcknowledgmentError(
            "This donation is not recorded in kilograms "
            f"(unit={unit_label or 'missing'}), so an acknowledgment PDF "
            "cannot honestly state a weight in kg. Only kilogram/gram "
            "values are convertible to kg; servings are not."
        )

    prepared_at = _parse_ts(donation.get("prepared_at"))
    if prepared_at is None:
        raise AcknowledgmentError(
            "The donation has no usable preparation timestamp, so the "
            "acknowledgment cannot state when the donation was made."
        )

    # Optional, real facts — each None is rendered as "Not available".
    impact = _row(client, "impact_records", "*", donation_id=str(donation.get("id")))
    delivery = _row(client, "deliveries", "*", donation_id=str(donation.get("id")))
    delivered_at = _parse_ts((delivery or {}).get("delivery_time"))
    volunteer_used, volunteer_name = _volunteer_facts(client, donation.get("id"))

    received_at = _parse_ts(claim.get("handover_verified_at"))
    handover_verified_at = _parse_ts(claim.get("handover_verified_at"))
    # The header's completion moment is the real receipt (or, failing that, the
    # delivery/handover) — never "now".
    completed_at = received_at or delivered_at or handover_verified_at

    return DonationAcknowledgmentRequest(
        donation_id=str(donation["id"]),
        restaurant_name=restaurant_name,
        ngo_name=ngo["organization_name"],
        food_details=donation.get("food_name") or "Food donation",
        quantity_kg=quantity_kg,
        donation_datetime=prepared_at,
        completion_status="Completed",
        unit=str(donation.get("unit") or "") or None,
        quantity_label=(
            f"{donation.get('quantity')} {donation.get('unit')}"
            if donation.get("quantity") is not None and donation.get("unit")
            else None
        ),
        servings=donation.get("servings"),
        order_id=donation.get("order_id"),
        posted_at=_parse_ts(donation.get("created_at")),
        claimed_at=_parse_ts(claim.get("created_at")),
        picked_up_at=_parse_ts((delivery or {}).get("pickup_time")),
        received_at=received_at,
        impact_points=(impact or {}).get("impact_points"),
        handover_verified_at=handover_verified_at,
        handover_photo_url=claim.get("handover_photo_url") or None,
        delivered_at=delivered_at,
        meals_rescued=(impact or {}).get("meals_rescued"),
        food_weight_kg=(impact or {}).get("food_weight_kg"),
        estimated_co2_saved=(impact or {}).get("estimated_co2_saved"),
        volunteer_transport_used=volunteer_used,
        volunteer_name=volunteer_name,
        completed_at=completed_at,
        handover_status=(
            "Successfully delivered & received" if received_at else None
        ),
        volunteer_role="Provider -> NGO delivery" if volunteer_used else None,
        ngo_receipt_confirmed=True if received_at else None,
    )


def _storage_path(donation_id) -> str:
    return f"{_STORAGE_PREFIX}/acknowledgment_{donation_id}.pdf"


def _persist(client, donation_id, pdf_bytes: bytes) -> tuple[bool, str | None]:
    """Uploads the PDF to the existing Supabase storage bucket and returns
    (persisted, public_url). Storage failures are reported, not hidden."""
    try:
        bucket = get_settings().supabase_storage_bucket
        _ensure_storage_bucket(client, bucket)
        path = _storage_path(donation_id)
        client.storage.from_(bucket).upload(
            path,
            pdf_bytes,
            # x-upsert: regenerating a PDF (manual button after auto-generation)
            # must replace the stored object instead of failing with a 409.
            file_options={"content-type": "application/pdf", "x-upsert": "true"},
        )
        url = client.storage.from_(bucket).get_public_url(path)
        return True, url
    except Exception as exc:  # noqa: BLE001
        logger.warning(
            "Acknowledgment PDF storage upload failed for %s: %s", donation_id, exc
        )
        return False, None


def generate_and_persist(
    client, donation: dict, ai_client=None, restaurant_name: str | None = None
) -> dict:
    """Generates the PDF through the AI service and persists its reference.

    Raises AcknowledgmentError for honest refusals and the usual
    AIService* errors for transport failures — callers decide how to surface
    them. Persistence is best-effort: an un-storable PDF is still returned to
    the caller with `persisted: False` (the storage limitation is reported,
    not papered over).
    """
    donation_id = str(donation["id"])
    request = build_acknowledgment_request(client, donation, restaurant_name)
    ai_client = ai_client or get_ai_client()
    ai_client.generate_acknowledgment(request)
    pdf_bytes = ai_client.download_acknowledgment(donation_id)

    persisted, url = _persist(client, donation_id, pdf_bytes)
    generated_at = None
    if persisted:
        from datetime import datetime, timezone

        generated_at = datetime.now(timezone.utc).isoformat()
        try:
            client.table("donations").update(
                {
                    "acknowledgment_pdf_url": url,
                    "acknowledgment_generated_at": generated_at,
                }
            ).eq("id", donation_id).execute()
        except Exception as exc:  # noqa: BLE001
            logger.warning(
                "Could not persist acknowledgment reference for %s: %s",
                donation_id,
                exc,
            )
            persisted, url = False, None
            generated_at = None

    return {
        "donation": donation,
        "pdf_bytes": pdf_bytes,
        "persisted": persisted,
        "url": url,
        "generated_at": generated_at,
    }


def load_persisted_pdf(client, donation: dict) -> bytes | None:
    """The stored PDF bytes for a donation, or None when nothing is persisted.

    This is what makes the acknowledgment survive an app restart and an AI
    service restart: the bytes live in the Supabase storage bucket, not only
    on the AI service's local disk.
    """
    if not donation or not donation.get("acknowledgment_pdf_url"):
        return None
    try:
        bucket = get_settings().supabase_storage_bucket
        return client.storage.from_(bucket).download(_storage_path(donation["id"]))
    except Exception as exc:  # noqa: BLE001
        logger.warning(
            "Stored acknowledgment unreadable for %s: %s", donation.get("id"), exc
        )
        return None


def auto_generate_acknowledgment(client, donation_id) -> dict | None:
    """Completion hook: generates + persists the PDF for a completed donation.

    Called after a delivery reaches 'delivered' (when the database trigger has
    flipped the donation to 'completed'). Best-effort by contract — returns an
    outcome dict ({"donation", "persisted", ...}) on success and None for
    EVERY failure (not completed, no weight unit, AI down, storage down), so
    it can never break the business transaction that completed the donation.
    """
    if not donation_id:
        return None
    try:
        donation = _row(client, "donations", "*", id=str(donation_id))
        if not donation:
            return None
        if donation.get("status") not in COMPLETED_DONATION_STATUSES:
            # Not actually completed yet (or ever) — no completion PDF.
            return None
        if donation.get("acknowledgment_pdf_url"):
            # Already generated and persisted earlier: idempotent, no re-run.
            return {
                "donation": donation,
                "persisted": True,
                "url": donation.get("acknowledgment_pdf_url"),
                "already_generated": True,
                "pdf_bytes": None,
            }
        return generate_and_persist(client, donation)
    except Exception as exc:  # noqa: BLE001
        logger.warning(
            "Auto acknowledgment skipped for donation %s: %s", donation_id, exc
        )
        return None
