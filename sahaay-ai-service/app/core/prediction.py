"""
Loads the trained surplus prediction model and encoders, and exposes a
simple predict() function used by the API router.

If the model files don't exist yet (first run), it trains them
automatically from the sample dataset so the API doesn't crash.
"""

import os

import joblib
import pandas as pd

from app.config import ENCODER_PATH, SURPLUS_MODEL_PATH
from app.models.schemas import SurplusPredictionRequest

_model = None
_encoders = None


def _ensure_model_trained():
    """Train the model on first use if the .pkl files are missing."""
    if not os.path.exists(SURPLUS_MODEL_PATH) or not os.path.exists(ENCODER_PATH):
        from app.ml.train_model import train  # local import to avoid circular import at startup
        train()


def _load():
    global _model, _encoders
    if _model is None or _encoders is None:
        _ensure_model_trained()
        _model = joblib.load(SURPLUS_MODEL_PATH)
        _encoders = joblib.load(ENCODER_PATH)
    return _model, _encoders


def _safe_encode(encoder, value: str, fallback_index: int = 0) -> int:
    """
    LabelEncoder throws an error on a value it never saw during training
    (e.g. a new food category or a typo). Instead of crashing the API,
    fall back to the first known class and let the caller know via the
    response `note` field in the router.
    """
    if value in encoder.classes_:
        return int(encoder.transform([value])[0])
    return fallback_index


def predict_surplus(payload: SurplusPredictionRequest) -> float:
    model, encoders = _load()

    category_encoder = encoders["food_category"]
    day_encoder = encoders["day_of_week"]

    category_enc = _safe_encode(category_encoder, payload.food_category.value)
    day_enc = _safe_encode(day_encoder, payload.day_of_week)

    sell_through_ratio = (
        payload.food_sold_kg / payload.food_prepared_kg
        if payload.food_prepared_kg > 0
        else 0
    )

    features = pd.DataFrame(
        [{
            "food_prepared_kg": payload.food_prepared_kg,
            "food_sold_kg": payload.food_sold_kg,
            "sell_through_ratio": sell_through_ratio,
            "food_category_enc": category_enc,
            "day_of_week_enc": day_enc,
            "day_of_month": payload.date.day,
            "month": payload.date.month,
        }]
    )

    prediction = model.predict(features)[0]

    # Surplus can never exceed what was prepared, and never be negative.
    prediction = max(0.0, min(prediction, payload.food_prepared_kg))
    return round(float(prediction), 2)


# How much of the predicted surplus to actually cut from tomorrow's
# preparation quantity. Kept below 1.0 (i.e. don't cut the full
# predicted surplus) so the restaurant keeps a safety buffer and
# doesn't risk running out of food if demand is a bit higher than usual.
SURPLUS_REDUCTION_FACTOR = 0.7

# If sell-through was already very high (little to no surplus), no
# reduction is suggested — the message instead confirms things look fine.
LOW_SURPLUS_THRESHOLD_KG = 2.0


def generate_preparation_recommendation(payload: SurplusPredictionRequest, predicted_surplus_kg: float):
    """
    Turns the raw surplus number into a plain-English recommendation
    and a suggested next-batch preparation quantity, as required by the
    SRS ("Food Preparation Recommendation", not just a raw prediction).
    """
    if predicted_surplus_kg <= LOW_SURPLUS_THRESHOLD_KG:
        recommended_prepare_kg = payload.food_prepared_kg
        message = (
            f"Predicted surplus is low (~{predicted_surplus_kg} kg). "
            f"Current preparation quantity of {payload.food_prepared_kg} kg looks well-matched to demand."
        )
        return round(recommended_prepare_kg, 2), message

    reduction = round(predicted_surplus_kg * SURPLUS_REDUCTION_FACTOR, 2)
    recommended_prepare_kg = max(0.0, round(payload.food_prepared_kg - reduction, 2))

    message = (
        f"Predicted surplus is ~{predicted_surplus_kg} kg. "
        f"Consider preparing about {recommended_prepare_kg} kg next time "
        f"(a reduction of ~{reduction} kg) to reduce expected wastage while keeping a safety buffer."
    )
    return recommended_prepare_kg, message
