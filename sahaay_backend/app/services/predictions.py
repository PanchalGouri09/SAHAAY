"""
Shared surplus-prediction persistence.

Both `app.routers.donations` (donation-triggered prediction) and
`app.routers.daily_food` (mandatory daily food entry) write the SAME AI result
into the SAME existing `public.food_predictions` table, so the row shape and the
AI payload shape are defined once here.

Nothing about the AI model, the AI endpoint, the AI request contract or the AI
service URL changes. This module only factors out the insert that the donation
flow already performed, so both flows cannot drift apart.
"""

from __future__ import annotations

from app.schemas.ai import SurplusPredictionRequest


def prediction_row(
    provider_id: str, request: SurplusPredictionRequest, result
) -> dict:
    """Build the `public.food_predictions` INSERT shared by both flows.

    `planned_quantity` stays an int because that is the existing column type.
    The AI service recommends a kg value, so it is rounded here exactly as the
    donation flow already did; the column is deliberately NOT redesigned.
    """
    return {
        "provider_id": provider_id,
        "prediction_date": request.date.isoformat(),
        "day_of_week": request.day_of_week,
        "planned_quantity": int(round(result.recommended_prepare_kg)),
        "predicted_consumption": None,
        "predicted_surplus": round(result.predicted_surplus_kg, 2),
        "surplus_probability": None,
        "recommendation": result.preparation_recommendation,
        "model_version": result.model_version,
    }


def insert_prediction(
    client, provider_id: str, request: SurplusPredictionRequest, result
) -> str:
    """Insert the AI result and return the new `food_predictions.id`."""
    inserted = (
        client.table("food_predictions")
        .insert(prediction_row(provider_id, request, result))
        .select("id")
        .execute()
    )
    return inserted.data[0]["id"]


def prediction_payload(result) -> dict:
    """The AI values echoed back to the client.

    Key-for-key identical to the shape the donation flow already returned, so
    the donation response is unchanged.
    """
    return {
        "predicted_surplus_kg": result.predicted_surplus_kg,
        "recommended_prepare_kg": result.recommended_prepare_kg,
        "preparation_recommendation": result.preparation_recommendation,
    }
