from datetime import datetime
from typing import Literal
from uuid import UUID

from pydantic import BaseModel, Field, model_validator

DonationStatus = Literal[
    "available",
    "claimed",
    "pickup_assigned",
    "picked_up",
    "in_transit",
    "delivered",
    "completed",
    "expired",
    "cancelled",
]
VegType = Literal["vegetarian", "non_vegetarian", "vegan", "mixed"]
StorageCondition = Literal["refrigerated", "frozen", "room_temperature", "insulated_container"]
DeliveryStatus = Literal[
    "assigned",
    "accepted",
    "picked_up",
    "in_transit",
    "delivered",
    "failed",
    "cancelled",
]


class DonationCreate(BaseModel):
    food_name: str
    food_category: str
    quantity: float = Field(gt=0)
    unit: str = "servings"
    servings: int | None = Field(default=None, ge=0)
    veg_type: VegType | None = None
    description: str | None = None
    # A provider may NOT create a donation without a food photo: the image is
    # uploaded through POST /api/v1/donations/upload first and its returned
    # food_image_url MUST be present here.
    food_image_url: str = Field(min_length=1)
    prepared_at: datetime
    expiry_time: datetime
    pickup_deadline: datetime
    pickup_address: str
    latitude: float | None = None
    longitude: float | None = None
    status: DonationStatus = "available"

    # AI safety input consumed by the safety service only; it is not a
    # donations column and is never persisted. food_prepared_kg/food_sold_kg
    # ARE donations columns (added by migration) and are persisted; they are
    # used for surplus prediction only when BOTH are provided (no invented
    # defaults).
    storage_condition: StorageCondition | None = None
    food_prepared_kg: float | None = Field(default=None, gt=0)
    food_sold_kg: float | None = Field(default=None, ge=0)

    @model_validator(mode="after")
    def _validate_surplus_inputs(self) -> "DonationCreate":
        has_prepared = self.food_prepared_kg is not None
        has_sold = self.food_sold_kg is not None
        if has_prepared != has_sold:
            raise ValueError(
                "food_prepared_kg and food_sold_kg must be provided together for surplus prediction."
            )
        if has_sold and self.food_sold_kg > self.food_prepared_kg:
            raise ValueError("food_sold_kg cannot exceed food_prepared_kg.")
        return self


class FoodImageUploadResponse(BaseModel):
    food_image_url: str


class DonationUpdate(BaseModel):
    food_name: str | None = None
    food_category: str | None = None
    quantity: float | None = Field(default=None, gt=0)
    unit: str | None = None
    servings: int | None = Field(default=None, ge=0)
    veg_type: VegType | None = None
    description: str | None = None
    food_image_url: str | None = None
    prepared_at: datetime | None = None
    expiry_time: datetime | None = None
    pickup_deadline: datetime | None = None
    pickup_address: str | None = None
    latitude: float | None = None
    longitude: float | None = None
    status: DonationStatus | None = None


class ClaimCreate(BaseModel):
    donation_id: UUID
    requested_quantity: float = Field(gt=0)
    notes: str | None = None


class DeliveryStatusUpdate(BaseModel):
    status: DeliveryStatus
    notes: str | None = None
    failure_reason: str | None = None
