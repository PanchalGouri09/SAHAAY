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

from datetime import datetime, timedelta, timezone
from math import isfinite
from re import compile as _re_compile
from statistics import mean

from fastapi import APIRouter, Depends, HTTPException, Response
from pydantic import ValidationError

from app.dependencies import get_current_profile, require_role
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
from app.services.food_mapping import map_food_category
from app.services.vehicle_logistics import (
    compatibility_detail,
    compatibility_label,
    order_by_logistics,
    requires_volunteer_transport,
    vehicle_compatibility,
)
from app.services.geo_distance import distance_with_fallback
from app.services.profile_completion import (
    ngo_profile_is_complete,
)
from app.supabase_client import get_supabase_client

router = APIRouter(tags=["ai-features"])

_COMPLETED_DONATION_STATUSES = {"completed", "delivered"}
_NGO_OPERATING_TIMEZONE = timezone(timedelta(hours=5, minutes=30), "Asia/Kolkata")

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


def _veg_to_dietary(value) -> str | None:
    if not value:
        return None
    key = str(value).strip().lower()
    return _DIETARY_MAP.get(key)


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
    except (TypeError, ValueError, OverflowError):
        return None
    if not isfinite(value) or value <= 0:
        return None
    unit = str(donation.get("unit") or "").strip().lower()
    factor = _WEIGHT_UNIT_TO_KG.get(unit)
    if factor is None:
        return None
    return value * factor


def _dietary_accepted(raw_values) -> list[str] | None:
    """Maps explicitly saved NGO dietary preferences onto the AI vocabulary."""
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


def _dietary_compatible(donation_type: str, accepted_types: list[str]) -> bool:
    """Apply explicit compatibility rules instead of treating unknown as any."""
    accepted = set(accepted_types)
    if "any" in accepted:
        return True
    if donation_type == "any":
        return {"veg", "non_veg"} <= accepted
    if donation_type == "vegan":
        return accepted.intersection({"vegan", "veg"}) != set()
    return donation_type in accepted


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


def _caller_provider_id(profile: dict) -> str | None:
    """The authenticated provider's id, or None for non-provider accounts
    (never raises, unlike _provider_id_of)."""
    providers = profile.get("providers")
    if not providers:
        return None
    row = providers[0] if isinstance(providers, list) else providers
    return (row or {}).get("id")


def _caller_ngo_id(profile: dict) -> str | None:
    """The authenticated NGO's id, or None for non-NGO accounts."""
    ngos = profile.get("ngos")
    if not ngos:
        return None
    row = ngos[0] if isinstance(ngos, list) else ngos
    return (row or {}).get("id")


def _ngo_claimed(client, donation_id, ngo_id) -> bool:
    """True only when this NGO really has a claim row on this donation."""
    try:
        rows = (
            client.table("claims")
            .select("id")
            .eq("donation_id", str(donation_id))
            .eq("ngo_id", str(ngo_id))
            .execute()
            .data
        ) or []
    except Exception:  # noqa: BLE001
        return False
    return bool(rows)


def _load_authorized_donation(client, donation_id: str, profile: dict) -> dict:
    """Loads a donation the caller is really a party to.

    Allowed: the owning provider, or the NGO that actually claimed it. Everyone
    else (another provider, an NGO with no claim, a volunteer) gets 403, and an
    unknown donation gets 404 — so a receipt can never leak across accounts.
    """
    if not donation_id:
        raise HTTPException(status_code=422, detail="donation_id is required.")
    response = (
        client.table("donations")
        .select("*")
        .eq("id", donation_id)
        .maybe_single()
        .execute()
    )
    donation = getattr(response, "data", None)
    if not donation:
        raise HTTPException(status_code=404, detail="Donation not found.")
    provider_id = _caller_provider_id(profile)
    if provider_id and donation.get("provider_id") == provider_id:
        return donation
    ngo_id = _caller_ngo_id(profile)
    if ngo_id and _ngo_claimed(client, donation_id, ngo_id):
        return donation
    raise HTTPException(
        status_code=403, detail="You are not a party to this donation."
    )


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
def _coordinates_from_row(row: dict) -> tuple[float, float] | None:
    try:
        latitude = float(row["latitude"])
        longitude = float(row["longitude"])
    except (KeyError, TypeError, ValueError, OverflowError):
        return None
    if (
        not isfinite(latitude)
        or not isfinite(longitude)
        or not -90 <= latitude <= 90
        or not -180 <= longitude <= 180
    ):
        return None
    return latitude, longitude


