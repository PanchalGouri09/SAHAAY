"""
Mandatory DAILY FOOD ENTRY — the provider's per-day food log and the entry
point for the existing AI surplus prediction.

A daily food entry is NOT a donation. Nothing in this router touches the
`donations` table, and submitting an entry never lists a donation.

Flow (unchanged boundary, no direct Flutter -> AI call):

    Flutter -> this FastAPI backend -> existing AI FastAPI service
             -> public.food_predictions -> provider dashboard

The AI model, the AI endpoint, the AI request contract and the AI service URL
are all untouched. This router reuses `AIClient.predict_surplus()` with the
existing `SurplusPredictionRequest`, deriving `day_of_week` and `date` on the
server. `provider_id` is never sent to the AI service and is never accepted
from the client.
"""

from __future__ import annotations

from datetime import date

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import ValidationError

from app.dependencies import require_role
from app.schemas.ai import SurplusPredictionRequest
from app.schemas.daily_food import DailyFoodEntryCreate
from app.services.ai_client import (
    AIClient,
    AIServiceHTTPError,
    AIServiceUnavailableError,
    get_ai_client,
)
from app.services.food_mapping import FoodCategoryAliases, map_food_category
from app.services.predictions import insert_prediction, prediction_payload
from app.supabase_client import get_supabase_client

router = APIRouter(prefix="/daily-food", tags=["daily-food"])

# Distinct AI categories reachable through the existing explicit mapping, used
# only to build a helpful error message. No mapping is added or changed.
_SUPPORTED_CATEGORY_HINTS = sorted(set(FoodCategoryAliases.values()))


def _provider_id_of(profile: dict) -> str:
    provider = profile.get("providers")
    if not provider:
        raise HTTPException(status_code=404, detail="Provider profile not found.")
    return provider[0]["id"] if isinstance(provider, list) else provider["id"]


def _entries_for(provider_id: str):
    """Always provider-scoped: a caller can only ever read their own rows."""
    return get_supabase_client().table("daily_food_entries").select("*").eq(
        "provider_id", provider_id
    )


def _entry_on(provider_id: str, entry_date: date) -> dict | None:
    rows = _entries_for(provider_id).eq("entry_date", entry_date.isoformat()).limit(
        1
    ).execute().data
    return rows[0] if rows else None


def _attached_prediction(entry: dict) -> dict:
    """Re-hydrate the stored prediction for a read.

    An entry whose AI call failed still exists, so this never raises: it returns
    a non-fatal `unavailable` status the UI can render as an error state.
    """
    prediction_id = entry.get("prediction_id")
    if not prediction_id:
        return {
            "status": "unavailable",
            "reason": "No AI prediction is attached to this entry yet.",
        }
    rows = (
        get_supabase_client()
        .table("food_predictions")
        .select("*")
        .eq("id", prediction_id)
        .limit(1)
        .execute()
        .data
    )
    if not rows:
        return {
            "status": "unavailable",
            "reason": "The AI prediction for this entry could not be read.",
        }
    row = rows[0]
    return {
        "status": "saved",
        "prediction_id": row["id"],
        # `predicted_surplus` is stored rounded to 2dp; `planned_quantity` is
        # the existing integer column and is returned as stored (not resized).
        "predicted_surplus_kg": row["predicted_surplus"],
        "recommended_prepare_kg": row["planned_quantity"],
        "preparation_recommendation": row["recommendation"],
        "prediction_date": row["prediction_date"],
        "day_of_week": row["day_of_week"],
        "model_version": row["model_version"],
    }


