"""
Provider donation creation + listing.

Phase 1 provider flow: a donation is created only AFTER the standalone AI
service verifies food safety over the REAL donation inputs. "Not Eligible"
rejects the donation (nothing is persisted). "Requires Manual Review" also
blocks creation because the current donations.status CHECK constraint cannot
represent a manual-review/rejected state, so we refuse rather than invent a
non-persistable state or silently treat it as safe.

Surplus prediction is a separate, OPTIONAL step: it runs only when the caller
has supplied BOTH food_prepared_kg and food_sold_kg (real inputs), and the
result is persisted into the existing food_predictions schema, then linked to
the donation via the existing donations.prediction_id FK.

The AI is never bypassed for safety; if the AI service is unavailable or
returns a malformed response, the request fails with a controlled 5xx error.
"""

import logging
from datetime import datetime, timezone
from uuid import uuid4

from fastapi import APIRouter, Depends, File, HTTPException, UploadFile
from pydantic import ValidationError

from app.config import get_settings
from app.dependencies import get_current_firebase_user, get_current_profile, require_role
from app.schemas.ai import SafetyCheckRequest, SurplusPredictionRequest
from app.schemas.donation import (
    DonationCreate,
    DonationMatchingDetailsUpdate,
    DonationUpdate,
    FoodImageUploadResponse,
)
from app.services.ai_client import (
    AIClient,
    AIServiceHTTPError,
    AIServiceUnavailableError,
    get_ai_client,
)
from app.services.food_mapping import map_food_category, map_veg_type_to_ai
from app.services import notification_service
from app.services.donation_offers import auto_start_offers_for_donation
from app.services.profile_completion import (
    require_complete_profile,
)
from app.services.predictions import insert_prediction, prediction_payload
from app.supabase_client import get_supabase_client

router = APIRouter(prefix="/donations", tags=["donations"])
logger = logging.getLogger("sahaay.donations")

# Field consumed by the AI pipeline but deliberately not persisted: the safety
# service needs the storage condition, yet it is not a donations column.
# food_prepared_kg/food_sold_kg ARE donations columns (migration adds them) and
# are persisted; only storage_condition stays transient here.
_AI_TRANSIENT_FIELDS = {
    "storage_condition",
}


def _provider_id_of(profile: dict) -> str:
    provider = profile.get("providers")
    if not provider:
        raise HTTPException(status_code=404, detail="Provider profile not found.")
    return provider[0]["id"] if isinstance(provider, list) else provider["id"]


def _verify_safety(ai_client: AIClient, request: SafetyCheckRequest):
    try:
        return ai_client.verify_safety(request)
    except AIServiceUnavailableError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc
    except AIServiceHTTPError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    except ValidationError as exc:
        raise HTTPException(
            status_code=502,
            detail="AI safety service returned an invalid response.",
        ) from exc


def _persist_prediction(
    client, provider_id: str, request: SurplusPredictionRequest, result, donation: dict
) -> dict:
    """Persist an AI surplus prediction into the CURRENT food_predictions
    schema and link it to the donation via donations.prediction_id (an
    existing nullable FK; no migration involved).

    The insert itself now lives in `app.services.predictions` so the donation
    flow and the daily food entry flow cannot drift apart. The written columns,
    the rounding of planned_quantity and the linked FK are all unchanged.
    """
    prediction_id = insert_prediction(client, provider_id, request, result)
    updated = (
        client.table("donations")
        .update({"prediction_id": prediction_id})
        .eq("id", donation["id"])
        .select()
        .execute()
    )
    return updated.data[0]


