from typing import Literal
from uuid import UUID

from pydantic import BaseModel, Field, model_validator

Role = Literal["provider", "ngo", "volunteer", "admin"]

# 24-hour "HH:MM" — the format the AI service stores in NGOInput.
# Matches the ngos.available_from / available_to check constraints.
_HOUR_PATTERN = r"^([01][0-9]|2[0-3]):[0-5][0-9]$"


class ProviderProfileCreate(BaseModel):
    organization_name: str
    organization_type: str
    description: str | None = None
    phone: str | None = None
    address: str
    city: str = "Pune"
    latitude: float | None = None
    longitude: float | None = None


class NgoProfileCreate(BaseModel):
    organization_name: str
    registration_number: str | None = None
    description: str | None = None
    phone: str | None = None
    address: str
    city: str = "Pune"
    latitude: float | None = None
    longitude: float | None = None
    food_capacity: int | None = Field(default=None, ge=0)
    preferred_food_types: list[str] | None = None
    available_from: str | None = Field(default=None, pattern=_HOUR_PATTERN)
    available_to: str | None = Field(default=None, pattern=_HOUR_PATTERN)

    @model_validator(mode="after")
    def _hours_must_be_a_pair(self):
        if (self.available_from is None) != (self.available_to is None):
            raise ValueError(
                "available_from and available_to must be set together or both left empty."
            )
        return self


class VolunteerProfileCreate(BaseModel):
    availability_status: Literal["available", "busy", "offline"] = "offline"
    vehicle_type: Literal["walking", "bike", "car", "other"] | None = None
    current_latitude: float | None = None
    current_longitude: float | None = None


class ProfileCreate(BaseModel):
    full_name: str
    email: str
    phone: str | None = None
    role: Role
    provider: ProviderProfileCreate | None = None
    ngo: NgoProfileCreate | None = None
    volunteer: VolunteerProfileCreate | None = None


class ProfileResponse(BaseModel):
    id: UUID
    firebase_uid: str
    full_name: str
    email: str
    phone: str | None = None
    role: str
    profile: dict | None = None


class ProfileUpdate(BaseModel):
    full_name: str | None = None
    phone: str | None = None
    profile_image_url: str | None = None
    provider: ProviderProfileCreate | None = None
    ngo: NgoProfileCreate | None = None
    volunteer: VolunteerProfileCreate | None = None
