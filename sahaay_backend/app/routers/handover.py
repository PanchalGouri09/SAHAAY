"""Server-side handover verification for claimed donations.

The claimed-donation screen used to generate a random 4-digit code in the
Flutter client and "verify" it against itself — any client could declare a
handover complete without backend involvement. These endpoints move the whole
lifecycle server-side:

    GET    /api/v1/donations/{donation_id}/handover        -> current state
    POST   /api/v1/donations/{donation_id}/handover/code   -> generate code
    POST   /api/v1/donations/{donation_id}/handover/verify -> validate code
    POST   /api/v1/donations/{donation_id}/handover/photo  -> store proof photo

Design notes:
  * Code generation, state reads and proof-photo uploads are `require_role("ngo")`
    and resolve the claim from (donation_id, ngo_id-from-token). No claim id,
    user id or organisation id ever comes from the request, so an NGO can only
    ever act on its own claims.
  * Verification is `require_any_role("provider", "ngo")`: either the receiving
    NGO (who generated the code) or the donating provider may submit it. The
    claim is still resolved from the token — a provider only ever matches a
    donation they own — so neither party can verify someone else's handover.
  * The code is a 4-digit value returned ONCE to the requester, stored only as
    a salted-per-claim SHA-256 hash with a 10-minute expiry and a 10-attempt
    lock, so a leaked database row does not reveal live codes and brute force
    is bounded.
  * Verification is what records the handover (`handover_verified_at`);
    nothing else in the claim/donation lifecycle is changed by these routes,
    and no notification triggers are added.
  * Delivery of the code (SMS/WhatsApp gateway) is NOT implemented — this
    project has no messaging provider. The code is returned to the requesting
    client to be shared with the person receiving the food. That limitation is
    documented here rather than hidden behind a fake gateway.
  * The proof photo is uploaded with the same byte-level image validation used
    for food photos and persisted onto claims.handover_photo_url, so it
    survives an app restart.
"""

import hashlib
import secrets
from datetime import datetime, timedelta, timezone
from uuid import uuid4

from fastapi import APIRouter, Depends, File, HTTPException, UploadFile

from app.config import get_settings
from app.dependencies import (
    get_current_firebase_user,
    require_any_role,
    require_any_role,
    require_role,
)
from app.routers.donations import (
    _EXTENSION_MIME,
    _IMAGE_EXTENSIONS,
    _ensure_storage_bucket,
    _extension_of_filename,
    _sniff_image_kind,
)
from app.schemas.donation import HandoverVerifyRequest
from app.services import acknowledgment, notification_service
from app.services.profile_completion import (
    require_verified_contacts,
    require_verified_email,
)
from app.services.volunteer_transport import is_live_claim_status
from app.supabase_client import get_supabase_client

router = APIRouter(prefix="/donations", tags=["handover"])

# How long a generated code stays valid, and how many wrong attempts are
# tolerated before the code is locked. Both are deliberately conservative:
# the code is short, so brute force must be bounded.
CODE_TTL_MINUTES = 10
MAX_VERIFY_ATTEMPTS = 10


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _role_row(profile: dict, role: str) -> dict:
    rows = profile.get(f"{role}s")
    row = rows[0] if isinstance(rows, list) and rows else rows
    if not row:
        raise HTTPException(status_code=404, detail=f"{role.title()} profile not found.")
    return row

def _parse_ts(value) -> datetime | None:
    """Supabase returns timestamptz as an ISO-8601 string (sometimes with a
    trailing 'Z'); returns None for anything unparseable so callers treat it
    as 'expired/unknown' rather than crashing."""
    if isinstance(value, datetime):
        return value if value.tzinfo else value.replace(tzinfo=timezone.utc)
    if not value:
        return None
    try:
        parsed = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except ValueError:
        return None
    return parsed if parsed.tzinfo else parsed.replace(tzinfo=timezone.utc)


def _hash_code(claim_id: str, code: str) -> str:
    # Per-claim salt: identical codes on different claims hash differently.
    return hashlib.sha256(f"{claim_id}:{code}".encode()).hexdigest()


