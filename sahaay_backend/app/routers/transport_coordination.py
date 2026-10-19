"""Claim-scoped, persisted transport decisions for provider and NGO participants."""

import logging
from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException

from app.dependencies import require_any_role
from app.schemas.donation import TransportCoordinationResponse
from app.services import notification_service
from app.services.volunteer_transport import first_row
from app.supabase_client import get_supabase_client

logger = logging.getLogger(__name__)
router = APIRouter(prefix="/claims", tags=["transport coordination"])


def _participant_claim(client, claim_id: str, profile: dict) -> tuple[dict, dict]:
    role = profile.get("role")
    if role not in {"provider", "ngo"}:
        raise HTTPException(status_code=403, detail="Provider or NGO access is required.")
    role_row = first_row(profile.get(f"{role}s"))
    if not role_row.get("id"):
        raise HTTPException(status_code=404, detail=f"{role.title()} profile not found.")

    claim_response = (
        client.table("claims").select("*").eq("id", claim_id).maybe_single().execute()
    )
    claim = getattr(claim_response, "data", None)
    if not claim:
        raise HTTPException(status_code=404, detail="Claim not found.")
    donation_response = (
        client.table("donations")
        .select("id,provider_id,food_name,status,expiry_time,pickup_deadline")
        .eq("id", str(claim["donation_id"]))
        .maybe_single()
        .execute()
    )
    donation = getattr(donation_response, "data", None) or {}
    expected_id = (
        donation.get("provider_id") if role == "provider" else claim.get("ngo_id")
    )
    if str(expected_id) != str(role_row["id"]):
        raise HTTPException(status_code=404, detail="Claim not found.")
    return claim, donation


def _delivery_is_open(claim: dict, donation: dict) -> bool:
    if claim.get("status") not in {"pending", "accepted"}:
        return False
    if donation.get("status") in {"expired", "cancelled", "completed", "delivered"}:
        return False
    now = datetime.now(timezone.utc)
    for field in ("expiry_time", "pickup_deadline"):
        raw = donation.get(field)
        if not raw:
            return False
        try:
            deadline = datetime.fromisoformat(str(raw).replace("Z", "+00:00"))
        except ValueError:
            return False
        if deadline.tzinfo is None:
            deadline = deadline.replace(tzinfo=timezone.utc)
        if deadline <= now:
            return False
    return True


@router.get("/{claim_id}/transport-coordination")
def get_transport_coordination(
    claim_id: str, profile: dict = Depends(require_any_role("provider", "ngo"))
) -> dict:
    client = get_supabase_client()
    claim, donation = _participant_claim(client, claim_id, profile)
    try:
        response = (
            client.table("claim_transport_coordination")
            .select("*")
            .eq("claim_id", str(claim["id"]))
            .maybe_single()
            .execute()
        )
    except Exception as exc:
        logger.info("Transport coordination read unavailable (%s)", type(exc).__name__)
        raise HTTPException(
            status_code=503,
            detail="Transport coordination is unavailable until the database migration is applied.",
        ) from exc
    row = getattr(response, "data", None)
    if not row:
        raise HTTPException(
            status_code=503,
            detail="Transport coordination is unavailable until the database migration is applied.",
        )
    delivery_result = (
        client.table("deliveries")
        .select("id,claim_id,status,volunteer_id,pickup_time")
        .eq("claim_id", str(claim["id"]))
        .maybe_single()
        .execute()
    )
    delivery = getattr(delivery_result, "data", None)
    if delivery and delivery.get("volunteer_id"):
        volunteer_result = (
            client.table("volunteers")
            .select("id,user_id")
            .eq("id", str(delivery["volunteer_id"]))
            .maybe_single()
            .execute()
        )
        volunteer = getattr(volunteer_result, "data", None) or {}
        user_result = (
            client.table("users")
            .select("id,full_name,phone")
            .eq("id", str(volunteer.get("user_id")))
            .maybe_single()
            .execute()
        ) if volunteer.get("user_id") else None
        delivery["volunteer"] = getattr(user_result, "data", None) or {}
    return {
        **row,
        "delivery": delivery,
        "delivery_eligible": _delivery_is_open(claim, donation),
    }


