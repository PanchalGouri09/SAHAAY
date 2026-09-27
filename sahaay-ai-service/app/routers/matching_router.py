from fastapi import APIRouter, HTTPException

from app.core.matching import score_and_rank_ngos
from app.models.schemas import MatchRequest, MatchResponse

router = APIRouter(prefix="/api/v1/matching", tags=["NGO Matching"])


@router.post("/rank-ngos", response_model=MatchResponse)
def rank_ngos_endpoint(payload: MatchRequest):
    """
    Ranks candidate NGOs for a donation based on distance, quantity fit,
    dietary compatibility, pickup-time feasibility, and restaurant
    reliability. Returns NGOs sorted best match first.
    """
    if not payload.candidate_ngos:
        raise HTTPException(status_code=400, detail="candidate_ngos list cannot be empty.")

    try:
        result = score_and_rank_ngos(payload.donation, payload.candidate_ngos)
    except Exception as exc:  # noqa: BLE001
        raise HTTPException(status_code=500, detail=f"Matching failed: {exc}") from exc

    return result