def _pickup_time_is_available(pickup_time: str, hours: tuple[str, str]) -> bool:
    pickup = datetime.strptime(pickup_time, "%H:%M").time()
    start = datetime.strptime(hours[0], "%H:%M").time()
    end = datetime.strptime(hours[1], "%H:%M").time()
    if start <= end:
        return start <= pickup <= end
    return pickup >= start or pickup <= end


def _ngo_candidates(
    client,
    *,
    pickup_time: str,
    quantity_kg: float,
    dietary_type: str,
    food_category: str,
) -> tuple[list[tuple[dict, NGOInput]], bool, bool]:
    """Builds real NGO candidates from the ngos table.

    NGOs lacking real operating hours, location, per-donation kg capacity,
    category preferences, or dietary preferences are excluded. People-served
    capacity and food categories are never treated as weight or dietary data.
    """
    rows = client.table("ngos").select("*").execute().data or []
    user_ids = list(
        dict.fromkeys(str(row["user_id"]) for row in rows if row.get("user_id"))
    )
    users = (
        client.table("users")
        .select("id,role,full_name,email,phone")
        .in_("id", user_ids)
        .execute()
        .data
        or []
    ) if user_ids else []
    users_by_id = {str(row["id"]): row for row in users}
    candidates: list[tuple[dict, NGOInput]] = []
    has_incomplete_profile = False
    for ngo in rows:
        user = users_by_id.get(str(ngo.get("user_id")))
        if not ngo_profile_is_complete(user, ngo):
            has_incomplete_profile = True
            continue
        hours = _availability_hours(ngo)
        coordinates = _coordinates_from_row(ngo)
        capacity = ngo.get("max_capacity_kg")
        try:
            capacity_kg = float(capacity)
        except (TypeError, ValueError, OverflowError):
            has_incomplete_profile = True
            continue
        if (
            hours is None
            or coordinates is None
            or not isfinite(capacity_kg)
            or capacity_kg <= 0
        ):
            has_incomplete_profile = True
            continue
        if quantity_kg > capacity_kg or not _pickup_time_is_available(pickup_time, hours):
            continue
        # Food categories live in SAHAAY's own vocabulary on BOTH the donation
        # ("Cooked Meals", "Rice", ...) and the NGO's preferred_food_types, so a
        # raw string comparison across the two is wrong. Normalise both sides to
        # the AI food-category vocabulary via map_food_category() and require a
        # real overlap. An unmappable donation category (or an NGO that accepts
        # none of the mappable categories) is not a match — never guessed.
        donation_category = map_food_category(food_category)
        raw_food_types = ngo.get("preferred_food_types") or []
        ngo_categories = {
            mapped
            for mapped in (
                map_food_category(value)
                for value in raw_food_types
            )
            if mapped is not None
        }
        if not raw_food_types or not ngo_categories:
            has_incomplete_profile = True
            continue
        if donation_category is None or donation_category not in ngo_categories:
            continue
        dietary = _dietary_accepted(ngo.get("dietary_preferences"))
        if not dietary:
            has_incomplete_profile = True
            continue
        if not _dietary_compatible(dietary_type, dietary):
            continue
        candidates.append(
            (
                ngo,
                NGOInput(
                    ngo_id=str(ngo["id"]),
                    name=ngo.get("organization_name") or "Unknown NGO",
                    latitude=coordinates[0],
                    longitude=coordinates[1],
                    dietary_accepted=dietary,
                    max_capacity_kg=capacity_kg,
                    min_capacity_kg=0.0,
                    available_from=hours[0],
                    available_to=hours[1],
                ),
            )
        )
    return candidates, has_incomplete_profile, bool(rows)