def _get_claim(profile: dict, donation_id: str) -> dict:
    """Resolve the claim strictly from the authenticated account and donation."""
    client = get_supabase_client()
    role = profile.get("role")
    query = client.table("claims").select("*").eq("donation_id", str(donation_id))
    if role == "ngo":
        query = query.eq("ngo_id", _role_row(profile, "ngo")["id"])
    elif role == "provider":
        provider_id = _role_row(profile, "provider")["id"]
        donation = (client.table("donations").select("id,provider_id")
                    .eq("id", str(donation_id)).maybe_single().execute())
        row = getattr(donation, "data", None) or {}
        if str(row.get("provider_id")) != str(provider_id):
            raise HTTPException(status_code=404, detail="No matching donation found.")
    else:
        raise HTTPException(status_code=403, detail="Provider or NGO access is required.")
    rows = getattr(query.order("created_at", desc=True).execute(), "data", None) or []
    if not rows:
        raise HTTPException(status_code=404, detail="No claim found for this donation.")
    # Prefer the currently accepted claim when a donation has older claim rows.
    for candidate in rows:
        if candidate.get("status") == "accepted":
            return candidate
    for candidate in rows:
        if candidate.get("handover_verified_at"):
            return candidate
    for candidate in rows:
        if is_live_claim_status(candidate.get("status")):
            return candidate
    return rows[0]


def _reject_if_claim_closed(claim: dict) -> None:
    if claim.get("status") != "accepted":
        raise HTTPException(
            status_code=409,
            detail="An accepted claim is required for handover.",
        )


def _rpc_result(response) -> dict:
    result = getattr(response, "data", None)
    if isinstance(result, list) and len(result) == 1:
        result = result[0]
    if not isinstance(result, dict) or not isinstance(result.get("status"), str):
        raise HTTPException(
            status_code=502,
            detail="The database returned an invalid handover result.",
        )
    return result


def _has_active_code(claim: dict) -> bool:
    if not claim.get("handover_code_hash"):
        return False
    expires = _parse_ts(claim.get("handover_code_expires_at"))
    return expires is not None and expires > _now()


def _handover_state(claim: dict, receipt_ready: bool = False) -> dict:
    return {
        "claim_id": str(claim["id"]),
        "receipt_ready": receipt_ready,
        "handover_verified": claim.get("handover_verified_at") is not None,
        "handover_verified_at": claim.get("handover_verified_at"),
        "handover_photo_url": claim.get("handover_photo_url"),
        "has_active_code": _has_active_code(claim),
        "handover_code_expires_at": claim.get("handover_code_expires_at"),
        "code_ttl_minutes": CODE_TTL_MINUTES,
        "max_verify_attempts": MAX_VERIFY_ATTEMPTS,
    }


@router.get("/{donation_id}/handover")
def get_handover_state(
    donation_id: str,
    profile: dict = Depends(require_any_role("ngo", "provider")),
) -> dict:
    """Current handover state for either authorized claim participant.

    Read-only: opening the claimed-donation screen never mints or resets a
    code — that only happens on an explicit POST to /handover/code.
    """
    claim = _get_claim(profile, donation_id)
    receipt = (get_supabase_client().table("donations")
               .select("acknowledgment_pdf_url").eq("id", str(donation_id)).maybe_single().execute())
    receipt_ready = bool((getattr(receipt, "data", None) or {}).get("acknowledgment_pdf_url"))
    return _handover_state(claim, receipt_ready)


