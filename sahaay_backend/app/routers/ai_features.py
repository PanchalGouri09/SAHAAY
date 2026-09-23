"""
AI feature integrations exposed through the Main SAHAAY FastAPI server.

Every request here is Firebase-authenticated, derives identity server-side,
and talks to the standalone AI service only through the typed AIClient. The
AI service is never exposed to Flutter directly.

Features (all auxiliary — they must fail without corrupting or blocking the
critical donation flow):

* NGO Matching:      POST   /api/v1/donations/{donation_id}/match
* Auto-Escalation:   POST   /api/v1/donations/{donation_id}/escalation-check
* Provider Reliability: GET /api/v1/providers/me/reliability
* Acknowledgment:    POST + GET /api/v1/donations/{donation_id}/acknowledgment

Honesty rules applied here (no invented data):
* real NGO rows are mapped onto the AI contract; an NGO without real
  operating hours is excluded from candidates (its hours are never invented).
* reliability counters come only from real donations/claims/feedback.
* the acknowledged claim / NGO must really exist for the completed donation.
* only donations that are still 'available' and not past expiry are matched.
* the AI's ranked NGO IDs are validated against the eligible candidate set,
  deduped, and enriched with the real NGO rows — unknown IDs are never shown.
"""

from datetime import datetime, timezone
from re import compile as _re_compile
from statistics import mean

from fastapi import APIRouter, Depends, HTTPException, Response
from pydantic import ValidationError

from app.dependencies import require_role
from app.routers.donations import _provider_id_of
from app.schemas.ai import (
    DonationAcknowledgmentRequest,
    DonationInput,
    MatchRequest,
    NGOInput,
    ReliabilityInput,
)
from app.services.ai_client import (
    AIClient,
    AIServiceHTTPError,
    AIServiceUnavailableError,
    get_ai_client,
)
from app.services.escalation import (
    assess_donation_escalation,
    eligible_for_escalation,
    is_expired,
)
from app.supabase_client import get_supabase_client

router = APIRouter(tags=["ai-features"])

_COMPLETED_DONATION_STATUSES = {"completed", "delivered"}

# 24-hour "HH:MM" — matches ngos.available_from/available_to check constraints
# and the AI service's NGOInput contract.
_HHMM_PATTERN = _re_compile(r"^([01][0-9]|2[0-3]):[0-5][0-9]$")

# DONATION veg_type -> AI dietary vocabulary (DietaryType). "any" is a truthful
# default: the provider did not restrict dietary compatibility.
_DIETARY_MAP = {
    "vegetarian": "veg",
    "vegan": "vegan",
    "non_vegetarian": "non_veg",
    "mixed": "any",
    "any": "any",
}


def _veg_to_dietary(value) -> str:
    key = (value or "any").strip().lower()
    return _DIETARY_MAP.get(key, "any")


# Real weight units and their factor to kilograms. Only SI-accurate unit
# conversions live here (1 kg = 1000 g); there is intentionally NO
# servings/plates/portions entry, because SAHAAY has no documented conversion
# from servings to a physical weight. Serving counts must never be sent to the
# AI as kilograms.
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


