from typing import Literal

from pydantic import BaseModel, Field


class DeviceTokenRegister(BaseModel):
    """An FCM token registered for the authenticated user's device."""

    token: str = Field(min_length=1, max_length=4096)
    platform: Literal["android", "ios", "web"]


class DeviceTokenResponse(BaseModel):
    id: str
    user_id: str
    token: str
    platform: str
    created_at: str
    updated_at: str
