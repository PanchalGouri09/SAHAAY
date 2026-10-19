"""Role-specific profile completeness rules for gated business actions."""

from __future__ import annotations

import re
from math import isfinite

from fastapi import HTTPException
from app.services.phone_number import normalize_indian_mobile_number

_TIME = re.compile(r"^(?:[01]\d|2[0-3]):[0-5]\d$")


def _first_row(value) -> dict:
    if isinstance(value, list):
        value = value[0] if value else None
    return value if isinstance(value, dict) else {}


def _nonempty(value) -> bool:
    return isinstance(value, str) and bool(value.strip())


def _valid_email(value) -> bool:
    text = value.strip() if isinstance(value, str) else ""
    return "@" in text and "." in text.rsplit("@", 1)[-1]


def _valid_phone(value) -> bool:
    return normalize_indian_mobile_number(value) is not None


def _valid_coordinates(row: dict) -> bool:
    try:
        latitude = float(row.get("latitude"))
        longitude = float(row.get("longitude"))
    except (TypeError, ValueError, OverflowError):
        return False
    return (
        isfinite(latitude)
        and isfinite(longitude)
        and -90 <= latitude <= 90
        and -180 <= longitude <= 180
    )


def _valid_hours(row: dict) -> bool:
    start = row.get("available_from")
    end = row.get("available_to")
    return (
        isinstance(start, str)
        and isinstance(end, str)
        and bool(_TIME.fullmatch(start))
        and bool(_TIME.fullmatch(end))
        and start != end
    )


def _valid_positive_number(value) -> bool:
    try:
        number = float(value)
    except (TypeError, ValueError, OverflowError):
        return False
    return isfinite(number) and number > 0


def _valid_string_list(value) -> bool:
    return (
        isinstance(value, list)
        and bool(value)
        and all(isinstance(item, str) and item.strip() for item in value)
    )


def ngo_matching_details_complete(ngo: dict) -> bool:
    """Whether saved NGO logistics can participate in donation matching."""
    return (
        _nonempty(ngo.get("organization_name"))
        and _nonempty(ngo.get("address"))
        and _nonempty(ngo.get("city"))
        and _valid_coordinates(ngo)
        and _valid_hours(ngo)
        and _valid_positive_number(ngo.get("max_capacity_kg"))
        and _valid_string_list(ngo.get("preferred_food_types"))
        and _valid_string_list(ngo.get("dietary_preferences"))
    )


def ngo_profile_is_complete(user: dict | None, ngo: dict) -> bool:
    """Use the canonical profile report as the NGO matching readiness check."""
    if not user:
        return False
    profile = {
        **user,
        "role": "ngo",
        "ngos": [ngo],
    }
    return profile_completion_report(profile)["complete"]


