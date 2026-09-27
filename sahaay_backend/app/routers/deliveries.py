from fastapi import APIRouter, Depends, HTTPException

from app.dependencies import require_role
from app.schemas.donation import DeliveryStatusUpdate
from app.services.volunteer_transport import first_row, is_live_claim_status
from app.supabase_client import get_supabase_client

router = APIRouter(prefix="/deliveries", tags=["deliveries"])


@router.get("")
def list_deliveries(profile: dict = Depends(require_role("volunteer"))) -> list[dict]:
    """Deliveries already accepted by the authenticated volunteer.

    Deliberately unchanged: it only ever returns work this volunteer has
    personally accepted. Open work nobody has taken is a separate, clearly
    labelled view — see GET /deliveries/transport-required.
    """
    volunteer = first_row(profile.get("volunteers"))
    if not volunteer:
        raise HTTPException(status_code=404, detail="Volunteer profile not found.")
    volunteer_id = volunteer["id"]
    response = get_supabase_client().table("deliveries").select("*").eq("volunteer_id", volunteer_id).order("created_at", desc=True).execute()
    return response.data or []


@router.get("/transport-required")
def list_transport_required(
    profile: dict = Depends(require_role("volunteer")),
) -> list[dict]:
    """Open volunteer transport tasks that nobody has accepted yet.

    These are donations where the provider and the claiming NGO both reported no
    vehicle, so `deliveries.status = 'unassigned'` and `volunteer_id IS NULL`.
    Listing them here is what makes them *discoverable*; nothing is assigned by
    this endpoint and no volunteer is invented.

    A task is discoverable only while BOTH the delivery is still `unassigned` AND
    the underlying claim is still live (`pending`/`accepted`/`completed`). A task
    whose claim has been `cancelled` or `rejected` is never returned, so a
    withdrawn offer cannot keep sending volunteers to a stale destination.

    Each row is enriched with the real donation, provider and NGO facts a
    volunteer needs to decide. Fields that are genuinely NULL in the database are
    returned as null rather than filled in with a placeholder.
    """
    volunteer = first_row(profile.get("volunteers"))
    if not volunteer:
        raise HTTPException(status_code=404, detail="Volunteer profile not found.")

    client = get_supabase_client()
    tasks = (
        client.table("deliveries")
        .select("*")
        .is_("volunteer_id", None)
        .eq("status", "unassigned")
        .order("created_at", desc=True)
        .execute()
        .data
        or []
    )
    if not tasks:
        return []

    # A task is only discoverable while the CLAIM behind it is still live.
    #
    # `status='unassigned'` alone is not sufficient: a donation can only ever
    # have one delivery row (UNIQUE on deliveries.donation_id), so a row created
    # for one claim outlives that claim. Once that claim is cancelled or
    # rejected the row would otherwise keep advertising a withdrawn NGO as the
    # destination forever, with no way for a volunteer to tell it is dead.
    #
    # So the claim status is resolved and filtered here, and it is the actual
    # authority: `cancelled`/`rejected` claims never produce a discoverable task.
    #
    # A row with no resolvable claim is dropped rather than shown. Refusing to
    # advertise a task whose origin cannot be verified is the safe direction:
    # hiding real work is recoverable, sending a volunteer to a withdrawn
    # destination is not.
    all_claim_ids = sorted({str(t["claim_id"]) for t in tasks if t.get("claim_id")})
    all_claims = (
        client.table("claims")
        .select("id,ngo_id,requested_quantity,status")
        .in_("id", all_claim_ids)
        .execute()
        .data
        or []
    ) if all_claim_ids else []
    claim_by_id = {str(c["id"]): c for c in all_claims}

    tasks = [
        t
        for t in tasks
        if is_live_claim_status(claim_by_id.get(str(t.get("claim_id")), {}).get("status"))
    ]
    if not tasks:
        return []

    donation_ids = sorted({str(t["donation_id"]) for t in tasks if t.get("donation_id")})
    donations = (
        client.table("donations")
        .select(
            "id,food_name,quantity,unit,servings,veg_type,pickup_address,"
            "latitude,longitude,pickup_deadline,expiry_time,status,"
            "volunteer_transport_required,provider_id"
        )
        .in_("id", donation_ids)
        .execute()
        .data
        or []
    )
    donation_by_id = {str(d["id"]): d for d in donations}

    provider_ids = sorted({str(d["provider_id"]) for d in donations if d.get("provider_id")})
    providers = (
        client.table("providers")
        .select("id,organization_name,address,city,phone,vehicle_available")
        .in_("id", provider_ids)
        .execute()
        .data
        or []
    ) if provider_ids else []
    provider_by_id = {str(p["id"]): p for p in providers}

    ngo_ids = sorted(
        {
            str(claim_by_id[str(t["claim_id"])]["ngo_id"])
            for t in tasks
            if claim_by_id.get(str(t.get("claim_id")), {}).get("ngo_id")
        }
    )
    ngos = (
        client.table("ngos")
        .select("id,organization_name,address,city,phone,vehicle_available")
        .in_("id", ngo_ids)
        .execute()
        .data
        or []
    ) if ngo_ids else []
    ngo_by_id = {str(n["id"]): n for n in ngos}

    enriched = []
    for task in tasks:
        donation = donation_by_id.get(str(task.get("donation_id")), {})
        claim = claim_by_id.get(str(task.get("claim_id")), {})
        provider = provider_by_id.get(str(donation.get("provider_id")), {})
        ngo = ngo_by_id.get(str(claim.get("ngo_id")), {})
        enriched.append(
            {
                **task,
                "volunteer_transport_required": True,
                "transport_requirement": "Volunteer transport required",
                "donation": donation or None,
                "provider": provider or None,
                "ngo": ngo or None,
                "claim": claim or None,
            }
        )
    return enriched