def _predict_and_link(
    ai_client: AIClient, provider_id: str, entry: dict
) -> tuple[dict, dict]:
    """Call the existing AI service and link the stored prediction back.

    Mirrors the donation flow's non-fatal behavior: if the AI service is
    unreachable or answers nonsense, the daily entry is still saved and the
    prediction is reported as skipped so the UI can show a clear error state
    instead of losing the provider's real data.
    """
    entry_date = date.fromisoformat(str(entry["entry_date"])[:10])
    request = SurplusPredictionRequest(
        food_prepared_kg=float(entry["food_prepared_kg"]),
        food_sold_kg=float(entry["food_sold_kg"]),
        food_category=map_food_category(entry["food_category"]),
        day_of_week=entry_date.strftime("%A"),
        date=entry_date,
    )
    try:
        result = ai_client.predict_surplus(request)
    except (AIServiceHTTPError, AIServiceUnavailableError) as exc:
        return entry, {"status": "skipped", "reason": str(exc)}
    except ValidationError:
        return entry, {
            "status": "skipped",
            "reason": "AI prediction service returned an invalid response.",
        }

    try:
        prediction_id = insert_prediction(
            get_supabase_client(), provider_id, request, result
        )
        linked = (
            get_supabase_client()
            .table("daily_food_entries")
            .update({"prediction_id": prediction_id})
            .eq("id", entry["id"])
            .select()
            .execute()
            .data[0]
        )
    except Exception:  # noqa: BLE001 - never lose the saved entry
        return entry, {
            "status": "error",
            "reason": "Daily food entry was saved but the prediction could not be saved.",
        }

    return linked, {
        "status": "saved",
        "prediction_id": linked["prediction_id"],
        **prediction_payload(result),
        "prediction_date": request.date.isoformat(),
        "model_version": result.model_version,
    }


@router.post("")
def create_daily_food_entry(
    payload: DailyFoodEntryCreate,
    profile: dict = Depends(require_role("provider")),
    ai_client: AIClient = Depends(get_ai_client),
) -> dict:
    """Create today's entry for the authenticated provider.

    `provider_id` comes from the Firebase token and `entry_date` from the server
    clock. The client cannot influence either. One entry per provider per day is
    enforced here and again by the unique index.
    """
    provider_id = _provider_id_of(profile)
    entry_date = date.today()

    # Category is mapped through the EXISTING explicit mapping and rejected when
    # it does not resolve, so the AI service only ever sees its own vocabulary.
    if map_food_category(payload.food_category) is None:
        raise HTTPException(
            status_code=422,
            detail=(
                f"Food category '{payload.food_category}' is not supported by the "
                "AI prediction service. Mappable categories resolve to: "
                f"{', '.join(_SUPPORTED_CATEGORY_HINTS)}."
            ),
        )

    if _entry_on(provider_id, entry_date) is not None:
        raise HTTPException(
            status_code=409,
            detail="Today's daily food entry has already been submitted.",
        )

    try:
        entry = (
            get_supabase_client()
            .table("daily_food_entries")
            .insert(
                {
                    "provider_id": provider_id,
                    "entry_date": entry_date.isoformat(),
                    "food_category": payload.food_category,
                    "food_prepared_kg": payload.food_prepared_kg,
                    "food_sold_kg": payload.food_sold_kg,
                    "meal_type": payload.meal_type,
                }
            )
            .select()
            .execute()
            .data[0]
        )
    except Exception as exc:  # noqa: BLE001
        # Postgres 23505 = unique_violation. The (provider_id, entry_date) unique
        # index is the last line of defence against a double submit that raced
        # past the pre-check above. Any other database error is not swallowed.
        if getattr(exc, "code", None) == "23505":
            raise HTTPException(
                status_code=409,
                detail="Today's daily food entry has already been submitted.",
            ) from exc
        raise

    entry, prediction = _predict_and_link(ai_client, provider_id, entry)
    return {**entry, "prediction": prediction}


@router.get("/today")
def get_today_daily_food_entry(
    profile: dict = Depends(require_role("provider")),
) -> dict:
    """Backend-authoritative answer to "does today's entry exist?".

    This is what the provider gate calls. It never raises for a missing entry —
    it reports `entry_required: true` — so the client never has to guess from a
    local date, and the date always comes from the server clock.
    """
    provider_id = _provider_id_of(profile)
    entry_date = date.today()
    entry = _entry_on(provider_id, entry_date)
    if entry is None:
        return {
            "entry_required": True,
            "entry_date": entry_date.isoformat(),
            "data": None,
            "prediction": None,
        }
    return {
        "entry_required": False,
        "entry_date": entry_date.isoformat(),
        "data": entry,
        "prediction": _attached_prediction(entry),
    }


@router.get("/history")
def list_daily_food_history(
    profile: dict = Depends(require_role("provider")),
    limit: int = Query(default=30, ge=1, le=200),
) -> dict:
    """The authenticated provider's previous entries, newest first.

    Scoped by `provider_id` server-side, so no other provider's rows can be
    reached through this endpoint.
    """
    provider_id = _provider_id_of(profile)
    rows = (
        _entries_for(provider_id)
        .order("entry_date", desc=True)
        .limit(limit)
        .execute().data
        or []
    )
    return {
        "data": [{**row, "prediction": _attached_prediction(row)} for row in rows]
    }