def _pickup_time_of(donation: dict) -> str | None:
    """Convert the pickup instant to the local timezone used by NGO hours.

    NGO hours are local 24-hour clock values. SAHAAY's current service area
    uses Asia/Kolkata; naive legacy timestamps are interpreted as local time.
    """
    deadline = donation.get("pickup_deadline")
    if not deadline:
        return None
    try:
        parsed = datetime.fromisoformat(str(deadline).replace("Z", "+00:00"))
    except (TypeError, ValueError):
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=_NGO_OPERATING_TIMEZONE)
    else:
        parsed = parsed.astimezone(_NGO_OPERATING_TIMEZONE)
    return parsed.strftime("%H:%M")


def _enrich_ranked_ngo(
    item,
    candidate_by_id: dict[str, dict],
    provider_vehicle: bool | None,
) -> dict:
    """Merges an AI-ranked NGO with its real ngos row and the logistics layer.

    AI-estimated fields (distance, per-criterion scores, final_score, rank)
    stay at the top level exactly as the AI returned them and are never
    modified; real factual NGO fields are added under 'ngo' so the two can
    never be confused. Vehicle logistics is a deterministic, transparent
    addition on top of the AI ranking — the AI contract has no vehicle field, so
    no vehicle information is sent to it and none is attributed to it.
    """
    row = candidate_by_id.get(item.ngo_id)
    data = item.model_dump(mode="json") if hasattr(item, "model_dump") else dict(item)
    # Tri-state, straight from the real row. None means "not answered yet"
    # and is passed through as null rather than coerced to false.
    ngo_vehicle = (row or {}).get("vehicle_available")
    compatibility = vehicle_compatibility(provider_vehicle, ngo_vehicle)
    data["ngo"] = {
        "id": item.ngo_id,
        "organization_name": (row or {}).get("organization_name"),
        "city": (row or {}).get("city"),
        "address": (row or {}).get("address"),
        "phone": (row or {}).get("phone"),
        "verified": bool((row or {}).get("verified")),
        "food_capacity": (row or {}).get("food_capacity"),
        "max_capacity_kg": (row or {}).get("max_capacity_kg"),
        "preferred_food_types": (row or {}).get("preferred_food_types") or [],
        "dietary_preferences": (row or {}).get("dietary_preferences") or [],
        "available_from": (row or {}).get("available_from"),
        "available_to": (row or {}).get("available_to"),
        "vehicle_available": ngo_vehicle,
    }
    # Provider side of the same question, so the UI can explain the pairing
    # without a second request. Also tri-state: null = provider has not
    # answered, which is not the same as "no vehicle".
    data["provider_vehicle_available"] = provider_vehicle
    data["vehicle_compatibility"] = compatibility
    data["vehicle_compatibility_label"] = compatibility_label(compatibility)
    data["vehicle_compatibility_detail"] = compatibility_detail(compatibility)
    # A confirmed third-party dependency (never inferred from missing data).
    data["volunteer_transport_required"] = requires_volunteer_transport(
        provider_vehicle, ngo_vehicle
    )
    return data


def _provider_location(provider_row: dict, donation: dict) -> tuple[float | None, float | None]:
    return _coordinates_from_row(provider_row) or _coordinates_from_row(donation) or (
        None,
        None,
    )


