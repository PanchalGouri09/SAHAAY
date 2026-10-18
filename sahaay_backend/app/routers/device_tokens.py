from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException, Response, status

from app.dependencies import get_current_profile
from app.schemas.device_token import DeviceTokenRegister, DeviceTokenResponse
from app.supabase_client import get_supabase_client

router = APIRouter(prefix="/device-tokens", tags=["device-tokens"])


@router.post(
    "",
    status_code=status.HTTP_201_CREATED,
    response_model=DeviceTokenResponse,
)
def register_device_token(
    payload: DeviceTokenRegister,
    profile: dict = Depends(get_current_profile),
) -> dict:
    """Register an FCM token for the authenticated user's profile."""
    result = (
        get_supabase_client()
        .table("user_device_tokens")
        .upsert(
            {
                "user_id": profile["id"],
                "token": payload.token,
                "platform": payload.platform,
                "updated_at": datetime.now(timezone.utc).isoformat(),
            },
            on_conflict="token",
        )
        .select()
        .single()
        .execute()
    )
    row = getattr(result, "data", None)
    if isinstance(row, list):
        row = row[0] if row else None
    required_fields = {
        "id",
        "user_id",
        "token",
        "platform",
        "created_at",
        "updated_at",
    }
    if not isinstance(row, dict) or not required_fields.issubset(row):
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Failed to register device token.",
        )
    return row


@router.get("", response_model=list[DeviceTokenResponse])
def list_device_tokens(
    profile: dict = Depends(get_current_profile),
) -> list[dict]:
    """List tokens owned by the authenticated profile only."""
    result = (
        get_supabase_client()
        .table("user_device_tokens")
        .select("*")
        .eq("user_id", profile["id"])
        .execute()
    )
    return result.data or []


@router.delete("/{token_id}", status_code=status.HTTP_204_NO_CONTENT)
def remove_device_token(
    token_id: str,
    profile: dict = Depends(get_current_profile),
) -> Response:
    """Delete a token only when it belongs to the authenticated profile."""
    result = (
        get_supabase_client()
        .table("user_device_tokens")
        .delete()
        .eq("id", token_id)
        .eq("user_id", profile["id"])
        .execute()
    )
    if not result.data:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Device token not found or not owned by this user.",
        )
    return Response(status_code=status.HTTP_204_NO_CONTENT)
