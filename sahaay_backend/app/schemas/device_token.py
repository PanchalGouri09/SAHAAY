from typing import Literal

from pydantic import BaseModel, Field


class DeviceTokenRegister(BaseModel):
    """Payload for registering an FCM device token."""
    token: str = Field(
        ..., min_length=1, max_length=4096,
        description="The FCM registration token or APNs device token.",
    )
    platform: Literal["android", "ios", "web"] = Field(
        ..., description="The platform: 'android', 'ios', or 'web'."
    )


class DeviceTokenResponse(BaseModel):
    """Response for device token operations."""
    id: str
    user_id: str
    token: str
    platform: str
    created_at: str
    updated_at: str