def _quantity_kg(donation: dict) -> float | None:
    """Resolves the donation's quantity into genuine kilograms.

    Only when the donation's unit is a real weight unit is the numeric
    quantity convertible (kg -> as-is, grams -> /1000). Missing, empty,
    serving-count, and unsupported units return None so callers surface an
    explicit 'insufficient_data' rather than inventing a servings-to-kg value.
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


def _dietary_accepted(raw_values) -> list[str] | None:
    """Maps the ngos.preferred_food_types text[] column onto the AI dietary
    vocabulary. Returns None when none of the stored values can be mapped
    (never invents a dietary preference)."""
    if not raw_values:
        return None
    mapped = []
    for value in raw_values:
        key = str(value).strip().lower()
        mapped_value = _DIETARY_MAP.get(key)
        if mapped_value is None and key in {"veg", "non_veg"}:
            mapped_value = key
        if mapped_value:
            mapped.append(mapped_value)
    return mapped or None


def _availability_hours(ngo: dict) -> tuple[str, str] | None:
    """Reads the NGO's real operating hours from the ngos table.

    Returns None when hours are missing, partial, or malformed — an NGO
    without usable hours is excluded from candidates rather than being
    assigned invented hours."""
    from_ = (str(ngo.get("available_from") or "")).strip()
    to_ = (str(ngo.get("available_to") or "")).strip()
    if not from_ or not to_:
        return None
    if not _HHMM_PATTERN.match(from_) or not _HHMM_PATTERN.match(to_):
        return None
    return from_, to_


def _load_owned_donation(client, donation_id: str, profile: dict) -> dict:
    """Loads a donation and enforces that it belongs to the authenticated
    provider. 404/403 are distinct so callers can never probe other donations."""
    if not donation_id:
        raise HTTPException(status_code=422, detail="donation_id is required.")
    response = (
        client.table("donations")
        .select("*")
        .eq("id", donation_id)
        .maybe_single()
        .execute()
    )
    if response is None:
        raise HTTPException(status_code=404, detail="Donation not found.")
    donation = response.data
    provider_id = _provider_id_of(profile)
    if donation.get("provider_id") != provider_id:
        raise HTTPException(status_code=403, detail="Donation does not belong to this provider.")
    return donation


def _route_ai_failure(exc: Exception, fallback: str = "The AI service request failed."):
    if isinstance(exc, AIServiceUnavailableError):
        raise HTTPException(status_code=503, detail=str(exc)) from exc
    if isinstance(exc, AIServiceHTTPError):
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    if isinstance(exc, ValidationError):
        raise HTTPException(
            status_code=502, detail="The AI service returned an invalid response."
        ) from exc
    raise HTTPException(status_code=502, detail=fallback) from exc


# ---------------------------------------------------------------------------
# Real provider history -> ReliabilityInput
# ---------------------------------------------------------------------------
def _build_reliability_input(client, provider_id: str) -> ReliabilityInput:
    donations = (
        client.table("donations")
        .select("id,status")
        .eq("provider_id", provider_id)
        .execute()
        .data
        or []
    )
    donation_ids = [row["id"] for row in donations]

    accepted_claims = 0
    if donation_ids:
        claims = (
            client.table("claims")
            .select("status")
            .in_("donation_id", donation_ids)
            .execute()
            .data
            or []
        )
        accepted_claims = sum(
            1 for c in claims if c.get("status") in {"accepted", "completed"}
        )
        feedback = (
            client.table("feedback")
            .select("rating")
            .in_("donation_id", donation_ids)
            .execute()
            .data
            or []
        )
        ratings = [f.get("rating") for f in feedback if f.get("rating") is not None]
    else:
        ratings = []

    completed = sum(1 for d in donations if d.get("status") in _COMPLETED_DONATION_STATUSES)
    cancelled = sum(1 for d in donations if d.get("status") == "cancelled")

    return ReliabilityInput(
        restaurant_id=provider_id,
        total_donations_offered=len(donations),
        total_donations_completed=completed,
        total_donations_accepted=accepted_claims,
        total_cancellations=cancelled,
        average_ngo_rating=round(mean(ratings), 2) if ratings else 0.0,
    )


def _calculate_reliability(ai_client: AIClient, client, provider_id: str):
    try:
        return ai_client.calculate_reliability(_build_reliability_input(client, provider_id))
    except Exception as exc:  # noqa: BLE001
        _route_ai_failure(exc, fallback="Reliability calculation failed.")


# ---------------------------------------------------------------------------
# 1. PROVIDER RELIABILITY SCORE
# ---------------------------------------------------------------------------
@router.get("/api/v1/providers/me/reliability")
def provider_reliability(
    profile: dict = Depends(require_role("provider")),
    ai_client: AIClient = Depends(get_ai_client),
) -> dict:
    provider_id = _provider_id_of(profile)
    result = _calculate_reliability(ai_client, get_supabase_client(), provider_id)
    return {
        "restaurant_id": result.restaurant_id,
        "reliability_score": result.reliability_score,
        "grade": result.grade,
        "breakdown": result.breakdown,
        "input": _build_reliability_input(get_supabase_client(), provider_id).model_dump(mode="json"),
    }


# ---------------------------------------------------------------------------
# NGO matching helpers
# ---------------------------------------------------------------------------
def _ngo_candidates(client) -> list[tuple[dict, NGOInput]]:
    """Builds real NGO candidates from the ngos table.

    NGOs lacking any field required by the AI contract (operating hours,
    location, capacity, dietary preference) are excluded; none are invented.
    Hours come from the real available_from/available_to columns. Returns
    (real_row, NGOInput) pairs so callers can later enrich AI results with
    the factual NGO data."""
    rows = (
        client.table("ngos")
        .select("*")
        .eq("verified", True)
        .execute()
        .data
        or []
    )
    candidates: list[tuple[dict, NGOInput]] = []
    for ngo in rows:
        hours = _availability_hours(ngo)
        if hours is None:
            continue
        if not ngo.get("latitude") or not ngo.get("longitude"):
            continue
        capacity = ngo.get("food_capacity")
        if not capacity or capacity <= 0:
            continue
        dietary = _dietary_accepted(ngo.get("preferred_food_types"))
        if not dietary:
            continue
        candidates.append(
            (
                ngo,
                NGOInput(
                    ngo_id=str(ngo["id"]),
                    name=ngo.get("organization_name") or "Unknown NGO",
                    latitude=float(ngo["latitude"]),
                    longitude=float(ngo["longitude"]),
                    dietary_accepted=dietary,
                    max_capacity_kg=float(capacity),
                    min_capacity_kg=0.0,
                    available_from=hours[0],
                    available_to=hours[1],
                ),
            )
        )
    return candidates


def _pickup_time_of(donation: dict) -> str | None:
    """The donation's real pickup deadline as HH:MM, or None when missing or
    malformed. Callers treat None as insufficient data — a time is never
    invented."""
    deadline = donation.get("pickup_deadline")
    if not deadline:
        return None
    try:
        parsed = datetime.fromisoformat(str(deadline).replace("Z", "+00:00"))
    except (TypeError, ValueError):
        return None
    return parsed.strftime("%H:%M")


def _enrich_ranked_ngo(item, candidate_by_id: dict[str, dict]) -> dict:
    """Merges an AI-ranked NGO with its real ngos row.

    AI-estimated fields (distance, per-criterion scores, final_score, rank)
    stay at the top level exactly as the AI returned them; real factual NGO
    fields are added under 'ngo' so the two can never be confused."""
    row = candidate_by_id.get(item.ngo_id)
    data = item.model_dump(mode="json") if hasattr(item, "model_dump") else dict(item)
    data["ngo"] = {
        "id": item.ngo_id,
        "organization_name": (row or {}).get("organization_name"),
        "city": (row or {}).get("city"),
        "address": (row or {}).get("address"),
        "phone": (row or {}).get("phone"),
        "verified": bool((row or {}).get("verified")),
        "food_capacity": (row or {}).get("food_capacity"),
        "preferred_food_types": (row or {}).get("preferred_food_types") or [],
        "available_from": (row or {}).get("available_from"),
        "available_to": (row or {}).get("available_to"),
    }
    return data


def _provider_location(provider_row: dict, donation: dict) -> tuple[float | None, float | None]:
    lat = provider_row.get("latitude") or donation.get("latitude")
    lon = provider_row.get("longitude") or donation.get("longitude")
    if lat is None or lon is None:
        return None, None
    return float(lat), float(lon)


# ---------------------------------------------------------------------------
# 2. NGO MATCHING
# ---------------------------------------------------------------------------
@router.post("/api/v1/donations/{donation_id}/match")
def match_ngos(
    donation_id: str,
    profile: dict = Depends(require_role("provider")),
    ai_client: AIClient = Depends(get_ai_client),
) -> dict:
    client = get_supabase_client()
    donation = _load_owned_donation(client, donation_id, profile)

    # A donation is only matched while it is still an open offer.
    if not eligible_for_escalation(donation):
        reason = (
            f"Donation status is '{donation.get('status')}' — matching runs "
            "only while the donation is 'available'."
            if donation.get("status") != "available"
            else "This donation has passed its expiry time, so it can no longer be matched."
        )
        return {"status": "insufficient_data", "reason": reason}

    provider_row = profile.get("providers")
    provider_row = provider_row[0] if isinstance(provider_row, list) else provider_row
    lat, lon = _provider_location(provider_row or {}, donation)
    if lat is None or lon is None:
        return {
            "status": "insufficient_data",
            "reason": "Provider pickup location is not set, so distance-based matching cannot run.",
        }

    pickup_time = _pickup_time_of(donation)
    if pickup_time is None:
        return {
            "status": "insufficient_data",
            "reason": "Donation has no usable pickup deadline, so pickup-time feasibility cannot be scored.",
        }

    quantity_value = donation.get("quantity")
    is_bad_numeric = (
        quantity_value is None
        or (isinstance(quantity_value, str) and not quantity_value.strip())
    )
    try:
        numeric_quantity = float(quantity_value) if quantity_value is not None else 0.0
    except (TypeError, ValueError):
        is_bad_numeric = True
        numeric_quantity = 0.0
    if is_bad_numeric or numeric_quantity <= 0:
        return {
            "status": "insufficient_data",
            "reason": "Donation has no usable positive quantity for matching.",
        }

    quantity_kg = _quantity_kg(donation)
    if quantity_kg is None:
        unit_label = str(donation.get("unit") or "").strip().lower()
        return {
            "status": "insufficient_data",
            "reason": (
                f"Donation quantity is recorded in units that are not a real "
                f"weight (unit={unit_label or 'missing'}), so quantity-based "
                "matching cannot run. Only kilogram/gram values are convertible "
                "to kg; servings are not."
            ),
        }

    candidates = _ngo_candidates(client)
    if not candidates:
        return {
            "status": "insufficient_data",
            "reason": "No NGO candidates are ready for matching. "
            "Every registered NGO is missing usable operating hours "
            "(available_from/available_to), so no time-based candidate could be included.",
        }

    restaurant_reliability = _calculate_reliability(ai_client, client, _provider_id_of(profile))

    request = MatchRequest(
        donation=DonationInput(
            donation_id=donation["id"],
            restaurant_id=_provider_id_of(profile),
            restaurant_latitude=lat,
            restaurant_longitude=lon,
            quantity_kg=quantity_kg,
            dietary_type=_veg_to_dietary(donation.get("veg_type")),
            pickup_time=pickup_time,
            restaurant_reliability_score=restaurant_reliability.reliability_score,
        ),
        candidate_ngos=[ngo_input for _, ngo_input in candidates],
    )
    try:
        result = ai_client.rank_ngos(request)
    except Exception as exc:  # noqa: BLE001
        _route_ai_failure(exc, fallback="NGO matching failed.")

    # Only trust rankings for NGOs we actually sent to the AI. Drop unknown
    # IDs, dedupe, and enrich each ranked NGO with its real ngos row.
    candidate_by_id = {str(row["id"]): row for row, _ in candidates}
    seen: set[str] = set()
    ranked_ngos = []
    for item in result.ranked_ngos:
        if item.ngo_id in seen:
            continue
        seen.add(item.ngo_id)
        if item.ngo_id not in candidate_by_id:
            continue
        ranked_ngos.append(_enrich_ranked_ngo(item, candidate_by_id))

    return {
        "status": "ok",
        "donation_id": result.donation_id,
        "ranked_ngos": ranked_ngos,
        "weights_used": result.weights_used,
        "insufficient_reason": None,
    }


# ---------------------------------------------------------------------------
# 3. AUTO-ESCALATION (provider dashboard + background scheduler)
# ---------------------------------------------------------------------------
@router.post("/api/v1/donations/{donation_id}/escalation-check")
def check_donation_escalation(
    donation_id: str,
    profile: dict = Depends(require_role("provider")),
    ai_client: AIClient = Depends(get_ai_client),
) -> dict:
    """Checks whether the NGO currently offered this donation should be
    escalated to the next-ranked NGO. Available on demand from the provider
    dashboard; the background scheduler drives the SAME shared logic
    automatically. Uses real claims rows as the offer sequence."""
    client = get_supabase_client()
    donation = _load_owned_donation(client, donation_id, profile)

    try:
        return assess_donation_escalation(client, ai_client, donation)
    except Exception as exc:  # noqa: BLE001
        _route_ai_failure(exc, fallback="Escalation check failed.")


# ---------------------------------------------------------------------------
# 4. DONATION ACKNOWLEDGMENT PDF
# ---------------------------------------------------------------------------
def _acknowledgment_metadata(client, donation: dict, profile: dict) -> dict:
    provider_row = profile.get("providers")
    provider_row = provider_row[0] if isinstance(provider_row, list) else provider_row
    restaurant_name = (provider_row or {}).get("organization_name")
    if not restaurant_name:
        raise HTTPException(
            status_code=400,
            detail="Provider record is missing an organization name, so an acknowledgment cannot be generated.",
        )

    claims = (
        client.table("claims")
        .select("*")
        .eq("donation_id", donation["id"])
        .execute()
        .data
        or []
    )
    completed_claim = next(
        (c for c in claims if c.get("status") == "completed"),
        next((c for c in claims if c.get("status") == "accepted"), None),
    )
    if completed_claim is None:
        raise HTTPException(
            status_code=400,
            detail="A completed claim is required to generate an acknowledgment.",
        )
    ngo_row = (
        client.table("ngos")
        .select("organization_name")
        .eq("id", completed_claim["ngo_id"])
        .maybe_single()
        .execute()
    )
    if ngo_row is None or not ngo_row.data.get("organization_name"):
        raise HTTPException(
            status_code=400,
            detail="NGO record for the claim is missing, so an acknowledgment cannot be generated.",
        )
    return {
        "restaurant_name": restaurant_name,
        "ngo_name": ngo_row.data["organization_name"],
    }


def _ack_pdf_response(pdf_bytes: bytes, donation_id: str) -> Response:
    return Response(
        content=pdf_bytes,
        media_type="application/pdf",
        headers={
            "Content-Disposition": f'attachment; filename="acknowledgment_{donation_id}.pdf"'
        },
    )


@router.post("/api/v1/donations/{donation_id}/acknowledgment/generate")
def generate_acknowledgment(
    donation_id: str,
    profile: dict = Depends(require_role("provider")),
    ai_client: AIClient = Depends(get_ai_client),
) -> Response:
    client = get_supabase_client()
    donation = _load_owned_donation(client, donation_id, profile)
    if donation.get("status") not in _COMPLETED_DONATION_STATUSES:
        raise HTTPException(
            status_code=400,
            detail="Acknowledgments can only be generated after the donation is completed.",
        )
    meta = _acknowledgment_metadata(client, donation, profile)

    quantity_kg = _quantity_kg(donation)
    if quantity_kg is None:
        unit_label = str(donation.get("unit") or "").strip().lower()
        raise HTTPException(
            status_code=400,
            detail=(
                "This donation is not recorded in kilograms "
                f"(unit={unit_label or 'missing'}), so an acknowledgment PDF "
                "cannot honestly state a weight in kg. Only kilogram/gram "
                "values are convertible to kg; servings are not."
            ),
        )

    request = DonationAcknowledgmentRequest(
        donation_id=donation["id"],
        restaurant_name=meta["restaurant_name"],
        ngo_name=meta["ngo_name"],
        food_details=donation.get("food_name") or "Food donation",
        quantity_kg=quantity_kg,
        donation_datetime=datetime.fromisoformat(
            donation["prepared_at"].replace("Z", "+00:00")
        ),
        completion_status="Completed",
    )
    try:
        # Generate first (the AI service stores the PDF by donation_id).
        ai_client.generate_acknowledgment(request)
        pdf_bytes = ai_client.download_acknowledgment(donation_id)
    except Exception as exc:  # noqa: BLE001
        _route_ai_failure(exc, fallback="Acknowledgment generation failed.")
    return _ack_pdf_response(pdf_bytes, donation_id)


@router.get("/api/v1/donations/{donation_id}/acknowledgment")
def download_acknowledgment(
    donation_id: str,
    profile: dict = Depends(require_role("provider")),
    ai_client: AIClient = Depends(get_ai_client),
) -> Response:
    client = get_supabase_client()
    _load_owned_donation(client, donation_id, profile)
    try:
        pdf_bytes = ai_client.download_acknowledgment(donation_id)
    except Exception as exc:  # noqa: BLE001
        if isinstance(exc, AIServiceHTTPError) and exc.status_code == 404:
            raise HTTPException(
                status_code=404,
                detail="Acknowledgment not found. Generate it first.",
            ) from exc
        _route_ai_failure(exc, fallback="Acknowledgment download failed.")
    return _ack_pdf_response(pdf_bytes, donation_id)