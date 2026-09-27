"""
Restaurant reliability scoring.

Produces a score out of 100 based on:
  - completion rate   (completed / offered)
  - average NGO rating (0-5 scale)
  - cancellation penalty (inverse of cancellation rate)
  - acceptance rate   (accepted / offered)

Weights are defined in app/config.py (RELIABILITY_WEIGHTS) and must
sum to 100.
"""

from app.config import RELIABILITY_WEIGHTS
from app.models.schemas import ReliabilityInput, ReliabilityResponse


def _safe_ratio(numerator: int, denominator: int) -> float:
    if denominator <= 0:
        return 0.0
    return numerator / denominator


def _grade_from_score(score: float) -> str:
    if score >= 85:
        return "Excellent"
    if score >= 70:
        return "Good"
    if score >= 50:
        return "Average"
    if score >= 30:
        return "Below Average"
    return "Poor"


def calculate_reliability(payload: ReliabilityInput) -> ReliabilityResponse:
    offered = payload.total_donations_offered

    completion_rate = _safe_ratio(payload.total_donations_completed, offered)
    acceptance_rate = _safe_ratio(payload.total_donations_accepted, offered)
    cancellation_rate = _safe_ratio(payload.total_cancellations, offered)

    completion_component = completion_rate * RELIABILITY_WEIGHTS["completion_rate"]
    rating_component = (payload.average_ngo_rating / 5.0) * RELIABILITY_WEIGHTS["avg_ngo_rating"]
    cancellation_component = (1 - cancellation_rate) * RELIABILITY_WEIGHTS["cancellation_penalty"]
    acceptance_component = acceptance_rate * RELIABILITY_WEIGHTS["acceptance_rate"]

    total_score = round(
        completion_component + rating_component + cancellation_component + acceptance_component,
        2,
    )
    total_score = max(0.0, min(100.0, total_score))

    return ReliabilityResponse(
        restaurant_id=payload.restaurant_id,
        reliability_score=total_score,
        grade=_grade_from_score(total_score),
        breakdown={
            "completion_rate_pct": round(completion_rate * 100, 2),
            "completion_component": round(completion_component, 2),
            "acceptance_rate_pct": round(acceptance_rate * 100, 2),
            "acceptance_component": round(acceptance_component, 2),
            "cancellation_rate_pct": round(cancellation_rate * 100, 2),
            "cancellation_component": round(cancellation_component, 2),
            "avg_ngo_rating": payload.average_ngo_rating,
            "rating_component": round(rating_component, 2),
        },
    )
