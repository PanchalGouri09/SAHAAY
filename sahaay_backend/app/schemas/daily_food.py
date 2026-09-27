"""
Request models for the mandatory daily food entry flow.

A daily food entry is NOT a donation, so nothing donation-shaped appears here:
no quantity/servings, no pickup address, no expiry, no pickup deadline, no
status, no NGO/volunteer reference.

[DailyFoodEntryCreate] deliberately has no `provider_id` and no `entry_date`
field. The provider is resolved from the Firebase bearer token and the date is
resolved from the server clock, so neither can be supplied or spoofed by the
client even if it sends extra keys.
"""

from __future__ import annotations

from typing import Literal

from pydantic import BaseModel, Field, model_validator

# The allowed optional meal types. The daily_food_entries CHECK constraint
# enforces the same set, and the Flutter screen offers exactly these.
MealType = Literal["breakfast", "lunch", "snacks", "dinner", "other"]


class DailyFoodEntryCreate(BaseModel):
    """Body for `POST /api/v1/daily-food`.

    `food_category` is the SAHAAY-side label (e.g. "Cooked Meals"); the backend
    maps it to the AI service's controlled vocabulary through
    `app.services.food_mapping.map_food_category` and rejects anything that
    does not map, so the client can never send the AI an unknown category.
    """

    food_category: str = Field(min_length=1, max_length=80)
    food_prepared_kg: float = Field(gt=0)
    food_sold_kg: float = Field(ge=0)
    meal_type: MealType | None = None

    @model_validator(mode="after")
    def _sold_within_prepared(self) -> "DailyFoodEntryCreate":
        # Same rule the donation flow already enforces on its optional kg pair.
        if self.food_sold_kg > self.food_prepared_kg:
            raise ValueError("food_sold_kg cannot exceed food_prepared_kg.")
        return self
