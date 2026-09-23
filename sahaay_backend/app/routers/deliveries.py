from fastapi import APIRouter, Depends, HTTPException

from app.dependencies import require_role
from app.schemas.donation import DeliveryStatusUpdate
from app.supabase_client import get_supabase_client

router = APIRouter(prefix="/deliveries", tags=["deliveries"])


@router.get("")
def list_deliveries(profile: dict = Depends(require_role("volunteer"))) -> list[dict]:
    volunteer = profile.get("volunteers")
    if not volunteer:
        raise HTTPException(status_code=404, detail="Volunteer profile not found.")
    volunteer_id = volunteer[0]["id"] if isinstance(volunteer, list) else volunteer["id"]
    response = get_supabase_client().table("deliveries").select("*").eq("volunteer_id", volunteer_id).order("created_at", desc=True).execute()
    return response.data or []


@router.patch("/{delivery_id}/status")
def update_delivery(
    delivery_id: str,
    payload: DeliveryStatusUpdate,
    profile: dict = Depends(require_role("volunteer")),
) -> dict:
    volunteer = profile.get("volunteers")
    if not volunteer:
        raise HTTPException(status_code=404, detail="Volunteer profile not found.")
    volunteer_id = volunteer[0]["id"] if isinstance(volunteer, list) else volunteer["id"]
    client = get_supabase_client()
    existing = client.table("deliveries").select("id").eq("id", delivery_id).eq("volunteer_id", volunteer_id).maybe_single().execute()
    if existing is None:
        raise HTTPException(status_code=404, detail="Delivery not found.")
    values = payload.model_dump(exclude_none=True)
    response = client.table("deliveries").update(values).eq("id", delivery_id).eq("volunteer_id", volunteer_id).select().execute()
    if not response.data:
        raise HTTPException(status_code=404, detail="Delivery not found.")
    return response.data[0]
