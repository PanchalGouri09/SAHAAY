"""NGO response endpoints for server-generated, ranked donation offers."""

import logging
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel

from app.dependencies import require_role
from app.services.donation_offers import respond_to_offer
from app.services.profile_completion import (
    require_complete_profile,
    ngo_profile_is_complete,
)
from app.services.geo_distance import coordinates, distance_with_fallback
from app.supabase_client import get_supabase_client

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/donation-offers", tags=["donation-offers"])
donation_router = APIRouter(prefix="/donations", tags=["donation-offers"])


class OfferResponse(BaseModel):
    decision: Literal["accepted", "declined"]


@donation_router.get("/{donation_id}/offers")
def get_persisted_offers(
    donation_id: str,
    profile: dict = Depends(require_role("provider")),
) -> dict:
    """Refresh candidates idempotently, then return the persisted ranking."""
    from app.routers.ai_features import _calculate_ngos_match, _load_owned_donation
    from app.services.ai_client import get_ai_client

    client = get_supabase_client()
    donation = _load_owned_donation(client, donation_id, profile)
    refresh_error: HTTPException | None = None
    try:
        match_result = _calculate_ngos_match(
            donation_id, profile, get_ai_client()
        )
    except HTTPException as exc:
        refresh_error = exc
        match_result = {}
    persistence_result = None
    if match_result.get("status") == "ok":
        from app.services.donation_offers import persist_ranked_candidates

        persistence_result = persist_ranked_candidates(
            client,
            donation_id=donation_id,
            ranked_ngos=match_result.get("ranked_ngos") or [],
        )
    candidates = (
        client.table("donation_match_candidates")
        .select("*")
        .eq("donation_id", donation_id)
        .order("match_rank")
        .execute()
        .data
        or []
    )
    if refresh_error and not candidates:
        raise refresh_error
    if (
        match_result.get("status") == "ok"
        and not candidates
        and persistence_result is not None
    ):
        raise HTTPException(
            status_code=502,
            detail=(
                "Matching produced ranked NGOs, but the database did not save "
                "any candidates. Please retry matching."
            ),
        )
    candidate_ngo_ids = list(
        dict.fromkeys(str(candidate["ngo_id"]) for candidate in candidates if candidate.get("ngo_id"))
    )
    ngo_rows = (
        client.table("ngos")
        .select("id,organization_name,city,latitude,longitude")
        .in_("id", candidate_ngo_ids)
        .execute()
        .data
        or []
    ) if candidate_ngo_ids else []
    ngo_by_id = {str(row["id"]): row for row in ngo_rows}
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
    pickup = provider if coordinates(provider) is not None else donation
    enriched_candidates = []
    for candidate in candidates:
        ngo = ngo_by_id.get(str(candidate.get("ngo_id")), {})
        details = candidate.get("score_details")
        details = distance_with_fallback(
            details if isinstance(details, dict) else {},
            pickup,
            ngo,
        )
        enriched = {
            **candidate,
            "ngo": {
                "organization_name": ngo.get("organization_name"),
                "city": ngo.get("city"),
            }
            if ngo
            else None,
        }
        if details:
            enriched["score_details"] = details
        enriched_candidates.append(enriched)
    candidates = enriched_candidates
    offer_rows = (
        client.table("donation_offers")
        .select("*")
        .eq("donation_id", donation_id)
        .order("candidate_rank")
        .execute()
        .data
        or []
    )
    current_offer = next(
        (offer for offer in offer_rows if offer.get("status") == "pending"), None
    )
    refresh_warning = (
        "Matching refresh is unavailable; showing the last saved results."
        if refresh_error
        else None
    )
    if (
        candidates
        and not current_offer
        and not any(offer.get("status") == "accepted" for offer in offer_rows)
        and match_result.get("status") in {"insufficient_data", "no_candidates"}
        and match_result.get("reason")
    ):
        refresh_warning = (
            f"Latest matching refresh: {match_result['reason']} "
            "Previously saved results are shown."
        )
    matching_reason = None
    if current_offer:
        matching_state = "active"
    elif any(offer.get("status") == "accepted" for offer in offer_rows):
        matching_state = "accepted"
    elif donation.get("status") != "available":
        matching_state = "closed"
    elif not candidates:
        match_status = match_result.get("status")
        match_reason = match_result.get("reason")
        if match_status == "insufficient_data":
            matching_state = "insufficient_data"
            matching_reason = match_reason or (
                "Donation details are incomplete for matching. Update the missing "
                "details and refresh matching."
            )
        elif match_status == "no_candidates" and match_reason:
            matching_state = "no_candidates"
            matching_reason = match_reason
        elif match_status not in {"no_candidates", None}:
            raise HTTPException(
                status_code=502,
                detail="Matching did not complete successfully. Please retry matching.",
            )
        else:
            ngos = client.table("ngos").select("*").execute().data or []
            user_ids = list(
                dict.fromkeys(str(row["user_id"]) for row in ngos if row.get("user_id"))
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
            if not any(
                ngo_profile_is_complete(users_by_id.get(str(row.get("user_id"))), row)
                for row in ngos
            ):
                matching_state = "no_matching_profiles"
                matching_reason = (
                    "No completed NGO profiles are available for matching yet. "
                    "Matching will retry after an NGO completes its profile."
                )
            else:
                matching_state = "no_candidates"
                matching_reason = (
                    "No compatible NGO candidates were returned for this donation."
                )
    else:
        matching_state = "exhausted"

    return {
        "donation_id": donation_id,
        "matching_state": matching_state,
        "matching_reason": matching_reason,
        "refresh_warning": refresh_warning,
        "ranked_candidates": candidates,
        "current_offer": current_offer,
        "offers": offer_rows,
    }


@donation_router.post("/{donation_id}/offers/escalation-check")
def check_provider_offer_escalation(
    donation_id: str,
    profile: dict = Depends(require_role("provider")),
) -> dict:
    """Advance a due ranked offer through the same database RPC as the scheduler."""
    from app.routers.ai_features import _load_owned_donation

    client = get_supabase_client()
    _load_owned_donation(client, donation_id, profile)
    try:
        pending = (
            client.table("donation_offers")
            .select("id,offer_expires_at")
            .eq("donation_id", donation_id)
            .eq("status", "pending")
            .limit(1)
            .maybe_single()
            .execute()
            .data
        )
        if not pending:
            return {"status": "no_active_offer", "changed": False}

        result = respond_to_offer(
            client,
            offer_id=str(pending["id"]),
            ngo_id=None,
            decision="timeout",
        )
    except Exception as exc:  # noqa: BLE001
        logger.error(
            "Ranked-offer escalation check failed error_type=%s",
            type(exc).__name__,
        )
        raise HTTPException(
            status_code=503,
            detail="Unable to check the ranked offer deadline.",
        ) from exc

    return {
        "status": result.get("status", "unknown"),
        "changed": bool(result.get("changed")),
        "exhausted": bool(result.get("exhausted")),
        "next_offer_active": isinstance(result.get("next_offer"), dict),
        "offer_expires_at": (
            result.get("next_offer", {}).get("offer_expires_at")
            if isinstance(result.get("next_offer"), dict)
            else pending.get("offer_expires_at")
        ),
    }


@router.get("")
def list_ngo_offers(profile: dict = Depends(require_role("ngo"))) -> list[dict]:
    """List persisted offer history addressed to the authenticated NGO."""
    ngo = profile.get("ngos")
    ngo = ngo[0] if isinstance(ngo, list) else ngo
    if not ngo or not ngo.get("id"):
        raise HTTPException(status_code=404, detail="NGO profile not found.")

    client = get_supabase_client()
    offers = (
        client.table("donation_offers")
        .select("*")
        .eq("ngo_id", str(ngo["id"]))
        .order("created_at", desc=True)
        .limit(100)
        .execute()
        .data
        or []
    )
    donation_ids = list(dict.fromkeys(str(row["donation_id"]) for row in offers))
    if not donation_ids:
        return []

    donations = (
        client.table("donations")
        .select("*")
        .in_("id", donation_ids)
        .execute()
        .data
        or []
    )
    donation_by_id = {str(row["id"]): row for row in donations}
    candidates = (
        client.table("donation_match_candidates")
        .select("*")
        .in_("donation_id", donation_ids)
        .eq("ngo_id", str(ngo["id"]))
        .execute()
        .data
        or []
    )
    candidate_by_donation = {
        str(row["donation_id"]): row for row in candidates
    }
    provider_ids = list(
        dict.fromkeys(
            str(donation.get("provider_id"))
            for donation in donations
            if donation.get("provider_id")
        )
    )
    provider_rows = (
        client.table("providers")
        .select("id,latitude,longitude")
        .in_("id", provider_ids)
        .execute()
        .data
        or []
    ) if provider_ids else []
    provider_by_id = {str(row["id"]): row for row in provider_rows}
    result = []
    for offer in offers:
        offer_donation = donation_by_id.get(str(offer["donation_id"]))
        candidate = candidate_by_donation.get(str(offer["donation_id"]))
        if candidate is not None and offer_donation is not None:
            provider = provider_by_id.get(
                str(offer_donation.get("provider_id")), {}
            )
            pickup = provider if coordinates(provider) is not None else offer_donation
            details = candidate.get("score_details")
            candidate = {
                **candidate,
            }
            details = distance_with_fallback(
                details if isinstance(details, dict) else {},
                pickup,
                ngo,
            )
            if details:
                candidate["score_details"] = details
        result.append(
            {
                **offer,
                "donation": offer_donation,
                "ranked_candidate": candidate,
            }
        )
    return result


@router.post("/{offer_id}/respond")
def respond(
    offer_id: str,
    payload: OfferResponse,
    profile: dict = Depends(require_role("ngo")),
) -> dict:
    if payload.decision == "accepted":
        require_complete_profile(profile, action="accepting a donation offer")
    ngo = profile.get("ngos")
    ngo = ngo[0] if isinstance(ngo, list) else ngo
    if not ngo or not ngo.get("id"):
        raise HTTPException(status_code=404, detail="NGO profile not found.")

    try:
        result = respond_to_offer(
            get_supabase_client(),
            offer_id=offer_id,
            ngo_id=str(ngo["id"]),
            decision=payload.decision,
        )
    except Exception as exc:  # noqa: BLE001
        raise HTTPException(
            status_code=503, detail="Unable to process the donation offer."
        ) from exc

    status = result.get("status")
    if status == "not_found":
        raise HTTPException(status_code=404, detail="Donation offer not found.")
    if status == "not_your_offer":
        raise HTTPException(status_code=403, detail="This offer belongs to another NGO.")
    if status == "ngo_not_eligible":
        raise HTTPException(
            status_code=403,
            detail="Complete the NGO profile before accepting this offer.",
        )
    if status == "not_due":
        raise HTTPException(
            status_code=409, detail="The five-minute offer deadline has not elapsed."
        )
    if status == "timed_out":
        raise HTTPException(
            status_code=409,
            detail="The five-minute offer deadline has passed; this offer timed out.",
        )
    if status in {"donation_closed", "expired"}:
        raise HTTPException(
            status_code=409, detail="This donation is no longer available."
        )
    if status in {"accepted", "declined", "timed_out"} and result.get("changed") is False:
        raise HTTPException(
            status_code=409,
            detail="This offer has already been responded to.",
        )
    if not result:
        raise HTTPException(
            status_code=503, detail="The offer response returned no result."
        )
    return result
