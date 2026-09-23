"""
SAHAAY admin dashboard APIs.

Read-only, Firebase-authenticated views over the real schema. Every endpoint
requires the 'admin' role (provisioned separately - admins cannot
self-register), so non-admin callers are rejected before any data is read.

Honesty rules applied throughout:
* nothing here writes, updates, or deletes any row; the admin console is a
  read-only Phase 1 view.
* user records never expose firebase_uid or any credential: every select
  lists the public user columns explicitly, never select("*") on users.
* analytics convert only genuine weight units (kg / grams) to kilograms via
  the shared _quantity_kg helper - servings/plates are never treated as kg.
* redistributed weight is read from the real impact_records.food_weight_kg
  values recorded at delivery time, never re-derived from donation quantities.
* expiry is computed against the real expiry_time (the background
  expire_stale_donations job is not guaranteed to have run), and a missing or
  malformed expiry_time is never treated as "expired".
"""

from fastapi import APIRouter, Depends, HTTPException, Query

from app.dependencies import require_role
from app.routers.ai_features import _COMPLETED_DONATION_STATUSES, _quantity_kg
from app.services.escalation import is_expired
from app.supabase_client import get_supabase_client

router = APIRouter(prefix="/admin", tags=["admin"])

_ALLOWED_ROLES = {"provider", "ngo", "volunteer", "admin"}
_ACTIVE_DELIVERY_STATUSES = {"assigned", "accepted", "picked_up", "in_transit"}
_MAX_PAGE_SIZE = 100

_USER_PUBLIC_COLUMNS = (
    "id,full_name,email,phone,role,profile_image_url,created_at,updated_at"
)
_USER_EXPOSED_FIELDS = [
    "id",
    "full_name",
    "email",
    "phone",
    "role",
    "profile_image_url",
    "created_at",
    "updated_at",
]
_PROVIDER_COLUMNS = (
    "id,user_id,organization_name,organization_type,description,phone,address,"
    "city,latitude,longitude,verified,created_at,updated_at"
)
_NGO_COLUMNS = (
    "id,user_id,organization_name,registration_number,description,phone,address,"
    "city,latitude,longitude,food_capacity,preferred_food_types,verified,"
    "available_from,available_to,created_at,updated_at"
)
_VOLUNTEER_COLUMNS = (
    "id,user_id,availability_status,vehicle_type,current_latitude,"
    "current_longitude,verified,created_at,updated_at"
)
_DONATION_COLUMNS = (
    "id,provider_id,prediction_id,food_name,food_category,quantity,unit,"
    "servings,veg_type,description,food_image_url,prepared_at,expiry_time,"
    "pickup_deadline,pickup_address,latitude,longitude,status,created_at,"
    "updated_at,cancellation_reason,food_prepared_kg,food_sold_kg"
)
_CLAIM_COLUMNS = (
    "id,donation_id,ngo_id,requested_quantity,status,claimed_at,accepted_at,"
    "rejected_at,notes,created_at,updated_at,rejection_reason"
)
_DELIVERY_COLUMNS = (
    "id,donation_id,claim_id,volunteer_id,pickup_address,delivery_address,"
    "pickup_time,delivery_time,status,notes,created_at,updated_at,"
    "proof_of_delivery_url,failure_reason"
)
_PREDICTION_COLUMNS = (
    "id,prediction_date,recommendation,predicted_surplus,confidence_score"
)


def _public_user(row: dict) -> dict:
    return {field: row.get(field) for field in _USER_EXPOSED_FIELDS}


def _count(client, table: str, *, role: str | None = None) -> int:
    query = client.table(table).select("id")
    if role is not None:
        query = query.eq("role", role)
    return len(query.execute().data or [])


def _page_response(
    client, table: str, columns: str, *, page: int, page_size: int, role: str | None = None
) -> dict:
    total = _count(client, table, role=role)
    start = (page - 1) * page_size
    end = start + page_size - 1
    query = client.table(table).select(columns)
    if role is not None:
        query = query.eq("role", role)
    rows = query.order("created_at", desc=True).range(start, end).execute().data or []
    return {"total": total, "page": page, "page_size": page_size, "items": rows}


def _attach_user_labels(client, rows: list[dict], *, user_id_key: str = "user_id") -> list[dict]:
    ids = sorted({row[user_id_key] for row in rows if row.get(user_id_key)})
    if not ids:
        return rows
    users = client.table("users").select(_USER_PUBLIC_COLUMNS).in_("id", ids).execute().data or []
    by_id = {user["id"]: user for user in users}
    for row in rows:
        user = by_id.get(row.get(user_id_key))
        if user:
            row["user_full_name"] = user.get("full_name")
            row["user_email"] = user.get("email")
            row["user_phone"] = user.get("phone")
    return rows


def _providers_by_id(client, provider_ids) -> dict:
    ids = sorted(provider_ids)
    if not ids:
        return {}
    providers = client.table("providers").select(_PROVIDER_COLUMNS).in_("id", ids).execute().data or []
    return {provider["id"]: provider for provider in providers}