def _maybe_predict_surplus(
    ai_client: AIClient,
    provider_id: str,
    payload: DonationCreate,
    ai_category: str,
    donation: dict,
):
    has_prepared = payload.food_prepared_kg is not None
    has_sold = payload.food_sold_kg is not None
    if not has_prepared and not has_sold:
        return None
    if ai_category == "other":
        return {
            "status": "skipped",
            "reason": "No historical surplus model is trained for the Other category.",
        }

    # (Both-or-neither and sold <= prepared are enforced by the DonationCreate
    # schema before any persistence happens, so no re-check is needed here.)

    request = SurplusPredictionRequest(
        food_prepared_kg=payload.food_prepared_kg,
        food_sold_kg=payload.food_sold_kg,
        food_category=ai_category,
        day_of_week=payload.prepared_at.strftime("%A"),
        date=payload.prepared_at.date(),
    )
    try:
        result = ai_client.predict_surplus(request)
    except (AIServiceHTTPError, AIServiceUnavailableError) as exc:
        return {"status": "skipped", "reason": str(exc)}
    except ValidationError as exc:
        return {"status": "skipped", "reason": "AI prediction service returned an invalid response."}

    try:
        updated = _persist_prediction(
            get_supabase_client(), provider_id, request, result, donation
        )
    except Exception as exc:
        return {"status": "error", "reason": "Donation was created but the prediction could not be saved."}

    return {
        "status": "saved",
        "prediction_id": updated["prediction_id"],
        **prediction_payload(result),
    }


@router.post("")
def create_donation(
    payload: DonationCreate,
    profile: dict = Depends(require_role("provider")),
    ai_client: AIClient = Depends(get_ai_client),
) -> dict:
    require_complete_profile(profile, action="creating a donation")
    provider_id = _provider_id_of(profile)

    # Optional AI surplus prediction must never invent input values: it runs
    # only when the provider genuinely supplied prepared AND sold quantities.
    ai_category = map_food_category(payload.food_category)
    if ai_category is None:
        raise HTTPException(
            status_code=422,
            detail=f"Food category '{payload.food_category}' is not supported by the food safety service.",
        )
    if payload.storage_condition is None:
        raise HTTPException(
            status_code=400,
            detail="storage_condition is required for food safety verification. "
            "Allowed values: 'refrigerated', 'frozen', 'room_temperature', 'insulated_container'.",
        )

    # Real AI safety verification before anything is persisted.
    safety = _verify_safety(
        ai_client,
        SafetyCheckRequest(
            donation_id=f"pending-{uuid4()}",
            food_category=ai_category,
            prepared_at=payload.prepared_at,
            storage_condition=payload.storage_condition,
            donation_status=payload.status or "available",
        ),
    )
    if safety.verdict == "Not Eligible":
        raise HTTPException(
            status_code=400,
            detail="Donation was rejected by the food safety check and was not created. "
            f"Reasons: {'; '.join(safety.reasons)}",
        )
    if safety.verdict == "Requires Manual Review":
        raise HTTPException(
            status_code=422,
            detail="Donation requires a manual review and cannot be accepted automatically; "
            "the current schema cannot persist a manual-review state. "
            f"Reasons: {'; '.join(safety.reasons)}",
        )

    values = {
        key: value
        for key, value in payload.model_dump(mode="json").items()
        if key not in _AI_TRANSIENT_FIELDS
    }
    values["provider_id"] = provider_id
    donation = (
        get_supabase_client()
        .table("donations")
        .insert(values)
        .select()
        .execute()
        .data[0]
    )

    # A donation that was really persisted is a real business event: notify the
    # verified NGOs in the provider's own city (the recipient list is derived
    # server-side from `ngos.city`/`providers.city`, never from the request).
    # Best-effort: the helper never raises, so it cannot fail the creation.
    provider = profile.get("providers")
    provider_row = provider[0] if isinstance(provider, list) else provider
    notification_service.donation_created(
        get_supabase_client(), donation=donation, provider_row=provider_row
    )

    # Matching reuses the existing eligibility filters and AI ranking. Offer
    # setup is best-effort so an unavailable ranking service cannot undo an
    # already-persisted donation; a later retry can safely start the sequence.
    try:
        matching = auto_start_offers_for_donation(
            get_supabase_client(),
            donation=donation,
            profile=profile,
            ai_client=ai_client,
        )
    except Exception as exc:  # noqa: BLE001
        logger.warning(
            "Could not start ranked offers error_type=%s",
            type(exc).__name__,
        )
        matching = {
            "status": "error",
            "reason": "Automatic matching could not be started; it will be retried.",
        }

    prediction = _maybe_predict_surplus(
        ai_client, provider_id, payload, ai_category, donation
    )
    return {**donation, "prediction": prediction, "matching": matching}


