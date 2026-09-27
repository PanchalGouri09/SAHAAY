from fastapi import APIRouter, HTTPException

from app.core.reliability import calculate_reliability
from app.models.schemas import ReliabilityInput, ReliabilityResponse

router = APIRouter(prefix="/api/v1/reliability", tags=["Restaurant Reliability"])


@router.post("/calculate", response_model=ReliabilityResponse)
def calculate_reliability_endpoint(payload: ReliabilityInput):
    """
    Calculates a restaurant's reliability score out of 100 based on
    completion rate, average NGO rating, cancellations, and acceptance history.
    """
    if payload.total_donations_completed > payload.total_donations_offered:
        raise HTTPException(
            status_code=400,
            detail="total_donations_completed cannot exceed total_donations_offered.",
        )
    try:
        result = calculate_reliability(payload)
    except Exception as exc:  # noqa: BLE001
        raise HTTPException(status_code=500, detail=f"Reliability calculation failed: {exc}") from exc

    return result
