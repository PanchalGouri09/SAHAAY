"""NGO-facing, server-evaluated SAHAAY matching eligibility."""

from fastapi import APIRouter, Depends, HTTPException

from app.dependencies import get_current_firebase_user, require_role
from app.services.ngo_verification import (
    _ngo_row,
    assess_ngo_demo_verification,
    update_demo_verification,
)
from app.supabase_client import get_supabase_client

router = APIRouter(tags=["ngo-demo-verification"])


@router.post("/profile/ngo/demo-verification/evaluate")
def evaluate_ngo_demo_verification(
    profile: dict = Depends(require_role("ngo")),
    firebase_user: dict = Depends(get_current_firebase_user),
) -> dict:
    """Recheck only the authenticated NGO's matching-eligibility requirements."""
    ngo = _ngo_row(profile)
    if not ngo.get("id"):
        raise HTTPException(status_code=404, detail="NGO profile not found.")

    assessment = assess_ngo_demo_verification(profile, firebase_user)
    try:
        update_demo_verification(get_supabase_client(), ngo, assessment)
    except Exception as exc:
        raise HTTPException(
            status_code=503,
            detail=(
                "Account verification status could not be saved. The backend "
                "database migration may need to be applied."
            ),
        ) from exc
    return assessment
