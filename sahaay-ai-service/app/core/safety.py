"""
Rule-based food safety verification.

This is intentionally rule-based (not ML) because food safety decisions
need to be transparent and explainable — the API always returns the
specific reasons behind a verdict.

Verdicts:
  - Eligible              : food passes all safety rules
  - Not Eligible           : food fails a hard safety rule (auto-rejected)
  - Requires Manual Review : borderline case, a human should check
"""

from datetime import datetime, timezone

from app.config import SAFETY_HARD_REJECT_HOURS, SAFETY_MANUAL_REVIEW_HOURS
from app.models.schemas import SafetyCheckRequest, SafetyCheckResponse, SafetyVerdict

# Storage conditions considered acceptable for donation at all.
UNSAFE_STORAGE_CONDITIONS = {"unrefrigerated_perishable", "spoiled", "unknown"}

# Donation statuses that immediately disqualify a donation regardless of food state.
DISQUALIFYING_STATUSES = {"cancelled", "rejected", "expired"}


def check_food_safety(payload: SafetyCheckRequest) -> SafetyCheckResponse:
    reasons = []

    check_time = payload.check_time or datetime.now(timezone.utc)
    prepared_at = payload.prepared_at

    # normalize timezone-awareness so subtraction never crashes
    if prepared_at.tzinfo is None:
        prepared_at = prepared_at.replace(tzinfo=timezone.utc)
    if check_time.tzinfo is None:
        check_time = check_time.replace(tzinfo=timezone.utc)

    hours_since_prep = round((check_time - prepared_at).total_seconds() / 3600.0, 2)

    category = payload.food_category.value
    hard_limit = SAFETY_HARD_REJECT_HOURS.get(category, SAFETY_HARD_REJECT_HOURS["default"])
    review_limit = SAFETY_MANUAL_REVIEW_HOURS.get(category, SAFETY_MANUAL_REVIEW_HOURS["default"])

    verdict = SafetyVerdict.eligible

    # --- Rule 1: donation status ---
    if payload.donation_status.lower() in DISQUALIFYING_STATUSES:
        verdict = SafetyVerdict.not_eligible
        reasons.append(f"Donation status '{payload.donation_status}' disqualifies it from being offered.")

    # --- Rule 2: negative time since preparation (data error) ---
    if hours_since_prep < 0:
        verdict = SafetyVerdict.manual_review
        reasons.append("Preparation time is in the future relative to check time — please verify the timestamp.")

    # --- Rule 3: storage condition ---
    if payload.storage_condition.lower() in UNSAFE_STORAGE_CONDITIONS:
        verdict = SafetyVerdict.not_eligible
        reasons.append(f"Storage condition '{payload.storage_condition}' is unsafe for donation.")

    # --- Rule 4: time-since-preparation thresholds (only if not already hard-rejected) ---
    if verdict != SafetyVerdict.not_eligible and hours_since_prep >= 0:
        if hours_since_prep > hard_limit:
            verdict = SafetyVerdict.not_eligible
            reasons.append(
                f"Food was prepared {hours_since_prep} hour(s) ago, exceeding the "
                f"{hard_limit}-hour safety limit for '{category}' food."
            )
        elif hours_since_prep > review_limit:
            if verdict != SafetyVerdict.not_eligible:
                verdict = SafetyVerdict.manual_review
            reasons.append(
                f"Food was prepared {hours_since_prep} hour(s) ago, which is past the "
                f"{review_limit}-hour comfortable window for '{category}' food but still "
                f"within the {hard_limit}-hour hard limit. A human should confirm freshness."
            )

    # --- Rule 5: dairy/raw food always flagged for review if stored at room temperature ---
    if category in ("dairy", "raw") and payload.storage_condition.lower() == "room_temperature":
        if verdict == SafetyVerdict.eligible:
            verdict = SafetyVerdict.manual_review
        reasons.append(f"'{category}' food stored at room temperature needs manual confirmation of freshness.")

    if not reasons:
        reasons.append("All safety checks passed: preparation time, storage, and status are within safe limits.")

    return SafetyCheckResponse(
        donation_id=payload.donation_id,
        verdict=verdict,
        hours_since_preparation=hours_since_prep,
        reasons=reasons,
    )
