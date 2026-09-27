from typing import Literal
from uuid import UUID

from pydantic import BaseModel, Field, field_validator, model_validator

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
    # Three-state, identical in meaning to ngos.vehicle_available:
    # true = has a vehicle, false = explicitly none, null = not answered yet.
    vehicle_available: bool | None = None


class ProviderProfileUpdate(BaseModel):
    """Partial provider update used by PATCH /api/v1/profile.

    Applied WITHOUT `exclude_none` so nullable columns can be written
    explicitly. Use [VehicleAvailabilityUpdate] for the vehicle toggle."""

    organization_name: str | None = None
    description: str | None = None
    phone: str | None = None
    address: str | None = None
    city: str | None = None
    latitude: float | None = None
    longitude: float | None = None
    vehicle_available: bool | None = None


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
    # Three-state: true = has a vehicle, false = explicitly none,
    # null (default) = the NGO has not answered yet. See the migration.
    vehicle_available: bool | None = None

    @model_validator(mode="after")
    def _hours_must_be_a_pair(self):
        if (self.available_from is None) != (self.available_to is None):
            raise ValueError(
                "available_from and available_to must be set together or both left empty."
            )
        return self


class NgoProfileUpdate(BaseModel):
    """Partial NGO update used by PATCH /api/v1/profile.

    Every field is optional, and unlike [NgoProfileCreate] this model is
    applied WITHOUT `exclude_none`, so nullable columns can be written
    explicitly. Use [VehicleAvailabilityUpdate] for the vehicle toggle.
    """

    organization_name: str | None = None
    registration_number: str | None = None
    description: str | None = None
    phone: str | None = None
    address: str | None = None
    city: str | None = None
    latitude: float | None = None
    longitude: float | None = None
    food_capacity: int | None = Field(default=None, ge=0)
    preferred_food_types: list[str] | None = None
    available_from: str | None = Field(default=None, pattern=_HOUR_PATTERN)
    available_to: str | None = Field(default=None, pattern=_HOUR_PATTERN)
    vehicle_available: bool | None = None

    @model_validator(mode="after")
    def _hours_must_be_a_pair_if_given(self):
        # Only enforce pairing when at least one hour is actually supplied;
        # a patch that touches neither must not be forced to clear both.
        if self.available_from is None and self.available_to is None:
            return self
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
    provider: ProviderProfileUpdate | None = None
    ngo: NgoProfileUpdate | None = None
    volunteer: VolunteerProfileCreate | None = None


class VehicleAvailabilityUpdate(BaseModel):
    """Body for the tri-state vehicle toggle of BOTH provider and NGO.

        PATCH /api/v1/profile/provider/vehicle-availability
        PATCH /api/v1/profile/ngo/vehicle-availability

    Deliberately separate from the full role-profile models: the vehicle toggle
    is a single tri-state field, and it MUST be able to send an explicit `null`
    (clear the answer back to "not answered"). Using an optional field on the
    full profile model would make that impossible, because an omitted field and
    an explicit null are indistinguishable in JSON.

    `null` is a meaningful value here, so it is declared explicitly with a
    default. A client that omits the field entirely also gets null, which is
    safe: clearing an unanswered question is a no-op.
    """

    vehicle_available: bool | None = None

    @field_validator("vehicle_available", mode="before")
    @classmethod
    def _reject_non_boolean(cls, value):
        # Guard against loose clients sending "true"/1/"yes" and having it
        # silently coerced. Only real booleans (or null) are accepted.
        if value is None or isinstance(value, bool):
            return value
        raise ValueError("vehicle_available must be true, false or null.")
