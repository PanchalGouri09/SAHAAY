"""Volunteer hand-off for donations that nobody in the loop can transport.

Trigger
-------
A claim is the first moment the (provider, NGO) pair is concrete, so it is where
pairwise vehicle compatibility becomes an operational fact. When the provider and
the claiming NGO have *both* explicitly reported no vehicle, the pickup can only
happen if a volunteer transports the food, and this module records that.

What this module does NOT do
----------------------------
It never fabricates a volunteer, never invents a driver, and never auto-assigns
the "nearest" volunteer. `volunteers` rows carry real availability_status and
current_latitude/longitude, but they are frequently NULL and often stale, so
auto-assignment on that basis would create a fake assignment that a human never
accepted. Instead the work is published as a real, claimable task:

    donations.volunteer_transport_required = true   (donor/NGO/admin visibility)
    deliveries row with status='unassigned'          (volunteer discovery)

    The volunteer_id stays NULL until a real authenticated volunteer accepts through
    POST /api/v1/deliveries/{id}/accept. deliveries.volunteer_id is nullable and its
    foreign key is ON DELETE SET NULL, so if that volunteer is later removed the task
    returns to the unassigned pool rather than becoming a dead assignment.

Recomputation, not a one-way write
----------------------------------
`donations.volunteer_transport_required` is *derived* state: it is true exactly
when at least one LIVE claim on the donation pairs a provider and an NGO that
have both explicitly answered "no vehicle". It is therefore recomputed from the
current claims by `recompute_volunteer_transport_required` rather than being
set once and never revisited, so it cannot go stale when a claim is cancelled,
rejected or completed.

Recomputing (rather than clearing on cancellation) is what makes it correct when
a donation has several claims at once:

    Claim A  provider=false ngo=false  status=cancelled   -> ignored
    Claim B  provider=false ngo=false  status=pending     -> requirement holds

Clearing on A's cancellation would be wrong, because B still needs a volunteer.
The function is a pure function of current database state, so calling it
repeatedly is idempotent and it is safe to call from any lifecycle transition
without a scheduler.
"""

from __future__ import annotations

from typing import Optional

from app.services.vehicle_logistics import (
    compatibility_detail,
    compatibility_label,
    requires_volunteer_transport,
    vehicle_compatibility,
)

#: Claim statuses that still represent a live offer for this donation.
#:
#: `pending`, `accepted` and `completed` all still represent real work that
#: somebody is expected to move, so a false/false pair among them genuinely
#: needs a volunteer. `cancelled` and `rejected` mean the offer was withdrawn,
#: so those claims must never drive the flag or volunteer task discovery.
#:
#: This mirrors the existing claim lifecycle (see app/schemas/donation.py and
#: the claims_status_check constraint) and introduces no new status.
LIVE_CLAIM_STATUSES: tuple[str, ...] = ("pending", "accepted", "completed")

#: Claim statuses that must never surface a discoverable volunteer task.
DEAD_CLAIM_STATUSES: tuple[str, ...] = ("cancelled", "rejected")


class VolunteerTransportTaskError(RuntimeError):
    """A volunteer transport task could not be published for a genuine need.

    Raised instead of leaving a donation flagged with no way for a volunteer to
    find the work. Callers surface this as a failed request rather than
    reporting a requirement that cannot actually be acted on.
    """


def is_live_claim_status(status: Optional[str]) -> bool:
    """True when a claim status still represents live work for this donation."""
    return status in LIVE_CLAIM_STATUSES



def first_row(value) -> dict:
    """Supabase role joins come back as a one-element list; accept both shapes."""
    if isinstance(value, list):
        return value[0] if value and isinstance(value[0], dict) else {}
    return value if isinstance(value, dict) else {}


def provider_vehicle_for_donation(client, donation: dict) -> Optional[bool]:
    """Reads the real providers.vehicle_available for a donation.

    Returns None when the row or column is missing, which the compatibility layer
    correctly treats as "not answered" rather than "no vehicle".
    """
    provider_id = donation.get("provider_id")
    if not provider_id:
        return None
    row = (
        client.table("providers")
        .select("vehicle_available")
        .eq("id", str(provider_id))
        .maybe_single()
        .execute()
    )
    data = row.data if getattr(row, "data", None) else None
    if not data:
        return None
    return data.get("vehicle_available")


