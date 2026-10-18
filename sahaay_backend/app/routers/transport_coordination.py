"""Claim-scoped, persisted transport decisions for provider and NGO participants."""

import logging

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
        .select("id,provider_id,food_name")
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


@router.get("/{claim_id}/transport-coordination")
def get_transport_coordination(
    claim_id: str, profile: dict = Depends(require_any_role("provider", "ngo"))
) -> dict:
    client = get_supabase_client()
    claim, _ = _participant_claim(client, claim_id, profile)
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
    return row


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
