import logging

from fastapi import APIRouter, Depends, HTTPException, status

from app.dependencies import require_role
from app.schemas.donation import ClaimCreate
from app.services import notification_service
from app.services.volunteer_transport import (
    first_row,
    recompute_volunteer_transport_required,
)
from app.supabase_client import get_supabase_client
from app.services.profile_completion import require_complete_profile
from app.routers.transport_coordination import coordination_by_claim_ids

router = APIRouter(prefix="/claims", tags=["claims"])
logger = logging.getLogger(__name__)


def _enrich_claims(client, claims: list[dict]) -> list[dict]:
    """Attach the claimed donation (and its provider) to each claim.

    The NGO "My Claims" screen needs the food name and the real provider
    organisation, not just the raw claim row. Enrichment is best-effort: a
    claim whose donation row is missing is returned untouched rather than
    failing the whole list.
    """
    if not claims:
        return claims

    donation_ids = list({str(c["donation_id"]) for c in claims if c.get("donation_id")})
    if not donation_ids:
        return claims

    donations_by_id: dict[str, dict] = {}
    provider_ids: set[str] = set()
    donation_rows = (
        client.table("donations").select("*").in_("id", donation_ids).execute().data or []
    )
    for row in donation_rows:
        donations_by_id[str(row["id"])] = dict(row)
        if row.get("provider_id") is not None:
            provider_ids.add(str(row["provider_id"]))

    providers_by_id: dict[str, dict] = {}
    if provider_ids:
        provider_rows = (
            client.table("providers").select("*").in_("id", list(provider_ids)).execute().data or []
        )
        providers_by_id = {str(p["id"]): dict(p) for p in provider_rows}

    ngos_by_id: dict[str, dict] = {}
    ngo_ids = list({str(c["ngo_id"]) for c in claims if c.get("ngo_id")})
    if ngo_ids:
        ngo_rows = (
            client.table("ngos")
            .select("id,organization_name,address,city,phone,latitude,longitude")
            .in_("id", ngo_ids)
            .execute()
            .data
            or []
        )
        ngos_by_id = {str(row["id"]): dict(row) for row in ngo_rows}

    deliveries_by_donation: dict[str, dict] = {}
    delivery_rows = (
        client.table("deliveries")
        .select("*")
        .in_("donation_id", donation_ids)
        .execute()
        .data
        or []
    )
    volunteer_ids = list({
        str(row["volunteer_id"])
        for row in delivery_rows
        if row.get("volunteer_id")
    })
    volunteers_by_id: dict[str, dict] = {}
    if volunteer_ids:
        volunteer_rows = (
            client.table("volunteers")
            .select("id,user_id")
            .in_("id", volunteer_ids)
            .execute()
            .data
            or []
        )
        volunteer_user_ids = list({
            str(row["user_id"]) for row in volunteer_rows if row.get("user_id")
        })
        users = (
            client.table("users")
            .select("id,full_name,phone")
            .in_("id", volunteer_user_ids)
            .execute()
            .data
            or []
        ) if volunteer_user_ids else []
        user_by_id = {str(row["id"]): row for row in users}
        volunteers_by_id = {
            str(row["id"]): dict(user_by_id.get(str(row.get("user_id")), {}))
            for row in volunteer_rows
        }
    for delivery in delivery_rows:
        volunteer = volunteers_by_id.get(str(delivery.get("volunteer_id")))
        deliveries_by_donation[str(delivery["donation_id"])] = {
            **delivery,
            "volunteer": volunteer,
        }

    for donation in donations_by_id.values():
        provider = providers_by_id.get(str(donation.get("provider_id")))
        if provider is not None:
            donation["provider"] = provider

    enriched: list[dict] = []
    for claim in claims:
        donation = donations_by_id.get(str(claim.get("donation_id")))
        enriched_claim = (
            {**claim, "donation": donation} if donation is not None else dict(claim)
        )
        if donation is not None:
            provider = providers_by_id.get(str(donation.get("provider_id")))
            if provider is not None:
                enriched_claim["provider"] = provider
        if claim.get("ngo_id"):
            ngo = ngos_by_id.get(str(claim["ngo_id"]))
            if ngo is not None:
                enriched_claim["ngo"] = ngo
        delivery = deliveries_by_donation.get(str(claim.get("donation_id")))
        if delivery is not None:
            enriched_claim["delivery"] = delivery
        enriched.append(enriched_claim)
    coordination_by_id = coordination_by_claim_ids(client, claims)
    for claim in enriched:
        coordination = coordination_by_id.get(str(claim.get("id")))
        if coordination is not None:
            claim["transport_coordination"] = coordination
    return enriched


