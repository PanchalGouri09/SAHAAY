from fastapi import APIRouter, Depends, HTTPException, status

from app.dependencies import get_current_firebase_user, get_current_profile
from app.schemas.profile import ProfileCreate, ProfileUpdate
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
        client.table(table).update(role_payload.model_dump(exclude_none=True)).eq("id", role_id).execute()

    refreshed = client.table("users").select("*, providers(*), ngos(*), volunteers(*)").eq("id", profile["id"]).single().execute()
    return _with_profile(refreshed.data, refreshed.data)
