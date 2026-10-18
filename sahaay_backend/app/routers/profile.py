import logging
from uuid import uuid4

from fastapi import (
    APIRouter,
    BackgroundTasks,
    Depends,
    File,
    HTTPException,
    UploadFile,
    status,
)

from app.config import get_settings
from app.dependencies import get_current_firebase_user, get_current_profile, require_role
from app.firebase_auth import firebase_user_exists
from app.routers.donations import (
    _EXTENSION_MIME,
    _IMAGE_EXTENSIONS,
    _ensure_storage_bucket,
    _extension_of_filename,
    _sniff_image_kind,
)
from app.schemas.profile import (
    LeaderboardVisibilityUpdate,
    ProfileCreate,
    ProfileUpdate,
    VehicleAvailabilityUpdate,
)
from app.supabase_client import get_supabase_client
from app.services.profile_completion import (
    contact_verification_state,
    profile_completion_report,
)
from app.services import notification_service
from app.services.phone_number import normalize_indian_mobile_number

router = APIRouter(prefix="/profile", tags=["profile"])
logger = logging.getLogger("sahaay.profile")


def _refresh_open_donation_matches() -> None:
    """Immediately refresh all open-donation rankings after an NGO profile save."""
    try:
        from app.services.ai_client import get_ai_client
        from app.services.donation_offers import match_unranked_donations

        result = match_unranked_donations(
            get_supabase_client(), get_ai_client(), force_retry=True
        )
        logger.info(
            "Post-profile NGO matching refresh: attempted=%s offered=%s",
            result.get("attempted", 0),
            result.get("offered", 0),
        )
    except Exception:  # noqa: BLE001
        logger.exception("Post-profile NGO matching refresh failed.")


def _single_or_none(result) -> dict | None:
    """Normalises a PostgREST ``maybe_single()`` result to an optional row.

    ``postgrest-py`` 2.x returns ``None`` when zero rows match (verified against
    the pinned 2.31.0). Older client versions instead handed back a response
    object whose ``.data`` was ``None`` or ``[]``. Treating every one of those
    shapes as "no row" keeps the duplicate checks below correct regardless of
    the installed client, and avoids turning a legitimate first-ever
    registration into a false "already exists" conflict.
    """
    if result is None:
        return None
    data = getattr(result, "data", None)
    if not data:
        return None
    if isinstance(data, list):
        return data[0] if data else None
    return data


def _with_profile(user: dict, profile: dict | None) -> dict:
    profile = profile or user
    if not profile:
        return user
    role = profile["role"]
    role_profile = profile.get(f"{role}s") or profile.get(role)
    result = {**profile, "profile": role_profile}
    result["profile_completion"] = profile_completion_report(
        {**profile, role: role_profile}
    )
    return result


@router.get("")
def get_profile(profile: dict = Depends(get_current_profile)) -> dict:
    return _with_profile(profile, profile)


@router.get("/contact-verification")
def get_contact_verification(
    profile: dict = Depends(get_current_profile),
    firebase_user: dict = Depends(get_current_firebase_user),
) -> dict:
    """Return contact status derived from the authenticated Firebase token."""
    return contact_verification_state(profile, firebase_user)