@router.patch("/{donation_id}/matching-details")
def update_donation_matching_details(
    donation_id: str,
    payload: DonationMatchingDetailsUpdate,
    profile: dict = Depends(require_role("provider")),
) -> dict:
    """Save an explicitly chosen dietary type and retry the ranked offers."""
    provider_id = _provider_id_of(profile)
    client = get_supabase_client()
    existing = (
        client.table("donations")
        .select("id,provider_id,status")
        .eq("id", donation_id)
        .maybe_single()
        .execute()
    )
    donation = getattr(existing, "data", None)
    if not donation:
        raise HTTPException(status_code=404, detail="Donation not found.")
    if str(donation.get("provider_id")) != provider_id:
        raise HTTPException(status_code=403, detail="Donation does not belong to this provider.")
    if donation.get("status") != "available":
        raise HTTPException(
            status_code=409,
            detail="Only an available donation can have matching details updated.",
        )

    updated = (
        client.table("donations")
        .update({"veg_type": payload.veg_type})
        .eq("id", donation_id)
        .eq("provider_id", provider_id)
        .eq("status", "available")
        .select("*")
        .execute()
        .data
        or []
    )
    if not updated:
        raise HTTPException(
            status_code=409,
            detail="The donation changed while matching details were being updated. Refresh and retry.",
        )
    updated_donation = updated[0]
    try:
        matching = auto_start_offers_for_donation(
            client,
            donation=updated_donation,
            profile=profile,
            ai_client=get_ai_client(),
        )
    except Exception as exc:  # noqa: BLE001
        logger.warning(
            "Could not retry matching after donation detail update error_type=%s",
            type(exc).__name__,
        )
        matching = {
            "status": "error",
            "reason": "Matching could not be refreshed; use Refresh matching to retry.",
        }
    return {**updated_donation, "matching": matching}


# MIME/extension lookup used only when byte-sniffing is inconclusive (e.g.
# HEIC/HEIF which have no simple magic signature). Keep existing extra formats
# (webp/heic/heif) supported alongside png/jpg/jpeg.
_IMAGE_EXTENSIONS = {
    "image/png": "png",
    "image/jpeg": "jpg",
    "image/jpg": "jpg",
    "image/webp": "webp",
    "image/heic": "heic",
    "image/heif": "heif",
}

_EXTENSION_MIME = {
    "png": "image/png",
    "jpg": "image/jpeg",
    "jpeg": "image/jpeg",
    "webp": "image/webp",
    "heic": "image/heic",
    "heif": "image/heif",
}


def _sniff_image_kind(data: bytes) -> tuple[str | None, str | None]:
    if data.startswith(b"\x89PNG\r\n\x1a\n"):
        return "png", "image/png"
    if data[:3] == b"\xff\xd8\xff":
        return "jpg", "image/jpeg"
    if data[:4] == b"RIFF" and data[8:12] == b"WEBP":
        return "webp", "image/webp"
    return None, None


def _extension_of_filename(filename: str | None) -> str | None:
    if not filename:
        return None
    ext = filename.rsplit(".", 1)[-1].lower().lstrip(".")
    return ext if ext in _EXTENSION_MIME else None


def _ensure_storage_bucket(client, bucket: str) -> None:
    try:
        client.storage.get_bucket(bucket)
    except Exception:
        try:
            client.storage.create_bucket(bucket, options={"public": True})
        except Exception as exc:
            raise HTTPException(
                status_code=502,
                detail="Food photo storage is not ready. Please try again later.",
            ) from exc