def profile_completion_report(profile: dict) -> dict:
    """Return a privacy-safe report containing labels, never stored values."""
    role = str(profile.get("role") or "")
    table = f"{role}s"
    account = profile
    role_row = _first_row(profile.get(table) or profile.get(role))
    if not role_row:
        nested = profile.get("profile")
        role_row = _first_row(nested)

    checks: list[tuple[str, bool]]
    if role == "provider":
        checks = [
            ("Contact name", _nonempty(account.get("full_name"))),
            ("Account email", _valid_email(account.get("email"))),
            (
                "Contact phone",
                _valid_phone(account.get("phone") or role_row.get("phone")),
            ),
            ("Organization name", _nonempty(role_row.get("organization_name"))),
            ("Pickup address", _nonempty(role_row.get("address"))),
            ("City", _nonempty(role_row.get("city"))),
            ("Pickup location coordinates", _valid_coordinates(role_row)),
        ]
    elif role == "ngo":
        checks = [
            ("Contact name", _nonempty(account.get("full_name"))),
            ("Account email", _valid_email(account.get("email"))),
            (
                "Contact phone",
                _valid_phone(account.get("phone") or role_row.get("phone")),
            ),
            ("Organization name", _nonempty(role_row.get("organization_name"))),
            ("Address", _nonempty(role_row.get("address"))),
            ("City", _nonempty(role_row.get("city"))),
            ("Location coordinates", _valid_coordinates(role_row)),
            ("Operating hours", _valid_hours(role_row)),
            (
                "Maximum donation capacity (kg)",
                _valid_positive_number(role_row.get("max_capacity_kg")),
            ),
            (
                "Preferred food types",
                _valid_string_list(role_row.get("preferred_food_types")),
            ),
            (
                "Dietary preferences",
                _valid_string_list(role_row.get("dietary_preferences")),
            ),
        ]
    else:
        checks = [
            ("Contact name", _nonempty(account.get("full_name"))),
            ("Account email", _valid_email(account.get("email"))),
            (
                "Contact phone",
                _valid_phone(account.get("phone") or role_row.get("phone")),
            ),
        ]

    completed = sum(1 for _, done in checks if done)
    missing = [label for label, done in checks if not done]
    return {
        "role": role,
        "complete": not missing,
        "completed_fields": completed,
        "total_fields": len(checks),
        "percentage": round(completed * 100 / len(checks)) if checks else 100,
        "missing_fields": missing,
    }


def require_complete_profile(profile: dict, *, action: str) -> None:
    """Reject protected actions without weakening normal profile access."""
    from fastapi import HTTPException

    report = profile_completion_report(profile)
    if report["complete"]:
        return
    missing = ", ".join(report["missing_fields"])
    raise HTTPException(
        status_code=409,
        detail=(
            f"Complete your {report['role']} profile before {action}. "
            f"Missing required fields: {missing}."
        ),
    )


def _email_is_verified(profile: dict, firebase_user: dict) -> bool:
    firebase_email = firebase_user.get("email")
    profile_email = profile.get("email")
    return (
        firebase_user.get("email_verified") is True
        and isinstance(firebase_email, str)
        and isinstance(profile_email, str)
        and firebase_email.strip().casefold() == profile_email.strip().casefold()
    )


def contact_verification_state(profile: dict, firebase_user: dict) -> dict:
    """Derive contact verification only from claims in a verified Firebase token."""
    from app.config import get_settings

    phone_number = normalize_indian_mobile_number(firebase_user.get("phone_number"))
    role = profile.get("role")
    role_row = _first_row(profile.get(f"{role}s") or profile.get(role))
    stored_phone = normalize_indian_mobile_number(
        profile.get("phone") or role_row.get("phone")
    )
    phone_verified = (
        phone_number is not None
        and stored_phone is not None
        and phone_number == stored_phone
    )

    return {
        "email_verified": _email_is_verified(profile, firebase_user),
        "phone_verified": phone_verified,
        "phone_auth_configured": get_settings().firebase_phone_auth_enabled,
    }


def require_verified_contacts(
    profile: dict, firebase_user: dict, *, action: str
) -> None:
    """Require trusted Firebase email and a linked phone claim for writes."""
    state = contact_verification_state(profile, firebase_user)
    missing = []
    if not state["email_verified"]:
        missing.append("verified email matching your SAHAAY account")
    if not state["phone_verified"]:
        missing.append("phone verified and linked to your Firebase account")
    if missing:
        raise HTTPException(
            status_code=403,
            detail=(
                f"Verify your {' and '.join(missing)} before {action}. "
                "Verification status is checked by the backend."
            ),
        )


def require_verified_email(profile: dict, firebase_user: dict, *, action: str) -> None:
    """Require the verified Firebase email to match the SAHAAY account."""
    if not _email_is_verified(profile, firebase_user):
        raise HTTPException(
            status_code=403,
            detail=(
                f"Verify the email matching your SAHAAY account before {action}. "
                "Verification status is checked by the backend."
            ),
        )