@router.post("", status_code=status.HTTP_201_CREATED)
def create_profile(
    payload: ProfileCreate,
    background_tasks: BackgroundTasks,
    current_user: dict = Depends(get_current_firebase_user),
) -> dict:
    firebase_uid = current_user["uid"]
    client = get_supabase_client()
    existing = _single_or_none(
        client.table("users").select("id").eq("firebase_uid", firebase_uid).maybe_single().execute()
    )
    if existing is not None:
        raise HTTPException(status_code=409, detail="A SAHAAY profile already exists.")

    # A different Firebase identity must never claim an email that already
    # belongs to another SAHAAY account: that would either duplicate the person
    # or silently reassign a legacy account. The UNIQUE(email) constraint is the
    # last line of defence; this pre-check is what turns the common case into a
    # clear conflict instead of a 500.
    if payload.email:
        email_owner = _single_or_none(
            client.table("users").select("id").eq("email", payload.email).maybe_single().execute()
        )
        if email_owner is not None:
            raise HTTPException(
                status_code=409,
                detail="This email is already associated with another SAHAAY account.",
            )

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
        role_row = role_result.data[0]
        if payload.phone:
            notification_service.contact_phone_updated(
                client,
                user_id=str(user_id),
                previous_phone=None,
            )
        response = {**user, "profile": role_row}
        response["profile_completion"] = profile_completion_report(
            {**user, payload.role: role_row}
        )
        if payload.role == "ngo":
            background_tasks.add_task(_refresh_open_donation_matches)
        return response
    except Exception as exc:
        # Roll the half-written account back so a failed registration never
        # leaves an orphaned users row behind. A cleanup failure must not mask
        # the original error, so it is logged and swallowed.
        if "user_id" in locals():
            try:
                client.table("users").delete().eq("id", user_id).execute()
            except Exception:  # noqa: BLE001
                logger.exception(
                    "Failed to roll back users row %s after a profile-create failure.",
                    user_id,
                )
        message = str(exc).lower()
        if "23505" in message or "duplicate key" in message or "unique" in message:
            raise HTTPException(
                status_code=409,
                detail="This email is already associated with another SAHAAY account.",
            ) from exc
        # Log the real cause (role + traceback) before collapsing it to a
        # generic 500. Without this the underlying PostgREST/schema error was
        # invisible in the server logs, which is what made the original failure
        # so hard to diagnose.
        logger.exception("create_profile failed for role=%s", payload.role)
        raise HTTPException(status_code=500, detail="Unable to create the SAHAAY profile.") from exc


@router.post("/adopt")
def adopt_profile(current_user: dict = Depends(get_current_firebase_user)) -> dict:
    """Restores a SAHAAY profile to a (re-)authenticated Firebase identity.

    The situation this repairs: the Firebase Authentication user was deleted
    (e.g. during test cleanup) but its SAHAAY `users` row - and any linked
    role, donation, claim or notification records - remained. Signing in again
    with a NEW Firebase UID makes GET /profile 404 by UID, so the client routes
    the person into first-time enrollment, and the eventual POST /profile is
    rejected with "email already associated with another SAHAAY account": a
    real account they cannot reach.

    Resolution is deliberately narrow and safe:
      * a row for the current UID always wins (idempotent no-op),
      * otherwise the *verified* token email is matched against `users.email`,
      * a match is re-linked only when its old Firebase UID is genuinely gone
        (`firebase_user_exists` is False), so a live account can never be
        taken over by a different identity,
      * nothing is deleted - only `users.firebase_uid` is re-pointed.

    Returns the same profile join as GET /profile, or 404 when there is
    genuinely no existing account (the caller should then enroll normally).
    """
    firebase_uid = current_user["uid"]
    client = get_supabase_client()
    select = "*, providers(*), ngos(*), volunteers(*)"

    current = _single_or_none(
        client.table("users").select(select).eq("firebase_uid", firebase_uid).maybe_single().execute()
    )
    if current is not None:
        return _with_profile(current, current)

    email = (current_user.get("email") or "").strip()
    if not email or not bool(current_user.get("email_verified")):
        raise HTTPException(
            status_code=404,
            detail="No existing SAHAAY profile to restore for this account.",
        )

    candidate = _single_or_none(
        client.table("users").select(select).eq("email", email).maybe_single().execute()
    )
    if candidate is None:
        raise HTTPException(
            status_code=404,
            detail="No existing SAHAAY profile to restore for this account.",
        )
    if candidate["firebase_uid"] == firebase_uid:
        return _with_profile(candidate, candidate)

    if firebase_user_exists(candidate["firebase_uid"]):
        raise HTTPException(
            status_code=409,
            detail="This email is already linked to an active SAHAAY account.",
        )

    # An UPDATE builder exposes `.select()` but not `.maybe_single()`; the
    # updated row comes back as a one-element `.data` list, normalised here.
    restored = _single_or_none(
        client.table("users")
        .update({"firebase_uid": firebase_uid})
        .eq("id", candidate["id"])
        .select(select)
        .execute()
    )
    if restored is None:
        raise HTTPException(status_code=500, detail="Unable to restore the SAHAAY profile.")
    logger.info(
        "Re-linked orphaned SAHAAY profile users.id=%s to a new Firebase UID (role=%s).",
        candidate["id"],
        candidate["role"],
    )
    return _with_profile(restored, restored)