@router.post("/upload", response_model=FoodImageUploadResponse)
def upload_donation_image(
    file: UploadFile = File(...),
    profile: dict = Depends(require_role("provider")),
) -> FoodImageUploadResponse:
    # Uploading a photo is scoped to an authenticated provider profile. Trusted
    # contact verification remains enforced when the donation itself is created.
    provider_id = _provider_id_of(profile)

    data = file.file.read()
    max_bytes = get_settings().max_food_photo_size_mb * 1024 * 1024
    if len(data) > max_bytes:
        raise HTTPException(
            status_code=413,
            detail=f"Food photo is too large. Maximum size is {get_settings().max_food_photo_size_mb} MB.",
        )

    # Validate by the file's real content first (magic bytes), then fall back to
    # the declared content-type, then finally to the upload filename. This means
    # a valid PNG/JPG is never rejected just because the multipart MIME string
    # was empty, generic, or slightly mismatched.
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
            detail="Food photos must be PNG, JPEG, WebP, HEIC, or HEIF images.",
        )
    uploaded_mime = mime or _EXTENSION_MIME.get(ext, "application/octet-stream")

    client = get_supabase_client()
    bucket = get_settings().supabase_storage_bucket
    path = f"food-photos/{provider_id}/{uuid4().hex}.{ext}"
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
            detail="Food photo could not be saved. Please try again.",
        ) from exc
    return FoodImageUploadResponse(food_image_url=url)


@router.get("")
def list_donations(profile: dict = Depends(get_current_profile)) -> list[dict]:
    client = get_supabase_client()
    if profile["role"] == "provider":
        provider = profile.get("providers")
        provider_id = provider[0]["id"] if isinstance(provider, list) else provider["id"]
        response = (
            client.table("donations")
            .select("*")
            .eq("provider_id", provider_id)
            .order("created_at", desc=True)
            .execute()
        )
        donations = response.data or []
        prediction_ids = list(
            dict.fromkeys(
                str(donation["prediction_id"])
                for donation in donations
                if donation.get("prediction_id")
            )
        )
        if prediction_ids:
            prediction_rows = (
                client.table("food_predictions")
                .select(
                    "id,predicted_surplus,planned_quantity,recommendation,"
                    "prediction_date,model_version,confidence_score,surplus_probability"
                )
                .in_("id", prediction_ids)
                .execute()
                .data
                or []
            )
            predictions_by_id = {
                str(prediction["id"]): prediction for prediction in prediction_rows
            }
            donations = [
                {
                    **donation,
                    "surplus_prediction": predictions_by_id.get(
                        str(donation.get("prediction_id"))
                    ),
                }
                for donation in donations
            ]
        # The provider's own dashboard shows the organisation profile; attach it
        # so the client does not need a second round-trip. Best-effort only.
        provider_row = (
            client.table("providers").select("*").eq("id", provider_id).maybe_single().execute()
        )
        organisation = getattr(provider_row, "data", None)
        if organisation:
            donations = [{**d, "provider": organisation} for d in donations]
        return donations
    response = (
        client.table("donations")
        .select("*")
        .eq("status", "available")
        .gt("expiry_time", datetime.now(timezone.utc).isoformat())
        .order("created_at", desc=True)
        .execute()
    )
    return response.data or []


@router.get("/{donation_id}")
def get_donation(donation_id: str, profile: dict = Depends(get_current_profile)) -> dict:
    response = (
        get_supabase_client()
        .table("donations")
        .select("*")
        .eq("id", donation_id)
        .maybe_single()
        .execute()
    )
    if response is None:
        raise HTTPException(status_code=404, detail="Donation not found.")
    donation = response.data
    if profile["role"] == "provider":
        provider = profile.get("providers")
        provider_id = provider[0]["id"] if isinstance(provider, list) else provider["id"]
        if donation["provider_id"] != provider_id:
            raise HTTPException(status_code=403, detail="Donation does not belong to this provider.")
    elif donation["status"] != "available":
        raise HTTPException(status_code=403, detail="Donation is not available.")
    return donation