@router.post("/{donation_id}/handover/code")
def generate_handover_code(
    donation_id: str,
    profile: dict = Depends(require_role("ngo")),
    firebase_user: dict = Depends(get_current_firebase_user),
) -> dict:
    """Generates a fresh handover code for the calling NGO's claim.

    An unexpired code cannot be replaced, so concurrent requests cannot hand
    out different plaintext codes while only one hash remains valid. The
    plaintext is returned exactly once — only its hash is stored.
    """
    claim = _get_claim(profile, donation_id)
    _reject_if_claim_closed(claim)
    require_verified_email(profile, firebase_user, action="generate a handover code")
    if claim.get("handover_verified_at"):
        raise HTTPException(
            status_code=409, detail="Handover for this claim is already verified."
        )

    code = f"{secrets.randbelow(10000):04d}"
    expires_at = _now() + timedelta(minutes=CODE_TTL_MINUTES)
    client = get_supabase_client()
    result = _rpc_result(
        client.rpc(
            "issue_donation_handover_code",
            {
                "p_claim_id": str(claim["id"]),
                "p_donation_id": str(donation_id),
                "p_code_hash": _hash_code(str(claim["id"]), code),
                "p_expires_at": expires_at.isoformat(),
            },
        ).execute()
    )
    if result["status"] == "active_code":
        raise HTTPException(
            status_code=409,
            detail="A handover code is already active. Use it or wait for it to expire.",
        )
    if result["status"] == "already_verified":
        raise HTTPException(
            status_code=409, detail="Handover for this claim is already verified."
        )
    if result["status"] in {"claim_closed", "invalid_request"}:
        raise HTTPException(status_code=409, detail="This claim is not eligible for a handover code.")
    if result["status"] in {"claim_not_found", "donation_not_found"}:
        raise HTTPException(status_code=404, detail="No matching donation claim found.")
    if result["status"] != "issued":
        raise HTTPException(status_code=502, detail="The database could not issue a handover code.")
    updates = {
        "handover_code_hash": _hash_code(str(claim["id"]), code),
        "handover_code_expires_at": expires_at.isoformat(),
        "handover_code_attempts": 0,
        "updated_at": _now().isoformat(),
    }
    return {
        **_handover_state({**claim, **updates}),
        "handover_code": code,
        "expires_at": expires_at.isoformat(),
    }


@router.post("/{donation_id}/handover/verify")
def verify_handover_code(
    donation_id: str,
    payload: HandoverVerifyRequest,
    profile: dict = Depends(require_any_role("provider", "ngo")),
    firebase_user: dict = Depends(get_current_firebase_user),
) -> dict:
    """Validates the entered code against the stored hash.

    Failure modes are explicit and never recorded as a verified handover:
    expired/absent code -> 410, wrong code -> 400 with remaining attempts,
    attempt limit reached -> 429 with the code locked. Success is the ONLY
    thing that writes `handover_verified_at`.
    """
    claim = _get_claim(profile, donation_id)
    if claim.get("status") != "completed":
        _reject_if_claim_closed(claim)
    require_verified_email(profile, firebase_user, action="verify a handover")
    client = get_supabase_client()
    result = _rpc_result(
        client.rpc(
            "verify_donation_handover",
            {
                "p_claim_id": str(claim["id"]),
                "p_donation_id": str(donation_id),
                "p_candidate_hash": _hash_code(
                    str(claim["id"]), payload.code.strip()
                ),
            },
        ).execute()
    )
    if result["status"] == "expired":
        raise HTTPException(
            status_code=410,
            detail="This handover code has expired. Generate a new one.",
        )
    if result["status"] == "locked":
        raise HTTPException(
            status_code=429,
            detail="Too many wrong attempts. Generate a new handover code.",
        )
    if result["status"] == "wrong_code":
        raise HTTPException(
            status_code=400,
            detail=(
                "That handover code is not correct. "
                f"{result.get('remaining_attempts', 0)} attempt(s) remaining."
            ),
        )
    if result["status"] in {"claim_closed", "invalid_request"}:
        raise HTTPException(
            status_code=409,
            detail="This claim is no longer eligible for handover verification.",
        )
    if result["status"] in {"claim_not_found", "donation_not_found"}:
        raise HTTPException(status_code=404, detail="No matching donation claim found.")
    if result["status"] not in {"verified", "already_verified"}:
        raise HTTPException(status_code=502, detail="The database could not verify handover.")

    already_verified = result["status"] == "already_verified"
    now_iso = result.get("verified_at") or claim.get("handover_verified_at")
    if not now_iso:
        raise HTTPException(
            status_code=502,
            detail="The database did not return the handover verification time.",
        )
    client = get_supabase_client()
    completed_claim = {
        **claim,
        "status": "completed",
        "handover_verified_at": now_iso,
        "handover_code_hash": None,
        "handover_code_expires_at": None,
        "handover_code_attempts": 0,
    }
    donation_response = (
        client.table("donations")
        .select("*")
        .eq("id", str(donation_id))
        .maybe_single()
        .execute()
    )
    donation = getattr(donation_response, "data", None)

    # The successful code entry is the physical completion event. Generate and
    # persist the same receipt the history screens will download.
    outcome = (
        acknowledgment.auto_generate_acknowledgment(client, donation_id)
        if donation
        else None
    )

    # Successful verification notifies both real participants. When the
    # persisted receipt is also ready, both receive the existing receipt-ready
    # event as well.
    notification_service.handover_verified(
        client, donation=donation, claim=completed_claim
    )
    if outcome and outcome.get("persisted"):
        notification_service.acknowledgment_ready(
            client,
            donation=outcome.get("donation") or donation,
            claim=completed_claim,
        )
    else:
        # Verification truly succeeded but the receipt could not be persisted
        # yet. Both real participants are told the donation is completed and
        # that the receipt is still being prepared, instead of silently
        # leaving them without any signal.
        notification_service.handover_completed(
            client, donation=donation, claim=completed_claim
        )

    return {
        "claim_id": str(claim["id"]),
        "handover_verified": True,
        "handover_verified_at": now_iso,
        "handover_photo_url": claim.get("handover_photo_url"),
        "acknowledgment_ready": bool(outcome and outcome.get("persisted")),
        "already_verified": already_verified,
        "has_active_code": False,
    }