def _predictions_by_id(client, prediction_ids) -> dict:
    ids = sorted(prediction_ids)
    if not ids:
        return {}
    predictions = (
        client.table("food_predictions")
        .select(_PREDICTION_COLUMNS)
        .in_("id", ids)
        .execute().data
        or []
    )
    return {prediction["id"]: prediction for prediction in predictions}


def _enrich_donations(client, donations: list[dict]) -> list[dict]:
    providers = _providers_by_id(
        client, {d["provider_id"] for d in donations if d.get("provider_id")}
    )
    predictions = _predictions_by_id(
        client, {d["prediction_id"] for d in donations if d.get("prediction_id")}
    )
    for donation in donations:
        provider = providers.get(donation.get("provider_id"))
        if provider:
            donation["provider"] = provider
        prediction = predictions.get(donation.get("prediction_id"))
        if prediction:
            donation["prediction"] = prediction
    return donations


def _attach_claim_context(client, claims_rows: list[dict]) -> list[dict]:
    donation_ids = sorted({c["donation_id"] for c in claims_rows if c.get("donation_id")})
    ngo_ids = sorted({c["ngo_id"] for c in claims_rows if c.get("ngo_id")})
    donation_by_id = {}
    if donation_ids:
        donations = (
            client.table("donations").select(_DONATION_COLUMNS).in_("id", donation_ids).execute().data or []
        )
        donation_by_id = {d["id"]: d for d in donations}
        _enrich_donations(client, list(donation_by_id.values()))
    ngo_by_id = {}
    if ngo_ids:
        ngos = client.table("ngos").select(_NGO_COLUMNS).in_("id", ngo_ids).execute().data or []
        ngo_by_id = {ngo["id"]: ngo for ngo in ngos}
    for claim in claims_rows:
        donation = donation_by_id.get(claim.get("donation_id"))
        if donation:
            claim["donation"] = donation
        ngo = ngo_by_id.get(claim.get("ngo_id"))
        if ngo:
            claim["ngo"] = ngo
    return claims_rows


def _attach_delivery_context(client, deliveries_rows: list[dict]) -> list[dict]:
    donation_ids = sorted({d["donation_id"] for d in deliveries_rows if d.get("donation_id")})
    claim_ids = sorted({d["claim_id"] for d in deliveries_rows if d.get("claim_id")})
    volunteer_ids = sorted({d["volunteer_id"] for d in deliveries_rows if d.get("volunteer_id")})
    donation_by_id = {}
    if donation_ids:
        donations = (
            client.table("donations").select(_DONATION_COLUMNS).in_("id", donation_ids).execute().data or []
        )
        donation_by_id = {d["id"]: d for d in donations}
        _enrich_donations(client, list(donation_by_id.values()))
    claim_by_id = {}
    ngo_by_id = {}
    if claim_ids:
        claims = (
            client.table("claims")
            .select("id,donation_id,ngo_id,status")
            .in_("id", claim_ids)
            .execute().data
            or []
        )
        claim_by_id = {c["id"]: c for c in claims}
        ngo_ids = sorted({c["ngo_id"] for c in claim_by_id.values() if c.get("ngo_id")})
        if ngo_ids:
            ngos = client.table("ngos").select(_NGO_COLUMNS).in_("id", ngo_ids).execute().data or []
            ngo_by_id = {ngo["id"]: ngo for ngo in ngos}
    volunteer_by_id = {}
    if volunteer_ids:
        volunteers = (
            client.table("volunteers").select(_VOLUNTEER_COLUMNS).in_("id", volunteer_ids).execute().data or []
        )
        volunteer_by_id = {v["id"]: v for v in volunteers}
    for delivery in deliveries_rows:
        donation = donation_by_id.get(delivery.get("donation_id"))
        if donation:
            delivery["donation"] = donation
        claim = claim_by_id.get(delivery.get("claim_id"))
        if claim:
            delivery["claim"] = claim
            ngo = ngo_by_id.get(claim.get("ngo_id"))
            if ngo:
                delivery["ngo"] = ngo
        volunteer = volunteer_by_id.get(delivery.get("volunteer_id"))
        if volunteer:
            delivery["volunteer"] = volunteer
    return deliveries_rows


def _admin_page_params(
    page: int = Query(default=1, ge=1),
    page_size: int = Query(default=20, ge=1, le=_MAX_PAGE_SIZE),
) -> tuple[int, int]:
    return page, page_size


@router.get("/summary")
def admin_summary(profile: dict = Depends(require_role("admin"))) -> dict:
    client = get_supabase_client()
    donations = client.table("donations").select("id,status").execute().data or []
    claims = client.table("claims").select("id,status").execute().data or []
    deliveries = client.table("deliveries").select("id,status").execute().data or []
    return {
        "total_users": _count(client, "users"),
        "providers": _count(client, "providers"),
        "ngos": _count(client, "ngos"),
        "volunteers": _count(client, "volunteers"),
        "total_donations": len(donations),
        "completed_redistributions": sum(
            1 for d in donations if d.get("status") in _COMPLETED_DONATION_STATUSES
        ),
        "pending_claims": sum(1 for c in claims if c.get("status") == "pending"),
        "active_deliveries": sum(
            1 for d in deliveries if d.get("status") in _ACTIVE_DELIVERY_STATUSES
        ),
    }


