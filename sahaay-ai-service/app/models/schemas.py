"""
All Pydantic request/response models used across the SAHAAY AI service.
Keeping them in one file makes it easy for the backend team to see the
full API contract at a glance.
"""

from datetime import date, datetime
from enum import Enum
from typing import List, Optional

from pydantic import BaseModel, Field


# =======================================================================
# 1. FOOD SURPLUS PREDICTION
# =======================================================================

class FoodCategory(str, Enum):
    cooked = "cooked"
    bakery = "bakery"
    dairy = "dairy"
    packaged = "packaged"
    raw = "raw"


class SurplusPredictionRequest(BaseModel):
    food_prepared_kg: float = Field(..., gt=0, description="Quantity of food prepared, in kg")
    food_sold_kg: float = Field(..., ge=0, description="Quantity of food sold/consumed, in kg")
    food_category: FoodCategory
    day_of_week: str = Field(..., description="Monday, Tuesday, ... Sunday")
    date: date

    class Config:
        json_schema_extra = {
            "example": {
                "food_prepared_kg": 50,
                "food_sold_kg": 38,
                "food_category": "cooked",
                "day_of_week": "Friday",
                "date": "2026-08-28"
            }
        }


class SurplusPredictionResponse(BaseModel):
    model_config = {"protected_namespaces": ()}

    predicted_surplus_kg: float
    preparation_recommendation: str
    recommended_prepare_kg: float
    input_echo: SurplusPredictionRequest
    model_version: str = "v1"
    note: str = "Prediction is an estimate based on historical patterns; treat as a guideline."


# =======================================================================
# 2. NGO MATCHING ENGINE
# =======================================================================

class DietaryType(str, Enum):
    veg = "veg"
    non_veg = "non_veg"
    vegan = "vegan"
    any = "any"


class NGOInput(BaseModel):
    ngo_id: str
    name: str
    latitude: float
    longitude: float
    dietary_accepted: List[DietaryType]
    max_capacity_kg: float = Field(..., gt=0)
    min_capacity_kg: float = Field(0, ge=0)
    available_from: str = Field(..., description="HH:MM, 24-hour format")
    available_to: str = Field(..., description="HH:MM, 24-hour format")
    reliability_score: Optional[float] = Field(
        None, ge=0, le=100, description="NGO's own reliability/rating score (optional)"
    )


class DonationInput(BaseModel):
    donation_id: str
    restaurant_id: str
    restaurant_latitude: float
    restaurant_longitude: float
    quantity_kg: float = Field(..., gt=0)
    dietary_type: DietaryType
    pickup_time: str = Field(..., description="HH:MM, 24-hour format, when food will be ready")
    restaurant_reliability_score: float = Field(..., ge=0, le=100)


class MatchRequest(BaseModel):
    donation: DonationInput
    candidate_ngos: List[NGOInput]


class NGOScoreBreakdown(BaseModel):
    ngo_id: str
    ngo_name: str
    distance_km: float
    distance_source: str  # "road" (real GPS routing) or "straight_line" (fallback)
    distance_score: float
    quantity_fit_score: float
    dietary_compatibility_score: float
    pickup_time_feasibility_score: float
    restaurant_reliability_score: float
    final_score: float
    rank: int


class MatchResponse(BaseModel):
    donation_id: str
    ranked_ngos: List[NGOScoreBreakdown]
    weights_used: dict


# =======================================================================
# 3. AUTO-ESCALATION
# =======================================================================

class EscalationStatus(str, Enum):
    pending = "pending"
    accepted = "accepted"
    rejected = "rejected"
    timed_out = "timed_out"


class EscalationCheckRequest(BaseModel):
    donation_id: str
    ranked_ngo_ids: List[str] = Field(..., description="NGO ids in ranked order, best first")
    current_ngo_index: int = Field(0, ge=0, description="Index in ranked_ngo_ids currently offered")
    current_ngo_status: EscalationStatus
    offer_sent_at: datetime
    timeout_minutes: Optional[int] = Field(None, description="Override default timeout if needed")


class EscalationCheckResponse(BaseModel):
    donation_id: str
    action: str  # "keep_waiting" | "escalate" | "accepted" | "no_ngos_left"
    next_ngo_id: Optional[str] = None
    next_ngo_index: Optional[int] = None
    minutes_elapsed: float
    message: str


# =======================================================================
# 4. RESTAURANT RELIABILITY SCORING
# =======================================================================

class ReliabilityInput(BaseModel):
    restaurant_id: str
    total_donations_offered: int = Field(..., ge=0)
    total_donations_completed: int = Field(..., ge=0)
    total_donations_accepted: int = Field(..., ge=0)
    total_cancellations: int = Field(..., ge=0)
    average_ngo_rating: float = Field(..., ge=0, le=5, description="Average NGO rating out of 5")


class ReliabilityResponse(BaseModel):
    restaurant_id: str
    reliability_score: float
    grade: str
    breakdown: dict


# =======================================================================
# 5. FOOD SAFETY VERIFICATION
# =======================================================================

class SafetyVerdict(str, Enum):
    eligible = "Eligible"
    not_eligible = "Not Eligible"
    manual_review = "Requires Manual Review"


class SafetyCheckRequest(BaseModel):
    donation_id: str
    food_category: FoodCategory
    prepared_at: datetime
    storage_condition: str = Field(
        ..., description="e.g. 'refrigerated', 'room_temperature', 'hot_holding', 'frozen'"
    )
    donation_status: str = Field(
        "pending", description="e.g. 'pending', 'confirmed', 'cancelled'"
    )
    check_time: Optional[datetime] = Field(
        None, description="Time to check against; defaults to now if not supplied"
    )


class SafetyCheckResponse(BaseModel):
    donation_id: str
    verdict: SafetyVerdict
    hours_since_preparation: float
    reasons: List[str]


# =======================================================================
# 6. PDF DONATION ACKNOWLEDGMENT
# =======================================================================

class DonationAcknowledgmentRequest(BaseModel):
    donation_id: str
    restaurant_name: str
    ngo_name: str
    food_details: str
    quantity_kg: float
    donation_datetime: datetime
    completion_status: str = Field(..., description="e.g. 'Completed'")


class DonationAcknowledgmentResponse(BaseModel):
    donation_id: str
    pdf_filename: str
    file_path: str
    message: str