@router.post("/{donation_id}/handover/photo")
def upload_handover_photo(
    donation_id: str,
    file: UploadFile = File(...),
    profile: dict = Depends(require_role("ngo")),
    firebase_user: dict = Depends(get_current_firebase_user),
) -> dict:
    """Stores the physical-handover proof photo against the calling NGO's claim.

    Same byte-level image validation as food photos; the public URL is
    persisted to claims.handover_photo_url in this same request so the photo
    is re-displayed after an app restart.
    """
    claim = _get_claim(profile, donation_id)
    _reject_if_claim_closed(claim)
    require_verified_contacts(profile, firebase_user, action="upload handover proof")

    data = file.file.read()
    max_bytes = get_settings().max_food_photo_size_mb * 1024 * 1024
    if len(data) > max_bytes:
        raise HTTPException(
            status_code=413,
            detail=(
                f"Handover photo is too large. Maximum size is "
                f"{get_settings().max_food_photo_size_mb} MB."
            ),
        )

    ext, mime = _sniff_image_kind(data)
    if ext is None:
        content_type = (file.content_type or "").lower()
        ext = _IMAGE_EXTENSIONS.get(content_type)
        mime = content_type if ext is None or "image" in content_type else None
    if ext is None:
        ext = _extension_of_filename(file.filename)
        mime = _EXTENSION_MIME.get(ext) if ext else None
    if ext is None:
        raise HTTPException(
            status_code=415,
            detail="Handover photos must be PNG, JPEG, WebP, HEIC, or HEIF images.",
        )
    uploaded_mime = mime or _EXTENSION_MIME.get(ext, "application/octet-stream")

    client = get_supabase_client()
    bucket = get_settings().supabase_storage_bucket
    path = f"handover-photos/{claim['id']}/{uuid4().hex}.{ext}"
    try:
        _ensure_storage_bucket(client, bucket)
        client.storage.from_(bucket).upload(
            path,
            data,
            file_options={"content-type": uploaded_mime},
        )
        url = client.storage.from_(bucket).get_public_url(path)
    except HTTPException:
        raise
    except Exception as exc:
        raise HTTPException(
            status_code=502,
            detail="Handover photo could not be saved. Please try again.",
        ) from exc

    client.table("claims").update(
        {"handover_photo_url": url, "updated_at": _now().isoformat()}
    ).eq("id", claim["id"]).execute()
    return {"handover_photo_url": url, "claim_id": str(claim["id"])}