@router.post("", status_code=status.HTTP_201_CREATED)
def create_claim(
    payload: ClaimCreate,
    profile: dict = Depends(require_role("ngo")),
) -> dict:
    require_complete_profile(profile, action="claiming a donation")
    ngo = first_row(profile.get("ngos"))
    if not ngo:
        raise HTTPException(status_code=404, detail="NGO profile not found.")
    ngo_id = ngo["id"]
    client = get_supabase_client()
    try:
        response = client.table("claims").insert({
            "donation_id": str(payload.donation_id),
            "ngo_id": ngo_id,
            "requested_quantity": payload.requested_quantity,
            "notes": payload.notes,
            # Set explicitly rather than left to the column default. The volunteer
            # transport lifecycle now reads this value to decide whether a claim
            # is live, so the initial state is stated here instead of being
            # inherited silently. This matches the existing 'pending' default and
            # introduces no new status.
            "status": "pending",
        }).select().execute()
        claim = response.data[0]
    except Exception as exc:
        raise HTTPException(status_code=500, detail="Unable to create claim.") from exc

    # Volunteer availability is now activated only when both authenticated
    # participants decline transport, not merely because their profile vehicle
    # flags are false.
    logistics = {
        "vehicle_compatibility": None,
        "vehicle_compatibility_label": "Transport response needed",
        "vehicle_compatibility_detail": (
            "The provider and NGO must confirm who will transport this donation."
        ),
        "volunteer_transport_required": False,
        "delivery_id": None,
        "delivery_created": False,
    }

    # The claim exists, so the donation's requirement is now derived from it. A
    # full recompute (rather than trusting the publication result) keeps the flag
    # consistent with every OTHER live claim on the same donation.
    recompute_volunteer_transport_required(client, str(payload.donation_id))

    # The donation's provider is told a claim was submitted. The recipient is
    # resolved server-side from the donation row; the sending NGO is never a
    # client-supplied value. Best-effort: never fails the created claim.
    donation_row = (
        client.table("donations")
        .select("*")
        .eq("id", str(payload.donation_id))
        .maybe_single()
        .execute()
    )
    notification_service.claim_created(
        client, donation=getattr(donation_row, "data", None), ngo_row=ngo
    )
    try:
        coordination = (
            client.table("claim_transport_coordination")
            .select("id")
            .eq("claim_id", str(claim["id"]))
            .maybe_single()
            .execute()
        )
        if getattr(coordination, "data", None):
            notification_service.transport_coordination_started(
                client,
                donation=getattr(donation_row, "data", None),
                claim=claim,
                ngo_row=ngo,
            )
    except Exception as exc:
        # A local backend can run before the additive migration is applied.
        # Existing claim creation remains available; coordination endpoints
        # explicitly report the missing schema rather than inventing state.
        logger.info(
            "Transport prompt skipped because coordination schema is unavailable (%s)",
            type(exc).__name__,
        )

    return {**claim, "logistics": logistics}


@router.get("")
def list_claims(profile: dict = Depends(require_role("ngo"))) -> list[dict]:
    ngo = profile.get("ngos")
    if not ngo:
        raise HTTPException(status_code=404, detail="NGO profile not found.")
    ngo_id = ngo[0]["id"] if isinstance(ngo, list) else ngo["id"]
    client = get_supabase_client()
    response = client.table("claims").select("*").eq("ngo_id", ngo_id).order("created_at", desc=True).execute()
    return _enrich_claims(client, response.data or [])


@router.get("/provider")
def list_provider_claims(profile: dict = Depends(require_role("provider"))) -> list[dict]:
    provider = profile.get("providers")
    if not provider:
        raise HTTPException(status_code=404, detail="Provider profile not found.")
    provider_id = provider[0]["id"] if isinstance(provider, list) else provider["id"]
    client = get_supabase_client()
    donations = client.table("donations").select("id").eq("provider_id", provider_id).execute().data or []
    donation_ids = [donation["id"] for donation in donations]
    if not donation_ids:
        return []
    response = client.table("claims").select("*").in_("donation_id", donation_ids).order("created_at", desc=True).execute()
    return _enrich_claims(client, response.data or [])


@router.patch("/{claim_id}")
def update_claim(
    claim_id: str,
    status: str,
    profile: dict = Depends(require_role("ngo")),
) -> dict:
    if status not in {"pending", "accepted", "rejected", "cancelled", "completed"}:
        raise HTTPException(status_code=422, detail="Invalid claim status.")
    if status == "accepted":
        require_complete_profile(profile, action="accepting a donation claim")
    ngo = profile.get("ngos")
    if not ngo:
        raise HTTPException(status_code=404, detail="NGO profile not found.")
    ngo_id = ngo[0]["id"] if isinstance(ngo, list) else ngo["id"]
    client = get_supabase_client()

    # Snapshot the donation and the OTHER pending claims BEFORE the update so the
    # recipients of an acceptance are the real NGOs that were competing, never a
    # client-supplied list. The database trigger rejects the displaced claims, so
    # the "other pending" set only exists in its pre-update form.
    previous = (
        client.table("claims")
        .select("id,donation_id,status")
        .eq("id", claim_id)
        .eq("ngo_id", ngo_id)
        .maybe_single()
        .execute()
    )
    previous_row = getattr(previous, "data", None) or {}
    donation_id = previous_row.get("donation_id")
    other_pending_ngo_ids: list[str] = []
    if status == "accepted" and donation_id:
        siblings = (
            client.table("claims")
            .select("id,ngo_id,status")
            .eq("donation_id", str(donation_id))
            .eq("status", "pending")
            .execute()
        )
        other_pending_ngo_ids = [
            str(row["ngo_id"])
            for row in (getattr(siblings, "data", None) or [])
            if str(row.get("id")) != str(claim_id) and row.get("ngo_id")
        ]

    response = client.table("claims").update({"status": status}).eq("id", claim_id).eq("ngo_id", ngo_id).select().execute()
    if not response.data:
        raise HTTPException(status_code=404, detail="Claim not found for this NGO.")
    claim = response.data[0]

    # The claim's status decides whether it still counts towards the donation's
    # volunteer requirement, so the flag is recalculated from the current live
    # claims on every transition. Recomputing (rather than clearing on
    # cancellation) is what keeps this correct when other live claims on the same
    # donation still require a volunteer.
    #
    # claims.donation_id is NOT NULL, so this is always present in a real row;
    # the guard only keeps a partial row from failing the status update itself.
    donation_id = claim.get("donation_id") or donation_id
    if donation_id:
        recompute_volunteer_transport_required(client, donation_id)

    # Provider + displaced NGOs are told about the real status change. The acting
    # NGO is never notified about its own action.
    notification_service.claim_status_changed(
        client,
        claim=claim,
        new_status=status,
        other_pending_ngo_ids=other_pending_ngo_ids,
    )

    return claim
