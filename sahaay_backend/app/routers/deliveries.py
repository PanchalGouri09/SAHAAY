import logging
from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException

from app.dependencies import get_current_firebase_user, require_role
from app.schemas.donation import DeliveryStatusUpdate
from app.services import notification_service
from app.services.volunteer_transport import first_row, is_live_claim_status
from app.services.profile_completion import require_verified_contacts
from app.supabase_client import get_supabase_client

router = APIRouter(prefix="/deliveries", tags=["deliveries"])
logger = logging.getLogger(__name__)


def _is_open_delivery_row(delivery: dict) -> bool:
    donation = delivery.get("donation")
    if not isinstance(donation, dict):
        return False
    if donation.get("status") in {"expired", "cancelled", "completed", "delivered"}:
        return False
    now = datetime.now(timezone.utc)
    for field in ("expiry_time", "pickup_deadline"):
        value = donation.get(field)
        if not value:
            return False
        try:
            deadline = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
        except ValueError:
            return False
        if deadline.tzinfo is None:
            deadline = deadline.replace(tzinfo=timezone.utc)
        if deadline <= now:
            return False
    return True


def _enrich_delivery_rows(client, deliveries: list[dict]) -> list[dict]:
    if not deliveries:
        return []
    claim_ids = sorted({str(row["claim_id"]) for row in deliveries if row.get("claim_id")})
    claims = (
        client.table("claims")
        .select("id,ngo_id,requested_quantity,status")
        .in_("id", claim_ids)
        .execute()
        .data
        or []
    ) if claim_ids else []
    claim_by_id = {str(row["id"]): row for row in claims}
    donation_ids = sorted({
        str(row["donation_id"]) for row in deliveries if row.get("donation_id")
    })
    donations = (
        client.table("donations")
        .select("*")
        .in_("id", donation_ids)
        .execute()
        .data
        or []
    ) if donation_ids else []
    donation_by_id = {str(row["id"]): row for row in donations}
    provider_ids = sorted({
        str(row["provider_id"])
        for row in donations
        if row.get("provider_id")
    })
    providers = (
        client.table("providers")
        .select("id,organization_name,address,city,phone,latitude,longitude")
        .in_("id", provider_ids)
        .execute()
        .data
        or []
    ) if provider_ids else []
    provider_by_id = {str(row["id"]): row for row in providers}
    ngo_ids = sorted({
        str(claim_by_id[str(row["claim_id"])]["ngo_id"])
        for row in deliveries
        if claim_by_id.get(str(row.get("claim_id")), {}).get("ngo_id")
    })
    ngos = (
        client.table("ngos")
        .select("id,organization_name,address,city,phone,latitude,longitude")
        .in_("id", ngo_ids)
        .execute()
        .data
        or []
    ) if ngo_ids else []
    ngo_by_id = {str(row["id"]): row for row in ngos}
    volunteer_ids = sorted({
        str(row["volunteer_id"])
        for row in deliveries
        if row.get("volunteer_id")
    })
    volunteer_by_id: dict[str, dict] = {}
    if volunteer_ids:
        volunteer_rows = (
            client.table("volunteers")
            .select("id,user_id")
            .in_("id", volunteer_ids)
            .execute()
            .data
            or []
        )
        user_ids = sorted({
            str(row["user_id"]) for row in volunteer_rows if row.get("user_id")
        })
        users = (
            client.table("users")
            .select("id,full_name,phone")
            .in_("id", user_ids)
            .execute()
            .data
            or []
        ) if user_ids else []
        user_by_id = {str(row["id"]): row for row in users}
        volunteer_by_id = {
            str(row["id"]): dict(user_by_id.get(str(row.get("user_id")), {}))
            for row in volunteer_rows
        }
    coordination_by_id: dict[str, dict] = {}
    if claim_ids:
        try:
            rows = (
                client.table("claim_transport_coordination")
                .select("*")
                .in_("claim_id", claim_ids)
                .execute()
                .data
                or []
            )
            coordination_by_id = {
                str(row["claim_id"]): row
                for row in rows
                if row.get("claim_id")
            }
        except Exception as exc:
            # Existing delivery details remain available if the additive
            # coordination migration has not been deployed yet.
            logger.info(
                "Transport coordination enrichment unavailable (%s)",
                type(exc).__name__,
            )
            coordination_by_id = {}

    return [
        {
            **delivery,
            "donation": donation_by_id.get(str(delivery.get("donation_id"))),
            "provider": provider_by_id.get(
                str(
                    donation_by_id.get(str(delivery.get("donation_id")), {}).get(
                        "provider_id"
                    )
                )
            ),
            "ngo": ngo_by_id.get(
                str(
                    claim_by_id.get(str(delivery.get("claim_id")), {}).get("ngo_id")
                )
            ),
            "claim": claim_by_id.get(str(delivery.get("claim_id"))),
            "volunteer": volunteer_by_id.get(str(delivery.get("volunteer_id"))),
            "transport_coordination": coordination_by_id.get(
                str(delivery.get("claim_id"))
            ),
        }
        for delivery in deliveries
    ]


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
    client = get_supabase_client()
    response = client.table("deliveries").select("*").eq("volunteer_id", volunteer_id).order("created_at", desc=True).execute()
    return _enrich_delivery_rows(client, response.data or [])