@router.get("/users")
def admin_list_users(
    page: int = Query(default=1, ge=1),
    page_size: int = Query(default=20, ge=1, le=_MAX_PAGE_SIZE),
    role: str | None = Query(default=None),
    profile: dict = Depends(require_role("admin")),
) -> dict:
    if role is not None and role not in _ALLOWED_ROLES:
        raise HTTPException(
            status_code=422,
            detail="role must be one of: provider, ngo, volunteer, admin.",
        )
    response = _page_response(
        get_supabase_client(), "users", _USER_PUBLIC_COLUMNS, page=page, page_size=page_size, role=role
    )
    response["items"] = [_public_user(row) for row in response["items"]]
    return response


@router.get("/providers")
def admin_list_providers(
    page: int = Query(default=1, ge=1),
    page_size: int = Query(default=20, ge=1, le=_MAX_PAGE_SIZE),
    profile: dict = Depends(require_role("admin")),
) -> dict:
    client = get_supabase_client()
    response = _page_response(client, "providers", _PROVIDER_COLUMNS, page=page, page_size=page_size)
    response["items"] = _attach_user_labels(client, response["items"])
    return response


@router.get("/ngos")
def admin_list_ngos(
    page: int = Query(default=1, ge=1),
    page_size: int = Query(default=20, ge=1, le=_MAX_PAGE_SIZE),
    profile: dict = Depends(require_role("admin")),
) -> dict:
    client = get_supabase_client()
    response = _page_response(client, "ngos", _NGO_COLUMNS, page=page, page_size=page_size)
    response["items"] = _attach_user_labels(client, response["items"])
    return response


@router.get("/volunteers")
def admin_list_volunteers(
    page: int = Query(default=1, ge=1),
    page_size: int = Query(default=20, ge=1, le=_MAX_PAGE_SIZE),
    profile: dict = Depends(require_role("admin")),
) -> dict:
    client = get_supabase_client()
    response = _page_response(client, "volunteers", _VOLUNTEER_COLUMNS, page=page, page_size=page_size)
    response["items"] = _attach_user_labels(client, response["items"])
    return response


@router.get("/donations")
def admin_list_donations(
    page: int = Query(default=1, ge=1),
    page_size: int = Query(default=20, ge=1, le=_MAX_PAGE_SIZE),
    profile: dict = Depends(require_role("admin")),
) -> dict:
    client = get_supabase_client()
    response = _page_response(client, "donations", _DONATION_COLUMNS, page=page, page_size=page_size)
    response["items"] = _enrich_donations(client, response["items"])
    return response


@router.get("/claims")
def admin_list_claims(
    page: int = Query(default=1, ge=1),
    page_size: int = Query(default=20, ge=1, le=_MAX_PAGE_SIZE),
    profile: dict = Depends(require_role("admin")),
) -> dict:
    client = get_supabase_client()
    response = _page_response(client, "claims", _CLAIM_COLUMNS, page=page, page_size=page_size)
    response["items"] = _attach_claim_context(client, response["items"])
    return response


@router.get("/deliveries")
def admin_list_deliveries(
    page: int = Query(default=1, ge=1),
    page_size: int = Query(default=20, ge=1, le=_MAX_PAGE_SIZE),
    profile: dict = Depends(require_role("admin")),
) -> dict:
    client = get_supabase_client()
    response = _page_response(client, "deliveries", _DELIVERY_COLUMNS, page=page, page_size=page_size)
    response["items"] = _attach_delivery_context(client, response["items"])
    return response


@router.get("/analytics")
def admin_analytics(profile: dict = Depends(require_role("admin"))) -> dict:
    client = get_supabase_client()
    donations = (
        client.table("donations")
        .select("id,status,quantity,unit,servings,expiry_time")
        .execute().data
        or []
    )
    donated_kg = 0.0
    expired_count = 0
    unclaimed_available = 0
    successful_redistributions = 0
    for donation in donations:
        kg = _quantity_kg(donation)
        if kg is not None:
            donated_kg += kg
        status = donation.get("status")
        if status in _COMPLETED_DONATION_STATUSES:
            successful_redistributions += 1
        if status == "expired" or (status == "available" and is_expired(donation)):
            expired_count += 1
        if status == "available" and not is_expired(donation):
            unclaimed_available += 1

    impact = client.table("impact_records").select("food_weight_kg").execute().data or []
    redistributed_kg = sum(
        float(row["food_weight_kg"]) for row in impact if row.get("food_weight_kg") is not None
    )

    deliveries = client.table("deliveries").select("id,status").execute().data or []
    completed_deliveries = sum(1 for d in deliveries if d.get("status") == "delivered")

    return {
        "total_food_donated_kg": round(donated_kg, 2),
        "total_food_redistributed_kg": round(redistributed_kg, 2),
        "expired_donations": expired_count,
        "unclaimed_available_donations": unclaimed_available,
        "successful_redistributions": successful_redistributions,
        "completed_deliveries": completed_deliveries,
    }