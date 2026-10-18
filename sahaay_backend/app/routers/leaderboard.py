"""
Public Impact Leaderboard API (FR-19).

Ranks opted-in organizations (providers and NGOs) by the food weight that the
`impact_records` table genuinely recorded for their completed donations.

Honesty rules applied throughout:
* an organization appears ONLY when its owning `users.leaderboard_public` flag
  is true (visibility is opt-in; the column defaults to false) AND it has at
  least one real recorded impact row - no placeholder, seed or demo entries.
* every number is read straight from `impact_records` (`food_weight_kg`,
  `meals_rescued`, `estimated_co2_saved`); nothing is re-derived from donation
  quantities and servings are never treated as kilograms.
* providers are credited for the donations they published, NGOs for the
  donations their accepted/completed claim actually received.
* no response ever exposes firebase_uid, email or phone - only the organization
  name, city, type and the aggregate impact numbers.
"""

from datetime import datetime, timezone

from fastapi import APIRouter, Depends

from app.dependencies import get_current_profile
from app.supabase_client import get_supabase_client

router = APIRouter(prefix="/leaderboard", tags=["leaderboard"])

# A claim in one of these states means the donation really reached the NGO and
# is therefore part of that NGO's redistributed total. A pending/rejected claim
# is not counted.
_RECEIVED_CLAIM_STATUSES = {"accepted", "completed"}


def _org_index(rows: list[dict], public_user_ids: set[str]) -> dict[str, dict]:
    """Maps org id -> {name, city, user_id} for ONLY the opted-in owners."""
    index: dict[str, dict] = {}
    for row in rows:
        user_id = str(row.get("user_id") or "")
        if user_id not in public_user_ids:
            continue
        index[str(row["id"])] = {
            "name": row.get("organization_name") or "Unnamed organization",
            "city": row.get("city") or "",
            "user_id": user_id,
        }
    return index


def _blank_totals() -> dict:
    return {
        "kg_redistributed": 0.0,
        "meals_rescued": 0,
        "co2_saved_kg": 0.0,
        "impact_records": 0,
    }


@router.get("")
def get_leaderboard(profile: dict = Depends(get_current_profile)) -> dict:
    """Real, opt-in leaderboard for the signed-in user (any role may view)."""
    client = get_supabase_client()

    public_users = (
        client.table("users")
        .select("id,role")
        .eq("leaderboard_public", True)
        .execute()
        .data
        or []
    )
    public_user_ids = {str(u["id"]) for u in public_users if u.get("id")}
    if not public_user_ids:
        return {"entries": [], "generated_at": _now_iso()}

    providers = _org_index(
        client.table("providers")
        .select("id,user_id,organization_name,city")
        .execute()
        .data
        or [],
        public_user_ids,
    )
    ngos = _org_index(
        client.table("ngos")
        .select("id,user_id,organization_name,city")
        .execute()
        .data
        or [],
        public_user_ids,
    )

    donations = (
        client.table("donations").select("id,provider_id").execute().data or []
    )
    provider_of_donation = {
        str(d["id"]): str(d.get("provider_id") or "") for d in donations
    }

    claims = (
        client.table("claims")
        .select("donation_id,ngo_id,status")
        .execute()
        .data
        or []
    )
    ngo_of_donation: dict[str, str] = {}
    for claim in claims:
        if str(claim.get("status") or "") in _RECEIVED_CLAIM_STATUSES:
            donation_id = str(claim.get("donation_id") or "")
            ngo_id = str(claim.get("ngo_id") or "")
            if donation_id and ngo_id:
                ngo_of_donation[donation_id] = ngo_id

    impacts = (
        client.table("impact_records")
        .select("donation_id,food_weight_kg,meals_rescued,estimated_co2_saved")
        .execute()
        .data
        or []
    )

    totals: dict[str, dict] = {}

    def _credit(org_id: str, kind: str, impact: dict) -> None:
        bucket = totals.setdefault(org_id, _blank_totals())
        bucket["kind"] = kind
        weight = _as_float(impact.get("food_weight_kg"))
        if weight is not None:
            bucket["kg_redistributed"] += weight
        meals = _as_int(impact.get("meals_rescued"))
        if meals is not None:
            bucket["meals_rescued"] += meals
        co2 = _as_float(impact.get("estimated_co2_saved"))
        if co2 is not None:
            bucket["co2_saved_kg"] += co2
        bucket["impact_records"] += 1

    for impact in impacts:
        donation_id = str(impact.get("donation_id") or "")
        if not donation_id:
            continue
        provider_id = provider_of_donation.get(donation_id)
        if provider_id and provider_id in providers:
            _credit(provider_id, "provider", impact)
        ngo_id = ngo_of_donation.get(donation_id)
        if ngo_id and ngo_id in ngos:
            _credit(ngo_id, "ngo", impact)

    entries = []
    for org_id, bucket in totals.items():
        kind = bucket.get("kind")
        org = (providers if kind == "provider" else ngos).get(org_id)
        if not org:
            continue
        if bucket["kg_redistributed"] <= 0 and bucket["meals_rescued"] <= 0:
            # An impact row that recorded nothing real is not a ranking.
            continue
        entries.append(
            {
                "name": org["name"],
                "city": org["city"],
                "type": kind,
                "kg_redistributed": round(bucket["kg_redistributed"], 2),
                "meals_rescued": bucket["meals_rescued"],
                "co2_saved_kg": round(bucket["co2_saved_kg"], 2),
                "donations": bucket["impact_records"],
            }
        )

    entries.sort(
        key=lambda e: (-e["kg_redistributed"], -e["meals_rescued"], e["name"].lower())
    )
    for rank, entry in enumerate(entries, start=1):
        entry["rank"] = rank

    return {"entries": entries, "generated_at": _now_iso()}


def _as_float(value) -> float | None:
    if value is None:
        return None
    try:
        result = float(value)
    except (TypeError, ValueError):
        return None
    return result if result >= 0 else None


def _as_int(value) -> int | None:
    if value is None:
        return None
    try:
        result = int(value)
    except (TypeError, ValueError):
        return None
    return result if result >= 0 else None


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()
