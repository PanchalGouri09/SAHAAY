from fastapi import APIRouter, HTTPException

from app.core.escalation import check_escalation
from app.models.schemas import EscalationCheckRequest, EscalationCheckResponse

router = APIRouter(prefix="/api/v1/escalation", tags=["Auto-Escalation"])


@router.post("/check", response_model=EscalationCheckResponse)
def check_escalation_endpoint(payload: EscalationCheckRequest):
    """
    Call this periodically (e.g. every minute via a scheduled job in the
    main backend) for each donation that is awaiting NGO response.
    Returns whether to keep waiting, escalate to the next NGO, or stop
    because the NGO already accepted / the list is exhausted.
    """
    if payload.current_ngo_index >= len(payload.ranked_ngo_ids):
        raise HTTPException(
            status_code=400,
            detail="current_ngo_index is out of range for ranked_ngo_ids.",
        )
    try:
        result = check_escalation(payload)
    except Exception as exc:  # noqa: BLE001
        raise HTTPException(status_code=500, detail=f"Escalation check failed: {exc}") from exc

    return result