@router.get("/transport-required")
def list_transport_required(
    profile: dict = Depends(require_role("volunteer")),
) -> list[dict]:
    """Open volunteer transport tasks that nobody has accepted yet.

    These are donations where the provider and the claiming NGO both explicitly
    declined transport, so the persisted coordination state is
    `searching_for_volunteers`, `deliveries.status = 'unassigned'`, and
    `volunteer_id IS NULL`.

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

    coordination_available = True
    try:
        coordination_rows = (
            client.table("claim_transport_coordination")
            .select("*")
            .in_("claim_id", list(claim_by_id))
            .execute()
            .data
            or []
        )
        coordination_by_id = {
            str(row["claim_id"]): row
            for row in coordination_rows
            if row.get("claim_id")
        }
    except Exception as exc:
        logger.info(
            "Transport coordination task filter unavailable (%s)",
            type(exc).__name__,
        )
        coordination_available = False
        coordination_by_id = {}
    if coordination_available:
        tasks = [
            task
            for task in tasks
            if coordination_by_id.get(str(task.get("claim_id")), {}).get("status")
            == "searching_for_volunteers"
        ]
    if not tasks:
        return []

    enriched = _enrich_delivery_rows(client, tasks)
    enriched = [task for task in enriched if _is_open_delivery_row(task)]
    return [
        {
            **task,
            "volunteer_transport_required": True,
            "transport_requirement": "Volunteer transport required",
            "transport_coordination": coordination_by_id.get(
                str(task.get("claim_id"))
            ),
        }
        for task in enriched
    ]


@router.post("/{delivery_id}/accept")
def accept_delivery(
    delivery_id: str,
    profile: dict = Depends(require_role("volunteer")),
    firebase_user: dict = Depends(get_current_firebase_user),
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
    require_verified_contacts(
        profile, firebase_user, action="accepting a volunteer transport task"
    )
    volunteer = first_row(profile.get("volunteers"))
    if not volunteer:
        raise HTTPException(status_code=404, detail="Volunteer profile not found.")
    client = get_supabase_client()

    existing = (
        client.table("deliveries")
        .select("id,donation_id,claim_id,status,volunteer_id")
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
    donation = (
        client.table("donations")
        .select("id,status,expiry_time,pickup_deadline")
        .eq("id", str(existing.data.get("donation_id")))
        .maybe_single()
        .execute()
    )
    if not getattr(donation, "data", None) or not _is_open_delivery_row(
        {"donation": donation.data}
    ):
        raise HTTPException(
            status_code=409,
            detail="This delivery is expired or no longer open for acceptance.",
        )

    coordination_schema_available = True
    try:
        coordination_response = (
            client.table("claim_transport_coordination")
            .select("id,status")
            .eq("claim_id", str(existing.data.get("claim_id")))
            .maybe_single()
            .execute()
        )
    except Exception as exc:
        # Compatibility with the existing delivery workflow before the
        # additive coordination migration is applied.
        logger.info(
            "Transport coordination migration unavailable for assignment (%s)",
            type(exc).__name__,
        )
        coordination_schema_available = False

    if coordination_schema_available:
        coordination = getattr(coordination_response, "data", None)
        if not coordination or coordination.get("status") != "searching_for_volunteers":
            raise HTTPException(
                status_code=409,
                detail="This transport task is no longer searching for volunteers.",
            )
        try:
            result = client.rpc(
                "confirm_claim_volunteer_assignment",
                {
                    "p_delivery_id": str(delivery_id),
                    "p_volunteer_id": str(volunteer["id"]),
                },
            ).execute()
        except Exception as exc:
            logger.warning(
                "Atomic volunteer assignment failed (%s)", type(exc).__name__
            )
            message = str(exc).lower()
            if "already been accepted" in message or "search is not open" in message:
                raise HTTPException(
                    status_code=409,
                    detail="This transport task has already been accepted or closed.",
                ) from exc
            raise HTTPException(
                status_code=503,
                detail="Could not assign this transport task. Please retry.",
            ) from exc
        result_data = getattr(result, "data", None)
        if isinstance(result_data, list) and len(result_data) == 1:
            result_data = result_data[0]
        updated_data = result_data.get("delivery") if isinstance(result_data, dict) else None
        if not isinstance(updated_data, dict):
            raise HTTPException(
                status_code=502,
                detail="The database returned an invalid volunteer assignment.",
            )
    else:
        # Legacy deployments retain the original single conditional UPDATE.
        updated = (
            client.table("deliveries")
            .update({"volunteer_id": volunteer["id"], "status": "assigned"})
            .eq("id", delivery_id)
            .is_("volunteer_id", None)
            .select()
            .execute()
        )
        if not updated.data:
            raise HTTPException(
                status_code=409,
                detail="This transport task has already been accepted by another volunteer.",
            )
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
        updated_data = updated.data[0]

    # The assignment really happened: tell the claiming NGO and the provider.
    # Recipients are resolved from the delivery's own relationships, never from
    # the request, and the push is best-effort.
    notification_service.volunteer_transport_assigned(
        client, delivery=updated_data, claim=None, donation=None
    )
    return updated_data


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
    existing = (
        client.table("deliveries")
        .select("id,claim_id,donation_id,status")
        .eq("id", delivery_id)
        .eq("volunteer_id", volunteer_id)
        .maybe_single()
        .execute()
    )
    existing_row = getattr(existing, "data", None)
    if not existing_row:
        raise HTTPException(status_code=404, detail="Delivery not found.")
    values = payload.model_dump(exclude_none=True)
    current_status = str(existing_row.get("status") or "")
    requested_status = values.get("status")
    if requested_status == current_status:
        return existing_row
    if current_status in {"delivered", "failed", "cancelled"}:
        raise HTTPException(
            status_code=409,
            detail="This delivery is already closed and cannot be reopened.",
        )
    progress_order = {
        "assigned": 0,
        "accepted": 0,
        "picked_up": 1,
        "in_transit": 2,
        "delivered": 3,
    }
    if (
        requested_status in progress_order
        and current_status in progress_order
        and progress_order[requested_status] < progress_order[current_status]
    ):
        raise HTTPException(
            status_code=409,
            detail="Delivery progress cannot move backwards.",
        )
    donation = (
        client.table("donations")
        .select("id,status,expiry_time,pickup_deadline")
        .eq("id", str(existing_row.get("donation_id")))
        .maybe_single()
        .execute()
    )
    if not getattr(donation, "data", None) or not _is_open_delivery_row(
        {"donation": donation.data}
    ):
        raise HTTPException(
            status_code=409,
            detail="This delivery is expired or no longer open for updates.",
        )
    if values.get("status") == "delivered":
        claim = (
            client.table("claims")
            .select("id,status,handover_verified_at")
            .eq("id", str(existing_row.get("claim_id")))
            .maybe_single()
            .execute()
        )
        claim_row = getattr(claim, "data", None)
        if not claim_row or not claim_row.get("handover_verified_at"):
            raise HTTPException(
                status_code=409,
                detail="The provider-generated handover code must be verified before delivery completion.",
            )
    response = (
        client.table("deliveries")
        .update(values)
        .eq("id", delivery_id)
        .eq("volunteer_id", volunteer_id)
        .eq("status", current_status)
        .select()
        .execute()
    )
    if not response.data:
        latest = (
            client.table("deliveries")
            .select("id,claim_id,donation_id,status")
            .eq("id", delivery_id)
            .eq("volunteer_id", volunteer_id)
            .maybe_single()
            .execute()
        )
        latest_row = getattr(latest, "data", None)
        if latest_row and latest_row.get("status") == requested_status:
            return latest_row
        if latest_row:
            raise HTTPException(
                status_code=409,
                detail="Delivery progress changed. Refresh before trying again.",
            )
        raise HTTPException(status_code=404, detail="Delivery not found.")
    delivery = response.data[0]
    if values.get("status") == "delivered":
        # The database trigger has completed the donation; generate its
        # acknowledgment receipt best-effort (never breaks this update).
        _generate_completion_receipt(client, delivery.get("donation_id"))
    # Tell the parties whose delivery actually moved. Recipients come from the
    # delivery's own relationships (claiming NGO, provider); best-effort.
    notification_service.delivery_status_changed(
        client,
        delivery=delivery,
        new_status=values.get("status"),
        failure_reason=values.get("failure_reason"),
    )
    return delivery


def _generate_completion_receipt(client, donation_id) -> None:
    """Best-effort acknowledgment generation after a delivery completes.

    Runs only after the database trigger has flipped the donation to
    'completed'. Imports are lazy so the router import graph stays acyclic, and
    the acknowledgment service itself never raises, so a broken PDF pipeline
    can never fail the delivery update that completed the donation.
    """
    if not donation_id:
        return
    from app.services import acknowledgment, notification_service

    outcome = acknowledgment.auto_generate_acknowledgment(client, donation_id)
    if outcome and outcome.get("persisted"):
        notification_service.acknowledgment_ready(
            client, donation=outcome.get("donation")
        )