# ---------------------------------------------------------------------------
# 2. NGO MATCHING
# ---------------------------------------------------------------------------
def _calculate_ngos_match(
    donation_id: str,
    profile: dict,
    ai_client: AIClient,
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

    dietary_type = _veg_to_dietary(donation.get("veg_type"))
    if dietary_type is None:
        return {
            "status": "insufficient_data",
            "reason": "Donation dietary type is missing or unsupported, so compatibility cannot be verified.",
        }
    food_category = str(donation.get("food_category") or "").strip()
    if map_food_category(food_category) is None:
        return {
            "status": "insufficient_data",
            "reason": "Donation food category is missing or unsupported, so compatible NGOs cannot be identified.",
        }
    candidates, has_incomplete_profile, has_ngo_profiles = _ngo_candidates(
        client,
        pickup_time=pickup_time,
        quantity_kg=quantity_kg,
        dietary_type=dietary_type,
        food_category=food_category,
    )
    if not candidates:
        if not has_ngo_profiles:
            return {
                "status": "no_candidates",
                "reason": (
                    "No completed NGO profiles are available for matching yet. "
                    "Matching will retry after an NGO completes its profile."
                ),
            }
        if has_incomplete_profile:
            return {
                "status": "insufficient_data",
                "reason": (
                    "No completed NGO profiles are available for matching yet. "
                    "Matching will retry after an NGO completes its profile."
                ),
            }
        return {
            "status": "no_candidates",
            "reason": (
                "No NGO matches this donation's pickup time, food category, "
                "dietary preferences, and available capacity."
            ),
        }

    restaurant_reliability = _calculate_reliability(ai_client, client, _provider_id_of(profile))

    request = MatchRequest(
        donation=DonationInput(
            donation_id=donation["id"],
            restaurant_id=_provider_id_of(profile),
            restaurant_latitude=lat,
            restaurant_longitude=lon,
            quantity_kg=quantity_kg,
            dietary_type=dietary_type,
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
    # The provider's own transport capability, tri-state and read from the real
    # providers row. It pairs with each NGO's answer to classify logistics. It
    # is NOT part of the AI request: the AI contract has no vehicle field, so
    # nothing here claims the model learned about vehicles.
    provider_vehicle = (provider_row or {}).get("vehicle_available")
    seen: set[str] = set()
    ranked_ngos = []
    for item in result.ranked_ngos:
        if item.ngo_id in seen:
            continue
        seen.add(item.ngo_id)
        if item.ngo_id not in candidate_by_id:
            continue
        ranked_ngos.append(_enrich_ranked_ngo(item, candidate_by_id, provider_vehicle))

    if seen.intersection(candidate_by_id) != set(candidate_by_id):
        raise HTTPException(
            status_code=502,
            detail="The matching service returned an incomplete eligible-NGO ranking.",
        )

    # Deterministic logistics viability layer applied around the AI ranking (see
    # app/services/vehicle_logistics.py for the documented ordering rule). No
    # AI score is altered, candidates sharing a tier keep the AI's order, and no
    # candidate is ever dropped — including the volunteer_required ones, which
    # stay claimable and are flagged instead of rejected.
    ordered_ngos, logistics_ordered = order_by_logistics(ranked_ngos)
    for match_rank, item in enumerate(ordered_ngos, start=1):
        item["match_rank"] = match_rank
    volunteer_required_ids = [
        item["ngo_id"] for item in ordered_ngos if item["volunteer_transport_required"]
    ]

    return {
        "status": "ok",
        "donation_id": result.donation_id,
        "ranked_ngos": ordered_ngos,
        "weights_used": result.weights_used,
        "insufficient_reason": None,
        # Transport capability of the requesting provider, so the UI can render
        # the pairing without a second request. null = not answered.
        "provider_vehicle_available": provider_vehicle,
        # True only when the logistics layer actually changed the AI's order.
        "logistics_ordering_applied": logistics_ordered,
        # NGOs that can only be served if a volunteer transports the food.
        "volunteer_transport_required": bool(volunteer_required_ids),
        "volunteer_required_ngo_ids": volunteer_required_ids,
    }


def _saved_match_response(client, donation_id: str) -> dict | None:
    persisted = (
        client.table("donation_match_candidates")
        .select("*")
        .eq("donation_id", donation_id)
        .order("match_rank")
        .execute()
        .data
        or []
    )
    if not persisted:
        return None
    ngo_ids = list(
        dict.fromkeys(str(row["ngo_id"]) for row in persisted if row.get("ngo_id"))
    )
    ngo_rows = (
        client.table("ngos")
        .select("*")
        .in_("id", ngo_ids)
        .execute()
        .data
        or []
    ) if ngo_ids else []
    ngo_by_id = {str(row["id"]): row for row in ngo_rows}
    donation_response = (
        client.table("donations")
        .select("*")
        .eq("id", donation_id)
        .maybe_single()
        .execute()
    )
    donation = getattr(donation_response, "data", None) or {}
    provider_response = (
        client.table("providers")
        .select("latitude,longitude")
        .eq("id", str(donation.get("provider_id")))
        .maybe_single()
        .execute()
        if donation.get("provider_id")
        else None
    )
    provider = getattr(provider_response, "data", None) or {}
    pickup_location = _provider_location(provider, donation)
    ranked = []
    for candidate in persisted:
        details = candidate.get("score_details")
        details = details if isinstance(details, dict) else {}
        ngo = ngo_by_id.get(str(candidate.get("ngo_id")), {})
        details = distance_with_fallback(details, {
            "latitude": pickup_location[0],
            "longitude": pickup_location[1],
        }, ngo)
        ranked.append(
            {
                **details,
                "ngo_id": str(candidate.get("ngo_id") or ""),
                "ngo_name": ngo.get("organization_name") or "Eligible NGO",
                "rank": candidate.get("ai_rank"),
                "match_rank": candidate.get("match_rank"),
                "final_score": candidate.get("final_score"),
                "ngo": {
                    "id": str(candidate.get("ngo_id") or ""),
                    "organization_name": ngo.get("organization_name"),
                    "city": ngo.get("city"),
                    "address": ngo.get("address"),
                    "phone": ngo.get("phone"),
                    "verified": bool(ngo.get("verified")),
                    "food_capacity": ngo.get("food_capacity"),
                    "max_capacity_kg": ngo.get("max_capacity_kg"),
                    "preferred_food_types": ngo.get("preferred_food_types") or [],
                    "dietary_preferences": ngo.get("dietary_preferences") or [],
                    "available_from": ngo.get("available_from"),
                    "available_to": ngo.get("available_to"),
                    "vehicle_available": ngo.get("vehicle_available"),
                },
            }
        )
    volunteer_required_ids = [
        item["ngo_id"]
        for item in ranked
        if item.get("volunteer_transport_required")
    ]
    return {
        "status": "ok",
        "donation_id": donation_id,
        "ranked_ngos": ranked,
        "weights_used": {},
        "matching_state": "persisted",
        "provider_vehicle_available": (
            ranked[0].get("provider_vehicle_available") if ranked else None
        ),
        "logistics_ordering_applied": any(
            item.get("rank") != item.get("match_rank") for item in ranked
        ),
        "volunteer_transport_required": bool(volunteer_required_ids),
        "volunteer_required_ngo_ids": volunteer_required_ids,
    }


@router.post("/api/v1/donations/{donation_id}/match")
def match_ngos(
    donation_id: str,
    profile: dict = Depends(require_role("provider")),
    ai_client: AIClient = Depends(get_ai_client),
) -> dict:
    """Ensure one authoritative ranking exists and return its persisted order."""
    from app.services.donation_offers import persist_ranked_candidates

    client = get_supabase_client()
    _load_owned_donation(client, donation_id, profile)
    saved = _saved_match_response(client, donation_id)
    if saved is not None:
        return saved

    result = _calculate_ngos_match(donation_id, profile, ai_client)
    if result.get("status") != "ok":
        return result

    try:
        result["offer_sequence"] = persist_ranked_candidates(
            client,
            donation_id=donation_id,
            ranked_ngos=result.get("ranked_ngos") or [],
        )
    except Exception as exc:  # noqa: BLE001
        raise HTTPException(
            status_code=503,
            detail="Eligible NGOs were matched, but their ranked offers could not be saved.",
        ) from exc
    saved = _saved_match_response(client, donation_id)
    if saved is None:
        raise HTTPException(
            status_code=503,
            detail="Matching completed, but the authoritative ranking could not be read back.",
        )
    saved["offer_sequence"] = result["offer_sequence"]
    saved["matching_state"] = result["offer_sequence"].get("status", "persisted")
    return saved


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
    profile: dict = Depends(get_current_profile),
    ai_client: AIClient = Depends(get_ai_client),
) -> Response:
    client = get_supabase_client()
    donation = _load_authorized_donation(client, donation_id, profile)
    # Serve the persisted copy first: it survives an app or AI-service restart.
    pdf_bytes = _stored_acknowledgment(client, donation)
    if pdf_bytes is None:
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


def _stored_acknowledgment(client, donation: dict) -> bytes | None:
    """The persisted PDF bytes for a donation, if any (None when not stored)."""
    from app.services.acknowledgment import load_persisted_pdf

    return load_persisted_pdf(client, donation)