def ngo_vehicle_for_claim(client, claim: dict) -> Optional[bool]:
    """Reads the real ngos.vehicle_available for a claim's NGO.

    Returns None when the row is missing or unanswered, which the compatibility
    layer treats as "not answered" rather than "no vehicle".
    """
    ngo_id = claim.get("ngo_id")
    if not ngo_id:
        return None
    row = (
        client.table("ngos")
        .select("vehicle_available")
        .eq("id", str(ngo_id))
        .maybe_single()
        .execute()
    )
    data = row.data if getattr(row, "data", None) else None
    if not data:
        return None
    return data.get("vehicle_available")


def recompute_volunteer_transport_required(client, donation_id: str) -> bool:
    """Recalculates `donations.volunteer_transport_required` from live claims.

    The rule, applied as a single aggregate over ALL current live claims:

        required = any(
            live claim AND provider.vehicle_available IS FALSE
                     AND ngo.vehicle_available IS FALSE
        )

    Why an aggregate and not "clear on cancel": a donation can hold several
    claims at once. Clearing the flag because one claim was cancelled would hide
    a genuine volunteer need belonging to another still-live claim. Recomputing
    from scratch always describes the real current state.

    NULL is never coerced to false: if the provider or the NGO has not answered,
    that pairing is `unknown` and contributes nothing, so a missing answer can
    never manufacture a volunteer requirement.

    This is a pure function of current database state plus the id passed in, so
    it is idempotent: repeated calls with no intervening change always produce
    the same result, which is what makes it safe to call from every lifecycle
    transition instead of from a scheduler.

    Returns the resulting boolean, and the value is also persisted so readers
    such as donor/NGO/admin listings see the corrected state.
    """
    donation_id = str(donation_id)
    donation = (
        client.table("donations")
        .select("id,provider_id")
        .eq("id", donation_id)
        .maybe_single()
        .execute()
    )
    if not getattr(donation, "data", None):
        # Nothing to flag. Do not invent a row.
        return False

    provider_vehicle = provider_vehicle_for_donation(client, donation.data)

    claims = (
        client.table("claims")
        .select("id,ngo_id,status")
        .eq("donation_id", donation_id)
        .in_("status", list(LIVE_CLAIM_STATUSES))
        .execute()
        .data
        or []
    )

    required = False
    for claim in claims:
        # Re-checked in Python as well as in SQL: the status filter is a query
        # optimisation, not the source of truth for what "live" means.
        if not is_live_claim_status(claim.get("status")):
            continue
        if requires_volunteer_transport(
            provider_vehicle, ngo_vehicle_for_claim(client, claim)
        ):
            required = True
            break

    client.table("donations").update({"volunteer_transport_required": required}).eq(
        "id", donation_id
    ).execute()
    return required