@router.post("/{delivery_id}/accept")
def accept_delivery(
    delivery_id: str,
    profile: dict = Depends(require_role("volunteer")),
) -> dict:
    """A real volunteer accepts an open transport task.

    The volunteer_id is taken from the authenticated token, never from the body,
    so a volunteer can only take work as themselves. The task must still be
    unclaimed, which is what makes this a genuine hand-off rather than a
    fabricated assignment: if somebody else accepted first, this returns 409.

    A task is only acceptable while its underlying claim is LIVE
    (`pending`/`accepted`/`completed`). Discovery already filters on this, but
    discovery and acceptance are separate requests, so a volunteer who loaded a
    task a moment before the NGO cancelled or rejected the claim could otherwise
    accept it afterwards and be handed work for a withdrawn offer. The claim is
    therefore resolved from the database here, never from the request.
    """
    volunteer = first_row(profile.get("volunteers"))
    if not volunteer:
        raise HTTPException(status_code=404, detail="Volunteer profile not found.")
    client = get_supabase_client()

    existing = (
        client.table("deliveries")
        .select("id,claim_id,status,volunteer_id")
        .eq("id", delivery_id)
        .maybe_single()
        .execute()
    )
    if not getattr(existing, "data", None):
        raise HTTPException(status_code=404, detail="Delivery not found.")
    if existing.data.get("volunteer_id") is not None:
        raise HTTPException(
            status_code=409,
            detail="This transport task has already been accepted by another volunteer.",
        )
    original_status = existing.data.get("status")
    if original_status not in ("unassigned", "assigned"):
        raise HTTPException(
            status_code=409,
            detail=f"This task is not open for acceptance (status '{original_status}').",
        )

    _reject_if_claim_not_live(client, existing.data)

    # The assignment itself is still a single conditional UPDATE, so two
    # volunteers racing for the same task cannot both win: only the update that
    # observes volunteer_id IS NULL changes the row.
    updated = (
        client.table("deliveries")
        .update({"volunteer_id": volunteer["id"], "status": "assigned"})
        .eq("id", delivery_id)
        .is_("volunteer_id", None)
        .select()
        .execute()
    )
    if not updated.data:
        # Lost the race against a concurrent accept.
        raise HTTPException(
            status_code=409,
            detail="This transport task has already been accepted by another volunteer.",
        )

    # The claim lives in a different table, so its status cannot be part of that
    # single conditional UPDATE. Close the remaining window (claim cancelled
    # between the check above and the update) by re-reading it and undoing the
    # assignment if the claim went dead in the meantime. This is deliberately
    # small and needs no transaction: the undo is itself guarded on
    # volunteer_id = this volunteer, so it can only ever reverse THIS
    # assignment and can never disturb a volunteer who took the task
    # independently.
    if not _claim_is_live(client, existing.data.get("claim_id")):
        client.table("deliveries").update(
            {"volunteer_id": None, "status": original_status}
        ).eq("id", delivery_id).eq("volunteer_id", volunteer["id"]).execute()
        raise HTTPException(
            status_code=409,
            detail=(
                "This transport task is no longer available: the NGO has "
                "cancelled or rejected the underlying claim. Nothing was changed."
            ),
        )
    return updated.data[0]


def _claim_is_live(client, claim_id) -> bool:
    """True only when the claim exists and is still a live claim.

    A claim that cannot be resolved is treated as NOT live, because accepting a
    task whose origin cannot be verified would risk handing a volunteer work for
    an offer that may already have been withdrawn.
    """
    if not claim_id:
        return False
    claim = (
        client.table("claims")
        .select("id,status")
        .eq("id", str(claim_id))
        .maybe_single()
        .execute()
    )
    if not getattr(claim, "data", None):
        return False
    return is_live_claim_status(claim.data.get("status"))


def _reject_if_claim_not_live(client, delivery: dict) -> None:
    """Raises 409 when a delivery's underlying claim is no longer live."""
    if _claim_is_live(client, delivery.get("claim_id")):
        return
    raise HTTPException(
        status_code=409,
        detail=(
            "This transport task is no longer available: the NGO has cancelled "
            "or rejected the underlying claim. Nothing was changed."
        ),
    )


@router.patch("/{delivery_id}/status")
def update_delivery(
    delivery_id: str,
    payload: DeliveryStatusUpdate,
    profile: dict = Depends(require_role("volunteer")),
) -> dict:
    volunteer = profile.get("volunteers")
    if not volunteer:
        raise HTTPException(status_code=404, detail="Volunteer profile not found.")
    volunteer_id = volunteer[0]["id"] if isinstance(volunteer, list) else volunteer["id"]
    client = get_supabase_client()
    existing = client.table("deliveries").select("id").eq("id", delivery_id).eq("volunteer_id", volunteer_id).maybe_single().execute()
    if existing is None:
        raise HTTPException(status_code=404, detail="Delivery not found.")
    values = payload.model_dump(exclude_none=True)
    response = client.table("deliveries").update(values).eq("id", delivery_id).eq("volunteer_id", volunteer_id).select().execute()
    if not response.data:
        raise HTTPException(status_code=404, detail="Delivery not found.")
    return response.data[0]
