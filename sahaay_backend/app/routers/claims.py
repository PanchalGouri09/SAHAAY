from fastapi import APIRouter, Depends, HTTPException, status

from app.dependencies import require_role
from app.schemas.donation import ClaimCreate
from app.supabase_client import get_supabase_client

router = APIRouter(prefix="/claims", tags=["claims"])


@router.post("", status_code=status.HTTP_201_CREATED)
def create_claim(payload: ClaimCreate, profile: dict = Depends(require_role("ngo"))) -> dict:
    ngo = profile.get("ngos")
    if not ngo:
        raise HTTPException(status_code=404, detail="NGO profile not found.")
    ngo_id = ngo[0]["id"] if isinstance(ngo, list) else ngo["id"]
    try:
        response = get_supabase_client().table("claims").insert({
            "donation_id": str(payload.donation_id),
            "ngo_id": ngo_id,
            "requested_quantity": payload.requested_quantity,
            "notes": payload.notes,
        }).select().execute()
        return response.data[0]
    except Exception as exc:
        raise HTTPException(status_code=500, detail="Unable to create claim.") from exc


@router.get("")
def list_claims(profile: dict = Depends(require_role("ngo"))) -> list[dict]:
    ngo = profile.get("ngos")
    if not ngo:
        raise HTTPException(status_code=404, detail="NGO profile not found.")
    ngo_id = ngo[0]["id"] if isinstance(ngo, list) else ngo["id"]
    response = get_supabase_client().table("claims").select("*").eq("ngo_id", ngo_id).order("created_at", desc=True).execute()
    return response.data or []


@router.get("/provider")
def list_provider_claims(profile: dict = Depends(require_role("provider"))) -> list[dict]:
    provider = profile.get("providers")
    if not provider:
        raise HTTPException(status_code=404, detail="Provider profile not found.")
    provider_id = provider[0]["id"] if isinstance(provider, list) else provider["id"]
    client = get_supabase_client()
    donations = client.table("donations").select("id").eq("provider_id", provider_id).execute().data or []
    donation_ids = [donation["id"] for donation in donations]
    if not donation_ids:
        return []
    response = client.table("claims").select("*").in_("donation_id", donation_ids).order("created_at", desc=True).execute()
    return response.data or []


@router.patch("/{claim_id}")
def update_claim(claim_id: str, status: str, profile: dict = Depends(require_role("ngo"))) -> dict:
    if status not in {"pending", "accepted", "rejected", "cancelled", "completed"}:
        raise HTTPException(status_code=422, detail="Invalid claim status.")
    ngo = profile.get("ngos")
    if not ngo:
        raise HTTPException(status_code=404, detail="NGO profile not found.")
    ngo_id = ngo[0]["id"] if isinstance(ngo, list) else ngo["id"]
    response = get_supabase_client().table("claims").update({"status": status}).eq("id", claim_id).eq("ngo_id", ngo_id).select().execute()
    if not response.data:
        raise HTTPException(status_code=404, detail="Claim not found for this NGO.")
    return response.data[0]