@router.post("/{claim_id}/transport-coordination/respond")
def respond_to_transport_coordination(
    claim_id: str,
    payload: TransportCoordinationResponse,
    profile: dict = Depends(require_any_role("provider", "ngo")),
) -> dict:
    role = profile.get("role")
    client = get_supabase_client()
    claim, donation = _participant_claim(client, claim_id, profile)
    try:
        previous_response = (
            client.table("claim_transport_coordination")
            .select("*")
            .eq("claim_id", str(claim["id"]))
            .maybe_single()
            .execute()
        )
    except Exception as exc:
        logger.info("Transport coordination read unavailable (%s)", type(exc).__name__)
        raise HTTPException(
            status_code=503,
            detail="Transport coordination is unavailable until the database migration is applied.",
        ) from exc
    previous = getattr(previous_response, "data", None)
    if not previous:
        raise HTTPException(
            status_code=503,
            detail="Transport coordination is unavailable until the database migration is applied.",
        )

    try:
        result = client.rpc(
            "respond_to_claim_transport",
            {
                "p_claim_id": str(claim["id"]),
                "p_actor_role": role,
                "p_response": payload.response,
                "p_captain_name": payload.captain_name,
                "p_captain_phone": payload.captain_phone,
            },
        ).execute()
    except Exception as exc:
        logger.warning(
            "Transport response RPC failed for claim %s (%s)",
            claim_id,
            type(exc).__name__,
        )
        message = str(exc).lower()
        if any(
            conflict in message
            for conflict in (
                "response has already been submitted",
                "claim is not open",
                "existing delivery task",
            )
        ):
            raise HTTPException(
                status_code=409,
                detail="The claim transport response is already submitted or no longer open.",
            ) from exc
        raise HTTPException(
            status_code=503,
            detail="The transport response could not be saved. Please retry.",
        ) from exc

    coordination = getattr(result, "data", None)
    if isinstance(coordination, list) and len(coordination) == 1:
        coordination = coordination[0]
    if not isinstance(coordination, dict):
        raise HTTPException(
            status_code=502,
            detail="The database returned an invalid transport coordination state.",
        )

    if previous.get(f"{role}_response") is None:
        if (
            coordination.get("responsible_role") in {"provider", "ngo"}
            and previous.get("responsible_role") is None
        ):
            notification_service.transport_responsibility_assigned(
                client,
                donation=donation,
                claim=claim,
                coordination=coordination,
            )
        elif (
            payload.response == "yes"
            and previous.get("responsible_role") in {"provider", "ngo"}
            and coordination.get("responsible_role") != role
        ):
            notification_service.transport_responsibility_confirmed(
                client,
                donation=donation,
                claim=claim,
                coordination=coordination,
                responding_role=role,
            )
        else:
            notification_service.transport_response_received(
                client,
                donation=donation,
                claim=claim,
                coordination=coordination,
                acting_role=role,
            )
        if coordination.get("status") == "searching_for_volunteers":
            notification_service.transport_volunteer_search_started(
                client, donation=donation, claim=claim
            )
    return coordination


@router.post("/{claim_id}/transport-coordination/request-volunteer")
def request_volunteer_delivery(
    claim_id: str,
    profile: dict = Depends(require_any_role("provider", "ngo")),
) -> dict:
    role = profile.get("role")
    client = get_supabase_client()
    claim, donation = _participant_claim(client, claim_id, profile)
    if not _delivery_is_open(claim, donation):
        raise HTTPException(
            status_code=409,
            detail="This claim or delivery has expired or is no longer open.",
        )

    try:
        volunteers = client.table("volunteers").select("id").limit(1).execute().data or []
    except Exception as exc:
        logger.warning("Volunteer eligibility check failed (%s)", type(exc).__name__)
        raise HTTPException(
            status_code=503,
            detail="Volunteer availability could not be checked. Please retry.",
        ) from exc
    if not volunteers:
        raise HTTPException(
            status_code=409,
            detail="No volunteer accounts are currently available. Please retry later.",
        )

    try:
        result = client.rpc(
            "request_claim_volunteer_delivery",
            {
                "p_claim_id": str(claim["id"]),
                "p_actor_role": role,
            },
        ).execute()
    except Exception as exc:
        logger.warning(
            "Volunteer delivery request failed for claim %s (%s)",
            claim_id,
            type(exc).__name__,
        )
        message = str(exc).lower()
        if any(
            phrase in message
            for phrase in (
                "expired",
                "not available",
                "must decline",
                "not open",
                "belongs to another",
            )
        ):
            raise HTTPException(
                status_code=409,
                detail="This claim is no longer eligible for a volunteer request.",
            ) from exc
        raise HTTPException(
            status_code=503,
            detail="The volunteer request could not be saved. Please retry.",
        ) from exc
    outcome = getattr(result, "data", None)
    if isinstance(outcome, list) and len(outcome) == 1:
        outcome = outcome[0]
    if not isinstance(outcome, dict) or not isinstance(
        outcome.get("coordination"), dict
    ):
        raise HTTPException(
            status_code=502,
            detail="The database returned an invalid volunteer request.",
        )
    coordination = outcome["coordination"]
    if outcome.get("created") is True:
        notification_service.transport_volunteer_search_started(
            client, donation=donation, claim=claim
        )
    return {
        **coordination,
        "delivery": outcome.get("delivery"),
        "created": bool(outcome.get("created")),
    }


def coordination_by_claim_ids(client, claims: list[dict]) -> dict[str, dict]:
    ids = [str(row["id"]) for row in claims if row.get("id")]
    if not ids:
        return {}
    try:
        rows = (
            client.table("claim_transport_coordination")
            .select("*")
            .in_("claim_id", ids)
            .execute()
            .data
            or []
        )
    except Exception as exc:
        # Claim list routes remain usable with the pre-migration schema. New
        # coordination actions return an explicit 503 until the migration lands.
        logger.info("Transport coordination enrichment unavailable: %s", type(exc).__name__)
        return {}
    return {str(row["claim_id"]): dict(row) for row in rows if row.get("claim_id")}
