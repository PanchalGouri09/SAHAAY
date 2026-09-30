"""
SAHAAY device token management for Firebase Cloud Messaging.

Handles FCM token registration, retrieval, and deletion for push notification
delivery. Tokens are stored per-user in Supabase and associated with the
authenticated Firebase user via the users table foreign key.
"""

from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException, status
from app.dependencies import get_current_profile
from app.supabase_client import get_supabase_client
from app.schemas.device_token import DeviceTokenRegister, DeviceTokenResponse

router = APIRouter(prefix="/device-tokens", tags=["device-tokens"])


@router.post("", status_code=status.HTTP_201_CREATED, response_model=DeviceTokenResponse)
def register_device_token(
    payload: DeviceTokenRegister,
    profile: dict = Depends(get_current_profile),
) -> dict:
    """Register an FCM device token for the authenticated user.

    The user_id is resolved from the authenticated Firebase token via the
    users table — never trust client-provided user_id.

    Args:
        payload: The device token and platform.
        profile: The authenticated user profile from Firebase auth.

    Returns:
        The created device token record.
    """
    supabase = get_supabase_client()
    user_id = profile["id"]

    # Upsert: insert or update the token for this user
    # Conflict is on (user_id, token) unique constraint
    response = (
        supabase.table("user_device_tokens")
        .upsert(
            {
                "user_id": user_id,
                "token": payload.token,
                "platform": payload.platform,
                "updated_at": datetime.now(timezone.utc).isoformat(),
            },
            on_conflict="user_id,token",
        )
        .select()
        .single()
        .execute()
    )

    if not response.data:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Failed to register device token.",
        )

    row = response.data
    if isinstance(row, list):
        row = row[0] if row else None
    if not row:
        raise HTTPException(status_code=500, detail="Failed to register device token.")
    required = {"id", "user_id", "token", "platform", "created_at", "updated_at"}
    if not required.issubset(row):
        raise HTTPException(status_code=500, detail="Device token response is incomplete.")
    return row


@router.get("", status_code=status.HTTP_200_OK)
def list_device_tokens(
    profile: dict = Depends(get_current_profile),
) -> list[dict]:
    """List all device tokens for the authenticated user.

    Only returns tokens belonging to the currently authenticated user.
    """
    supabase = get_supabase_client()
    user_id = profile["id"]

    response = (
        supabase.table("user_device_tokens")
        .select("*")
        .eq("user_id", user_id)
        .execute()
    )

    return response.data or []


@router.delete("/{token_id}", status_code=status.HTTP_204_NO_CONTENT)
def remove_device_token(
    token_id: str,
    profile: dict = Depends(get_current_profile),
) -> None:
    """Remove a specific device token for the authenticated user.

    Only the owner of the token can delete it.
    """
    supabase = get_supabase_client()
    user_id = profile["id"]

    response = (
        supabase.table("user_device_tokens")
        .delete()
        .eq("id", token_id)
        .eq("user_id", user_id)
        .execute()
    )

    if not response.data:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Device token not found or not owned by this user.",
        )
