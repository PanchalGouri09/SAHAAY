from fastapi import APIRouter, HTTPException

from app.core.prediction import generate_preparation_recommendation, predict_surplus
from app.models.schemas import SurplusPredictionRequest, SurplusPredictionResponse

router = APIRouter(prefix="/api/v1/prediction", tags=["Surplus Prediction"])


@router.post("/predict-surplus", response_model=SurplusPredictionResponse)
def predict_surplus_endpoint(payload: SurplusPredictionRequest):
    """
    Predicts expected food surplus (kg) based on food prepared, food sold,
    category, day of week, and date. Also returns a plain-English
    preparation recommendation for the next batch.
    """
    try:
        predicted = predict_surplus(payload)
        recommended_kg, message = generate_preparation_recommendation(payload, predicted)
    except Exception as exc:  # noqa: BLE001
        raise HTTPException(status_code=500, detail=f"Prediction failed: {exc}") from exc

    return SurplusPredictionResponse(
        predicted_surplus_kg=predicted,
        preparation_recommendation=message,
        recommended_prepare_kg=recommended_kg,
        input_echo=payload,
    )
