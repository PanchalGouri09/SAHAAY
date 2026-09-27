from fastapi import APIRouter, HTTPException

from app.core.safety import check_food_safety
from app.models.schemas import SafetyCheckRequest, SafetyCheckResponse

router = APIRouter(prefix="/api/v1/safety", tags=["Food Safety Verification"])


@router.post("/verify", response_model=SafetyCheckResponse)
def verify_food_safety_endpoint(payload: SafetyCheckRequest):
    """
    Runs rule-based food safety checks and returns Eligible / Not Eligible /
    Requires Manual Review, along with the specific reasons for the verdict.
    """
    try:
        result = check_food_safety(payload)
    except Exception as exc:  # noqa: BLE001
        raise HTTPException(status_code=500, detail=f"Safety check failed: {exc}") from exc

    return result
