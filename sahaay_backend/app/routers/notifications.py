from fastapi import APIRouter, Depends, HTTPException

from app.dependencies import get_current_profile
from app.supabase_client import get_supabase_client

router = APIRouter(prefix="/notifications", tags=["notifications"])


@router.get("")
def list_notifications(profile: dict = Depends(get_current_profile)) -> list[dict]:
    response = get_supabase_client().table("notifications").select("*").eq("user_id", profile["id"]).order("created_at", desc=True).execute()
    return response.data or []


@router.patch("/{notification_id}/read")
def mark_notification_read(notification_id: str, profile: dict = Depends(get_current_profile)) -> dict:
    client = get_supabase_client()
    existing = client.table("notifications").select("id").eq("id", notification_id).eq("user_id", profile["id"]).maybe_single().execute()
    if existing is None:
        raise HTTPException(status_code=404, detail="Notification not found.")
    response = client.table("notifications").update({"is_read": True}).eq("id", notification_id).eq("user_id", profile["id"]).select().execute()
    if not response.data:
        raise HTTPException(status_code=404, detail="Notification not found.")
    return response.data[0]
