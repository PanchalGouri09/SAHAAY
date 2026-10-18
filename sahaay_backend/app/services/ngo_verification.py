"""Server-side SAHAAY matching eligibility checks for NGO profiles."""

from __future__ import annotations

from datetime import datetime, timezone
from math import isfinite

from app.config import get_settings
from app.services.profile_completion import (
    contact_verification_state,
    profile_completion_report,
)
from app.services import notification_service


def _ngo_row(profile: dict) -> dict:
    value = profile.get("ngos") or profile.get("ngo")
    if isinstance(value, list):
        value = value[0] if value else None
    return value if isinstance(value, dict) else {}


def _valid_address_and_coordinates(ngo: dict) -> bool:
    address = ngo.get("address")
    city = ngo.get("city")
    if not isinstance(address, str) or not address.strip():
        return False
    if not isinstance(city, str) or not city.strip():
        return False
    try:
        latitude = float(ngo.get("latitude"))
        longitude = float(ngo.get("longitude"))
    except (TypeError, ValueError, OverflowError):
        return False
    return (
        isfinite(latitude)
        and isfinite(longitude)
        and -90 <= latitude <= 90
        and -180 <= longitude <= 180
    )


def assess_ngo_demo_verification(profile: dict, firebase_user: dict) -> dict:
    """Assess SAHAAY matching eligibility without changing legal verification."""
    ngo = _ngo_row(profile)
    report = profile_completion_report(profile)
    firebase_email = firebase_user.get("email")
    profile_email = profile.get("email")
    email_matches = (
        isinstance(firebase_email, str)
        and isinstance(profile_email, str)
        and firebase_email.strip().casefold() == profile_email.strip().casefold()
    )
    email_verified = firebase_user.get("email_verified") is True and email_matches
    contacts = contact_verification_state(profile, firebase_user)
    phone_otp_configured = get_settings().firebase_phone_auth_enabled
    phone_verified = contacts["phone_verified"]
    address_valid = _valid_address_and_coordinates(ngo)
    profile_complete = report["complete"] is True

    blockers: list[str] = []
    if not email_verified:
        if firebase_user.get("email_verified") is not True:
            blockers.append(
                "Verify the email address through the Firebase verification link."
            )
        else:
            blockers.append(
                "The verified Firebase email does not match the SAHAAY account email."
            )
    if not phone_otp_configured:
        blockers.append(
            "Phone verification is not enabled for this Firebase project; account eligibility remains pending."
        )
    elif not phone_verified:
        blockers.append(
            "Verify and link a phone number to this Firebase account."
        )
    if not address_valid:
        blockers.append(
            "Complete the address and choose a valid map location with coordinates."
        )
    if not profile_complete:
        blockers.extend(
            f"Complete the required profile field: {field}."
            for field in report["missing_fields"]
        )

    demo_verified = (
        email_verified
        and phone_otp_configured
        and phone_verified
        and address_valid
        and profile_complete
    )
    return {
        "status": "demo_verified" if demo_verified else "pending",
        "demo_verified": demo_verified,
        "production_verified": ngo.get("verified") is True,
        "label": (
            "Eligible for SAHAAY matching; this does not represent legal NGO "
            "verification."
        ),
        "checks": {
            "email_verified": email_verified,
            "phone_verified": phone_verified,
            "address_valid": address_valid,
            "profile_complete": profile_complete,
            "phone_otp": {
                "configured": phone_otp_configured,
                "required": True,
                "verified": phone_verified,
                "status": (
                    "verified"
                    if phone_verified
                    else "pending"
                    if phone_otp_configured
                    else "not_configured"
                ),
            },
        },
        "blockers": blockers,
        "phone_notice": (
            "Phone verification is enabled and checked through Firebase."
            if phone_otp_configured
            else (
                "Firebase phone verification is not enabled on the backend. "
                "A profile phone number is not treated as verified."
            )
        ),
    }


def update_demo_verification(client, ngo: dict, assessment: dict) -> dict:
    """Persist only server-computed matching eligibility, avoiding redundant writes."""
    ngo_id = ngo.get("id")
    if not ngo_id:
        return assessment

    desired = assessment["demo_verified"] is True
    current = ngo.get("demo_verified") is True
    if current == desired:
        return assessment

    updates: dict[str, object] = {
        "demo_verified": desired,
        "demo_verified_at": (
            datetime.now(timezone.utc).isoformat() if desired else None
        ),
    }
    response = (
        client.table("ngos")
        .update(updates)
        .eq("id", ngo_id)
        .eq("demo_verified", current)
        .select("id,demo_verified,demo_verified_at")
        .execute()
    )
    rows = getattr(response, "data", None) or []
    if not rows:
        latest = (
            client.table("ngos")
            .select("id,demo_verified,demo_verified_at")
            .eq("id", ngo_id)
            .maybe_single()
            .execute()
        )
        latest_row = getattr(latest, "data", None)
        if not latest_row or latest_row.get("demo_verified") is not desired:
            raise RuntimeError("NGO matching eligibility update affected no row.")
        ngo.update(latest_row)
        return assessment
    ngo.update(rows[0])
    notification_service.ngo_demo_verification_changed(
        client, ngo=ngo, verified=desired
    )
    return assessment