def publish_volunteer_transport_task(
    client,
    donation: dict,
    ngo: dict,
    claim_id: str,
) -> dict:
    """Evaluates a claim's transport compatibility and, when a volunteer is
    genuinely required, publishes a claimable volunteer task.

    Returns a summary dict describing what was found, so the caller can surface
    the outcome to the NGO without re-deriving the logic:

        {
          "vehicle_compatibility": str,
          "vehicle_compatibility_label": str,
          "vehicle_compatibility_detail": str,
          "volunteer_transport_required": bool,
          "delivery_id": str | None,   # existing or newly created task
          "delivery_created": bool,
        }

    When no volunteer is required this is a no-op apart from the returned
    summary, so it is always safe to call on claim creation.
    """
    provider_vehicle = provider_vehicle_for_donation(client, donation)
    ngo_vehicle = ngo.get("vehicle_available")
    compatibility = vehicle_compatibility(provider_vehicle, ngo_vehicle)
    needed = requires_volunteer_transport(provider_vehicle, ngo_vehicle)

    summary = {
        "vehicle_compatibility": compatibility,
        "vehicle_compatibility_label": compatibility_label(compatibility),
        "vehicle_compatibility_detail": compatibility_detail(compatibility),
        "volunteer_transport_required": needed,
        "delivery_id": None,
        "delivery_created": False,
    }
    if not needed:
        # The flag is left exactly as it is, then reconciled by
        # recompute_volunteer_transport_required from every live claim. Un-flagging
        # here on the strength of this one claim would be wrong, because another
        # claim on the same donation may still require a volunteer.
        return summary

    # Validate BEFORE writing anything. Both columns are NOT NULL and neither
    # address may be invented, so an un-describable task must never reach the
    # flag-setting step and leave a requirement nobody can act on.
    pickup_address = donation.get("pickup_address")
    delivery_address = ngo.get("address")
    if not pickup_address or not delivery_address:
        raise VolunteerTransportTaskError(
            "Volunteer transport is required for this claim, but the task cannot "
            "be described because the pickup address or the NGO address is "
            "missing. Both are required to publish a real transport task."
        )

    # deliveries has a UNIQUE index on donation_id, so a second task for the same
    # donation can only ever be a REUSE of the existing row.
    existing = (
        client.table("deliveries")
        .select("id,claim_id,status,volunteer_id,delivery_address")
        .eq("donation_id", str(donation["id"]))
        .maybe_single()
        .execute()
    )
    if getattr(existing, "data", None):
        summary["delivery_id"] = str(existing.data["id"])
        summary["delivery_reused"] = True
        _rebind_task_to_active_claim(client, existing.data, str(claim_id), delivery_address)
        client.table("donations").update({"volunteer_transport_required": True}).eq(
            "id", str(donation["id"])
        ).execute()
        return summary

    # The flag is only set once a task genuinely exists to back it up, so the
    # donation can never claim a requirement that no volunteer is able to find.
    created = (
        client.table("deliveries")
        .insert(
            {
                "donation_id": str(donation["id"]),
                "claim_id": str(claim_id),
                # NULL until a real volunteer accepts. This is a genuine open
                # task, not an assignment.
                "volunteer_id": None,
                "pickup_address": pickup_address,
                "delivery_address": delivery_address,
                "pickup_time": donation.get("pickup_deadline"),
                "status": "unassigned",
            }
        )
        .select()
        .execute()
    )
    created_rows = getattr(created, "data", None)
    if not created_rows:
        # An insert that returns no row did not create a task. Reporting success
        # here would advertise a requirement that has no task behind it.
        raise VolunteerTransportTaskError(
            "Volunteer transport is required for this claim, but the transport "
            "task could not be created. The donation was not flagged, because a "
            "volunteer would not be able to find the work."
        )

    client.table("donations").update({"volunteer_transport_required": True}).eq(
        "id", str(donation["id"])
    ).execute()
    summary["delivery_id"] = str(created_rows[0]["id"])
    summary["delivery_created"] = True
    return summary


def _rebind_task_to_active_claim(
    client,
    existing: dict,
    claim_id: str,
    delivery_address: str,
) -> None:
    """Points a reused task row at the claim that is actually live right now.

    A donation can only ever have one delivery row (UNIQUE on donation_id), so a
    new active claim that also needs a volunteer must take that row over. Without
    this, the reused row would keep pointing at an earlier CANCELLED or REJECTED
    claim, and would advertise that withdrawn NGO as the destination.

    Only fields that belong to the claim are rebound, and only when the row is
    still genuinely open:
      * `claim_id` always moves to the new live claim, so discovery resolves the
        destination from the authoritative claim.
      * `delivery_address` is refreshed, because the destination NGO changed.
      * A row that a real volunteer has already taken (`volunteer_id` set) or
        that has already progressed past `unassigned` is left completely alone:
        it is real work in progress and must not be silently reassigned.
    """
    if str(existing.get("claim_id")) == str(claim_id):
        return
    if existing.get("volunteer_id") is not None or existing.get("status") != "unassigned":
        # Somebody is already on it. Never overwrite a real volunteer's task.
        return

    client.table("deliveries").update(
        {
            "claim_id": str(claim_id),
            "delivery_address": delivery_address,
        }
    ).eq("id", str(existing["id"])).eq("status", "unassigned").is_("volunteer_id", None).execute()