@router.patch("")
def update_profile(
    payload: ProfileUpdate,
    background_tasks: BackgroundTasks,
    profile: dict = Depends(get_current_profile),
    firebase_user: dict = Depends(get_current_firebase_user),
) -> dict:
    client = get_supabase_client()
    user_values = payload.model_dump(exclude_none=True, exclude={"provider", "ngo", "volunteer"})
    previous_phone = profile.get("phone")
    changed_phone = (
        "phone" in user_values
        and normalize_indian_mobile_number(previous_phone)
        != normalize_indian_mobile_number(user_values["phone"])
    )
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
        if (
            "phone" in updates
            and "phone" not in user_values
            and normalize_indian_mobile_number(role_row.get("phone"))
            != normalize_indian_mobile_number(updates["phone"])
        ):
            previous_phone = role_row.get("phone")
            changed_phone = True
        if updates:
            client.table(table).update(updates).eq("id", role_id).execute()

    refreshed = client.table("users").select("*, providers(*), ngos(*), volunteers(*)").eq("id", profile["id"]).single().execute()
    response = _with_profile(refreshed.data, refreshed.data)
    if changed_phone:
        notification_service.contact_phone_updated(
            client,
            user_id=str(profile["id"]),
            previous_phone=previous_phone,
        )
    if role == "ngo":
        response = _with_profile(refreshed.data, refreshed.data)
        background_tasks.add_task(_refresh_open_donation_matches)
    return response


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


@router.patch("/leaderboard-visibility")
def update_leaderboard_visibility(
    payload: LeaderboardVisibilityUpdate,
    profile: dict = Depends(get_current_profile),
) -> dict:
    """Persists the signed-in user's public-leaderboard visibility.

    Writes `users.leaderboard_public` on the row resolved from the verified
    Firebase token, so the request body carries no identifier and one account
    can never flip another's setting. The leaderboard itself only ever shows
    organizations whose owner opted in here.
    """
    client = get_supabase_client()
    updated = (
        client.table("users")
        .update({"leaderboard_public": payload.public})
        .eq("id", profile["id"])
        .select("id,leaderboard_public")
        .execute()
    )
    if not updated.data:
        raise HTTPException(status_code=404, detail="Profile not found.")
    return {
        "status": "ok",
        "leaderboard_public": bool(updated.data[0].get("leaderboard_public")),
    }


@router.post("/upload-photo")
def upload_profile_photo(
    file: UploadFile = File(...),
    profile: dict = Depends(get_current_profile),
) -> dict:
    """Stores the signed-in user's profile photo and persists its public URL.

    The target row is the caller's own `users` row (resolved from the verified
    Firebase token), so no request field can point at another account. Uses the
    same byte-level image validation as food/handover photos.
    """
    data = file.file.read()
    max_bytes = get_settings().max_food_photo_size_mb * 1024 * 1024
    if len(data) > max_bytes:
        raise HTTPException(
            status_code=413,
            detail=(
                f"Profile photo is too large. Maximum size is "
                f"{get_settings().max_food_photo_size_mb} MB."
            ),
        )

    ext, mime = _sniff_image_kind(data)
    if ext is None:
        content_type = (file.content_type or "").lower()
        ext = _IMAGE_EXTENSIONS.get(content_type)
        mime = content_type if ext is None or "image" in content_type else None
    if ext is None:
        ext = _extension_of_filename(file.filename)
        mime = _EXTENSION_MIME.get(ext) if ext else None
    if ext is None:
        raise HTTPException(
            status_code=415,
            detail="Profile photos must be PNG, JPEG, WebP, HEIC, or HEIF images.",
        )
    uploaded_mime = mime or _EXTENSION_MIME.get(ext, "application/octet-stream")

    client = get_supabase_client()
    bucket = get_settings().supabase_storage_bucket
    path = f"profile-photos/{profile['id']}/{uuid4().hex}.{ext}"
    try:
        _ensure_storage_bucket(client, bucket)
        client.storage.from_(bucket).upload(
            path,
            data,
            file_options={"content-type": uploaded_mime},
        )
        url = client.storage.from_(bucket).get_public_url(path)
    except HTTPException:
        raise
    except Exception as exc:
        raise HTTPException(
            status_code=502,
            detail="Profile photo could not be saved. Please try again.",
        ) from exc

    client.table("users").update({"profile_image_url": url}).eq("id", profile["id"]).execute()
    return {"profile_image_url": url}
