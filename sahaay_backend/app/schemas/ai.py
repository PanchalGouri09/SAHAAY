"""
Typed request/response models for the SAHAAY AI & Smart Features service.

These mirror the service's own contract (app/models/schemas.py) so the main
backend can marshal requests and validate responses with type safety. They
contain no AI logic; they are a wire contract only.
"""

from datetime import date, datetime
from typing import Any, Literal

from pydantic import BaseModel, Field

FoodCategory = Literal["cooked", "bakery", "dairy", "packaged", "raw", "other"]
DietaryType = Literal["veg", "non_veg", "vegan", "any"]
EscalationStatus = Literal["pending", "accepted", "rejected", "timed_out"]
SafetyVerdict = Literal["Eligible", "Not Eligible", "Requires Manual Review"]
EscalationAction = Literal["keep_waiting", "escalate", "accepted", "no_ngos_left"]
ReliabilityGrade = Literal["Excellent", "Good", "Average", "Below Average", "Poor"]


class SurplusPredictionRequest(BaseModel):
    food_prepared_kg: float = Field(gt=0)
    food_sold_kg: float = Field(ge=0)
    food_category: FoodCategory
    day_of_week: str
    date: date


class SurplusPredictionResponse(BaseModel):
    model_config = {"protected_namespaces": ()}

    predicted_surplus_kg: float
    preparation_recommendation: str
    recommended_prepare_kg: float
    input_echo: SurplusPredictionRequest
    model_version: str = "v1"
    note: str = "Prediction is an estimate based on historical patterns; treat as a guideline."


class NGOInput(BaseModel):
    ngo_id: str
    name: str
    latitude: float
    longitude: float
    dietary_accepted: list[DietaryType]
    max_capacity_kg: float = Field(gt=0)
    min_capacity_kg: float = Field(0, ge=0)
    available_from: str
    available_to: str
    reliability_score: float | None = Field(default=None, ge=0, le=100)


class DonationInput(BaseModel):
    donation_id: str
    restaurant_id: str
    restaurant_latitude: float
    restaurant_longitude: float
    quantity_kg: float = Field(gt=0)
    dietary_type: DietaryType
    pickup_time: str
    restaurant_reliability_score: float = Field(ge=0, le=100)


class MatchRequest(BaseModel):
    donation: DonationInput
    candidate_ngos: list[NGOInput]


class NGOScoreBreakdown(BaseModel):
    ngo_id: str
    ngo_name: str
    distance_km: float = Field(ge=0)
    distance_source: Literal["road", "straight_line"]
    distance_score: float = Field(ge=0, le=100)
    quantity_fit_score: float = Field(ge=0, le=100)
    dietary_compatibility_score: float = Field(ge=0, le=100)
    pickup_time_feasibility_score: float = Field(ge=0, le=100)
    restaurant_reliability_score: float = Field(ge=0, le=100)
    final_score: float = Field(ge=0, le=100)
    rank: int = Field(ge=1)


class MatchResponse(BaseModel):
    donation_id: str
    ranked_ngos: list[NGOScoreBreakdown]
    weights_used: dict[str, Any]


class EscalationCheckRequest(BaseModel):
    donation_id: str
    ranked_ngo_ids: list[str]
    current_ngo_index: int = Field(0, ge=0)
    current_ngo_status: EscalationStatus
    offer_sent_at: datetime
    timeout_minutes: int | None = None


class EscalationCheckResponse(BaseModel):
    donation_id: str
    action: EscalationAction
    next_ngo_id: str | None = None
    next_ngo_index: int | None = None
    minutes_elapsed: float
    message: str


class ReliabilityInput(BaseModel):
    restaurant_id: str
    total_donations_offered: int = Field(ge=0)
    total_donations_completed: int = Field(ge=0)
    total_donations_accepted: int = Field(ge=0)
    total_cancellations: int = Field(ge=0)
    average_ngo_rating: float = Field(ge=0, le=5)


class ReliabilityResponse(BaseModel):
    restaurant_id: str
    reliability_score: float
    grade: ReliabilityGrade
    breakdown: dict[str, Any]


class SafetyCheckRequest(BaseModel):
    donation_id: str
    food_category: FoodCategory
    prepared_at: datetime
    storage_condition: str
    donation_status: str = "pending"
    check_time: datetime | None = None


class SafetyCheckResponse(BaseModel):
    donation_id: str
    verdict: SafetyVerdict
    hours_since_preparation: float
    reasons: list[str]


class DonationAcknowledgmentRequest(BaseModel):
    donation_id: str
    restaurant_name: str
    ngo_name: str
    food_details: str
    quantity_kg: float
    donation_datetime: datetime
    completion_status: str

    # Extended, real-only facts. Every one is optional: anything the database
    # cannot supply is sent as null and rendered by the AI service as
    # "Not available" rather than invented.
    unit: str | None = None
    quantity_label: str | None = None
    servings: int | None = None
    order_id: str | None = None
    posted_at: datetime | None = None
    claimed_at: datetime | None = None
    picked_up_at: datetime | None = None
    received_at: datetime | None = None
    impact_points: int | None = None
    handover_verified_at: datetime | None = None
    handover_photo_url: str | None = None
    delivered_at: datetime | None = None
    meals_rescued: int | None = None
    food_weight_kg: float | None = None
    estimated_co2_saved: float | None = None
    volunteer_transport_used: bool | None = None
    volunteer_name: str | None = None
    completed_at: datetime | None = None
    handover_status: str | None = None
    volunteer_role: str | None = None
    ngo_receipt_confirmed: bool | None = None


class DonationAcknowledgmentResponse(BaseModel):
    donation_id: str
    pdf_filename: str
    file_path: str
    message: str