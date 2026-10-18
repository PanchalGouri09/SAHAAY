from typing import Literal

from pydantic import BaseModel, Field

DevicePlatform = Literal["android", "ios", "web"]


class DeviceTokenRegister(BaseModel):
    """A client-supplied FCM registration token for the AUTHENTICATED user.

    The token is stored against the caller's own users.id (resolved from the
    verified Firebase token); it is never used to address another user, so a
    client cannot register a device "for" someone else.
    """

    token: str = Field(min_length=1)
    platform: DevicePlatform = "android"
