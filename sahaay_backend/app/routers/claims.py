from fastapi import APIRouter, Depends, HTTPException, status

from app.dependencies import require_role
from app.schemas.donation import ClaimCreate
from app.services.volunteer_transport import (
    VolunteerTransportTaskError,
    first_row,
    publish_volunteer_transport_task,
    recompute_volunteer_transport_required,
)
from app.supabase_client import get_supabase_client

router = APIRouter(prefix="/claims", tags=["claims"])


@router.post("", status_code=status.HTTP_201_CREATED)
def create_claim(payload: ClaimCreate, profile: dict = Depends(require_role("ngo"))) -> dict:
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

    # The claim is the first point where the provider<->NGO pair is concrete, so
    # this is where vehicle compatibility becomes operational. When neither side
    # has transport a claimable volunteer task is published.
    #
    # A publication failure is deliberately NOT swallowed into `logistics: {}`.
    # The claim itself already exists, so it cannot be un-made, and quietly
    # returning an empty summary would tell the NGO everything is fine while
    # leaving a genuine volunteer need with no task behind it. The failure is
    # reported as a real error so the caller knows transport is unresolved.
    logistics: dict = {}
    try:
        donation = (
            client.table("donations")
            .select("id,provider_id,pickup_address,pickup_deadline")
            .eq("id", str(payload.donation_id))
            .maybe_single()
            .execute()
        )
        if getattr(donation, "data", None):
            logistics = publish_volunteer_transport_task(
                client, donation.data, ngo, str(claim["id"])
            )
    except VolunteerTransportTaskError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc

    # The claim exists, so the donation's requirement is now derived from it. A
    # full recompute (rather than trusting the publication result) keeps the flag
    # consistent with every OTHER live claim on the same donation.
    recompute_volunteer_transport_required(client, str(payload.donation_id))

    return {**claim, "logistics": logistics}


@router.get("")
def list_claims(profile: dict = Depends(require_role("ngo"))) -> list[dict]:
    ngo = profile.get("ngos")
    if not ngo:
        raise HTTPException(status_code=404, detail="NGO profile not found.")
    ngo_id = ngo[0]["id"] if isinstance(ngo, list) else ngo["id"]
    response = get_supabase_client().table("claims").select("*").eq("ngo_id", ngo_id).order("created_at", desc=True).execute()
    return response.data or []


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
    return response.data or []


@router.patch("/{claim_id}")
def update_claim(claim_id: str, status: str, profile: dict = Depends(require_role("ngo"))) -> dict:
    if status not in {"pending", "accepted", "rejected", "cancelled", "completed"}:
        raise HTTPException(status_code=422, detail="Invalid claim status.")
    ngo = profile.get("ngos")
    if not ngo:
        raise HTTPException(status_code=404, detail="NGO profile not found.")
    ngo_id = ngo[0]["id"] if isinstance(ngo, list) else ngo["id"]
    client = get_supabase_client()
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
    donation_id = claim.get("donation_id")
    if donation_id:
        recompute_volunteer_transport_required(client, donation_id)

    return claim
