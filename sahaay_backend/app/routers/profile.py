from fastapi import APIRouter, Depends, HTTPException, status

from app.dependencies import get_current_firebase_user, get_current_profile, require_role
from app.schemas.profile import ProfileCreate, ProfileUpdate, VehicleAvailabilityUpdate
from app.supabase_client import get_supabase_client

router = APIRouter(prefix="/profile", tags=["profile"])


def _with_profile(user: dict, profile: dict | None) -> dict:
    if not profile:
        return user
    role = profile["role"]
    return {**profile, "profile": profile.get(f"{role}s") or profile.get(role)}


@router.get("")
def get_profile(profile: dict = Depends(get_current_profile)) -> dict:
    return _with_profile(profile, profile)


@router.post("", status_code=status.HTTP_201_CREATED)
def create_profile(
    payload: ProfileCreate,
    current_user: dict = Depends(get_current_firebase_user),
) -> dict:
    firebase_uid = current_user["uid"]
    client = get_supabase_client()
    existing = client.table("users").select("id").eq("firebase_uid", firebase_uid).maybe_single().execute()
    if existing is not None:
        raise HTTPException(status_code=409, detail="A SAHAAY profile already exists.")

    if payload.role == "provider" and payload.provider is None:
        raise HTTPException(status_code=422, detail="Provider profile data is required.")
    if payload.role == "ngo" and payload.ngo is None:
        raise HTTPException(status_code=422, detail="NGO profile data is required.")
    if payload.role == "volunteer" and payload.volunteer is None:
        raise HTTPException(status_code=422, detail="Volunteer profile data is required.")
    if payload.role == "admin":
        raise HTTPException(status_code=403, detail="Admin profiles are provisioned separately.")

    try:
        user_result = client.table("users").insert({
            "firebase_uid": firebase_uid,
            "full_name": payload.full_name,
            "email": payload.email,
            "phone": payload.phone,
            "role": payload.role,
        }).select().execute()
        user = user_result.data[0]
        user_id = user["id"]
        profile_payload = {"user_id": user_id}
        if payload.provider:
            profile_payload.update(payload.provider.model_dump())
            table = "providers"
        elif payload.ngo:
            profile_payload.update(payload.ngo.model_dump())
            table = "ngos"
        else:
            profile_payload.update(payload.volunteer.model_dump())
            table = "volunteers"
        role_result = client.table(table).insert(profile_payload).select().execute()
        return {**user, "profile": role_result.data[0]}
    except Exception as exc:
        if "user_id" in locals():
            client.table("users").delete().eq("id", user_id).execute()
        raise HTTPException(status_code=500, detail="Unable to create the SAHAAY profile.") from exc


@router.patch("")
def update_profile(
    payload: ProfileUpdate,
    profile: dict = Depends(get_current_profile),
) -> dict:
    client = get_supabase_client()
    user_values = payload.model_dump(exclude_none=True, exclude={"provider", "ngo", "volunteer"})
    if user_values:
        client.table("users").update(user_values).eq("id", profile["id"]).execute()

    role = profile["role"]
    role_payload = getattr(payload, role, None)
    if role_payload is not None and role != "admin":
        table = f"{role}s"
        role_row = profile.get(table)
        if not role_row:
            raise HTTPException(status_code=404, detail="Role profile not found.")
        role_id = role_row[0]["id"] if isinstance(role_row, list) else role_row["id"]
        # Only fields the client actually sent are written, so an omitted
        # column keeps its stored value. `exclude_unset` (not
        # `exclude_none`) is required here: otherwise a nullable column such
        # as ngos.vehicle_available could never be set back to null, because
        # "not sent" and "explicitly null" would become indistinguishable.
        updates = role_payload.model_dump(exclude_unset=True)
        if updates:
            client.table(table).update(updates).eq("id", role_id).execute()

    refreshed = client.table("users").select("*, providers(*), ngos(*), volunteers(*)").eq("id", profile["id"]).single().execute()
    return _with_profile(refreshed.data, refreshed.data)


@router.patch("/provider/vehicle-availability")
def update_provider_vehicle_availability(
    payload: VehicleAvailabilityUpdate,
    profile: dict = Depends(require_role("provider")),
) -> dict:
    """Sets or clears the authenticated provider's pickup-vehicle availability.

    Three-state, matching public.providers.vehicle_available:
      true  -> "Yes, I have a vehicle"
      false -> "No, I don't"
      null  -> clears the answer back to "not answered"

    The provider row is resolved from the verified Firebase token via
    `require_role("provider")` -> users.id -> providers.user_id. The request body
    carries no identifier at all, so a client cannot address another provider's
    record. An NGO calling this path is rejected by `require_role` with 403, so a
    provider-owned field can never be written by the other role.
    """
    client = get_supabase_client()
    provider_rows = profile.get("providers") or []
    provider_row = provider_rows[0] if isinstance(provider_rows, list) and provider_rows else provider_rows
    if not provider_row:
        raise HTTPException(status_code=404, detail="Provider profile not found.")

    updated = (
        client.table("providers")
        .update({"vehicle_available": payload.vehicle_available})
        .eq("id", provider_row["id"])
        .select()
        .execute()
    )
    if not updated.data:
        raise HTTPException(status_code=404, detail="Provider profile not found.")

    return {
        "status": "ok",
        "provider_id": str(updated.data[0]["id"]),
        "organization_name": updated.data[0].get("organization_name"),
        "vehicle_available": updated.data[0].get("vehicle_available"),
    }


@router.patch("/ngo/vehicle-availability")
def update_ngo_vehicle_availability(
    payload: VehicleAvailabilityUpdate,
    profile: dict = Depends(require_role("ngo")),
) -> dict:
    """Sets or clears the authenticated NGO's pickup-vehicle availability.

    Three-state, matching public.ngos.vehicle_available:
      true  -> "Yes, I have a vehicle"
      false -> "No, I don't"
      null  -> clears the answer back to "not answered"

    The NGO row is resolved from the verified Firebase token via
    `require_role("ngo")` -> users.id -> ngos.user_id. The request body carries
    no identifier at all, so a client cannot address another NGO's record, and a
    provider calling this path is rejected by `require_role` with 403.
    """
    client = get_supabase_client()
    ngo_rows = profile.get("ngos") or []
    ngo_row = ngo_rows[0] if isinstance(ngo_rows, list) and ngo_rows else ngo_rows
    if not ngo_row:
        raise HTTPException(status_code=404, detail="NGO profile not found.")

    updated = (
        client.table("ngos")
        .update({"vehicle_available": payload.vehicle_available})
        .eq("id", ngo_row["id"])
        .select()
        .execute()
    )
    if not updated.data:
        raise HTTPException(status_code=404, detail="NGO profile not found.")

    return {
        "status": "ok",
        "ngo_id": str(updated.data[0]["id"]),
        "organization_name": updated.data[0].get("organization_name"),
        "vehicle_available": updated.data[0].get("vehicle_available"),
    }
