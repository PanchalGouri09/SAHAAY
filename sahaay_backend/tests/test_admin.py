"""
Tests for the Phase 1 SAHAAY admin dashboard endpoints.

Drives the real FastAPI route + dependency chain (require_role("admin")) against
a fake Supabase modelling the postgrest-py filter/order/range semantics used by
app/routers/admin.py. Auth (get_current_profile) is overridden so we can assert
the 401/403 gates without any Firebase tokens or live Supabase.

Required coverage (all real JSON payloads):
* admin can reach every endpoint; non-admin -> 403; unauthenticated -> 401
* empty tables produce valid empty envelopes / zeroed metrics
* users pagination, ordering, and role filtering
* donation/provider/prediction joins incl. absent prediction
* claim joins (donation + provider + ngo) and delivery joins
  (donation + claim + ngo + volunteer)
* NGO operating hours are returned
* analytics never counts servings as kg; kg + grams sum correctly;
  redistributed kg comes from impact_records.food_weight_kg
* expired / unclaimed-available logic, active delivery statuses,
  completed redistributions, pending claims
* no response ever exposes firebase_uid
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from types import SimpleNamespace

import pytest
from fastapi.testclient import TestClient

from app.dependencies import get_current_profile
from app.main import app

client = TestClient(app)

_ENVELOPE_PATHS = [
    "/api/v1/admin/users",
    "/api/v1/admin/providers",
    "/api/v1/admin/ngos",
    "/api/v1/admin/volunteers",
    "/api/v1/admin/donations",
    "/api/v1/admin/claims",
    "/api/v1/admin/deliveries",
]
_ALL_PATHS = _ENVELOPE_PATHS + ["/api/v1/admin/summary", "/api/v1/admin/analytics"]


# ---------------------------------------------------------------------------
# Fake Supabase (postgrest-py semantics: eq / in_ / order / inclusive range)
# ---------------------------------------------------------------------------
class _RowResult(SimpleNamespace):
    pass


class _FakeTable:
    def __init__(self, name: str, rows: list[dict]) -> None:
        self._name = name
        self._rows = rows
        self._filters: list[tuple] = []
        self._order: tuple[str, bool] | None = None
        self._range: tuple[int, int] | None = None

    def select(self, *cols: str) -> "_FakeTable":
        return self

    def eq(self, key: str, value: object) -> "_FakeTable":
        self._filters.append(("eq", key, value))
        return self

    def in_(self, key: str, values: list) -> "_FakeTable":
        self._filters.append(("in", key, values))
        return self

    def order(self, col: str, *, desc: bool = False, **kwargs) -> "_FakeTable":
        self._order = (col, desc)
        return self

    def range(self, start: int, end: int) -> "_FakeTable":
        self._range = (start, end)
        return self

    def __getattr__(self, item):
        return lambda *a, **k: self

    def _filtered(self) -> list[dict]:
        rows = list(self._rows)
        for kind, key, value in self._filters:
            if kind == "eq":
                rows = [r for r in rows if r.get(key) == value]
            elif kind == "in":
                rows = [r for r in rows if r.get(key) in set(value)]
        if self._order is not None:
            col, desc = self._order
            rows = sorted(
                rows,
                key=lambda r: (r.get(col) is not None, str(r.get(col))),
                reverse=desc,
            )
        if self._range is not None:
            start, end = self._range
            rows = rows[start : end + 1]
        return rows

    def execute(self) -> _RowResult:
        return _RowResult(data=self._filtered())


class _FakeSupabase:
    def __init__(self) -> None:
        self.tables: dict[str, list[dict]] = {}

    def table(self, name: str) -> _FakeTable:
        return _FakeTable(name, self.tables.setdefault(name, []))

    def seed(self, name: str, rows: list[dict]) -> None:
        self.tables.setdefault(name, []).extend(list(rows))


def _donation(**overrides) -> dict:
    row = {
        "id": "don-1",
        "provider_id": "provider-1",
        "prediction_id": None,
        "food_name": "Vegetable Rice",
        "food_category": "Cooked Meals",
        "quantity": 10.0,
        "unit": "kg",
        "servings": None,
        "veg_type": "vegetarian",
        "description": None,
        "food_image_url": None,
        "prepared_at": "2026-09-29T12:00:00+00:00",
        "expiry_time": "2026-09-30T12:00:00+00:00",
        "pickup_deadline": "2026-09-30T10:00:00+00:00",
        "pickup_address": "123 MG Road, Pune",
        "latitude": 18.52,
        "longitude": 73.85,
        "status": "available",
        "created_at": "2026-09-29T12:00:00+00:00",
        "updated_at": "2026-09-29T12:00:00+00:00",
        "cancellation_reason": None,
        "food_prepared_kg": None,
        "food_sold_kg": None,
    }
    row.update(overrides)
    return row


def _user(user_id: str, **overrides) -> dict:
    row = {
        "id": user_id,
        "firebase_uid": f"firebase-{user_id}",
        "full_name": f"Name {user_id}",
        "email": f"{user_id}@example.com",
        "phone": "+91-0000000000",
        "role": "volunteer",
        "profile_image_url": None,
        "created_at": "2026-09-01T00:00:00+00:00",
        "updated_at": "2026-09-01T00:00:00+00:00",
    }
    row.update(overrides)
    return row


def _provider(**overrides) -> dict:
    row = {
        "id": "provider-1",
        "user_id": "user-provider-1",
        "organization_name": "Fresh Bites Kitchen",
        "organization_type": "restaurant",
        "description": None,
        "phone": "+91-1111111111",
        "address": "123 MG Road, Pune",
        "city": "Pune",
        "latitude": 18.52,
        "longitude": 73.85,
        "verified": True,
        "created_at": "2026-09-01T00:00:00+00:00",
        "updated_at": "2026-09-01T00:00:00+00:00",
    }
    row.update(overrides)
    return row


def _ngo(**overrides) -> dict:
    row = {
        "id": "ngo-1",
        "user_id": "user-ngo-1",
        "organization_name": "Feed The City",
        "registration_number": None,
        "description": None,
        "phone": "+91-2222222222",
        "address": "45 Bandra West, Mumbai",
        "city": "Mumbai",
        "latitude": 19.0,
        "longitude": 72.82,
        "food_capacity": 200,
        "preferred_food_types": ["vegetarian", "vegan"],
        "verified": True,
        "available_from": "07:00",
        "available_to": "22:00",
        "created_at": "2026-09-01T00:00:00+00:00",
        "updated_at": "2026-09-01T00:00:00+00:00",
    }
    row.update(overrides)
    return row


def _volunteer(**overrides) -> dict:
    row = {
        "id": "volunteer-1",
        "user_id": "user-volunteer-1",
        "availability_status": "available",
        "vehicle_type": "bike",
        "current_latitude": None,
        "current_longitude": None,
        "verified": True,
        "created_at": "2026-09-01T00:00:00+00:00",
        "updated_at": "2026-09-01T00:00:00+00:00",
    }
    row.update(overrides)
    return row


def _claim(**overrides) -> dict:
    row = {
        "id": "claim-1",
        "donation_id": "don-1",
        "ngo_id": "ngo-1",
        "requested_quantity": 5.0,
        "status": "pending",
        "claimed_at": "2026-09-29T12:30:00+00:00",
        "accepted_at": None,
        "rejected_at": None,
        "notes": None,
        "created_at": "2026-09-29T12:30:00+00:00",
        "updated_at": "2026-09-29T12:30:00+00:00",
        "rejection_reason": None,
    }
    row.update(overrides)
    return row


def _delivery(**overrides) -> dict:
    row = {
        "id": "delivery-1",
        "donation_id": "don-1",
        "claim_id": "claim-1",
        "volunteer_id": "volunteer-1",
        "pickup_address": "123 MG Road, Pune",
        "delivery_address": "45 Bandra West, Mumbai",
        "pickup_time": None,
        "delivery_time": None,
        "status": "assigned",
        "notes": None,
        "created_at": "2026-09-29T13:00:00+00:00",
        "updated_at": "2026-09-29T13:00:00+00:00",
        "proof_of_delivery_url": None,
        "failure_reason": None,
    }
    row.update(overrides)
    return row


# ---------------------------------------------------------------------------
# Fixture: admin profile + fake supabase
# ---------------------------------------------------------------------------
@pytest.fixture
def admin_ctx(monkeypatch: pytest.MonkeyPatch):
    fake = _FakeSupabase()
    monkeypatch.setattr("app.routers.admin.get_supabase_client", lambda: fake)
    app.dependency_overrides[get_current_profile] = lambda: {
        "id": "admin-user-1",
        "role": "admin",
    }
    yield SimpleNamespace(fake=fake)
    app.dependency_overrides.clear()


# ===========================================================================
# 1. Admin can reach every endpoint (and empty tables are safe) [REQ 1 + 4]
# ===========================================================================
@pytest.mark.parametrize("path", _ENVELOPE_PATHS)
def test_admin_endpoint_empty_table_returns_empty_envelope(admin_ctx, path) -> None:
    response = client.get(path)

    assert response.status_code == 200
    body = response.json()
    assert set(body) == {"total", "page", "page_size", "items"}
    assert body["total"] == 0
    assert body["page"] == 1
    assert body["page_size"] == 20
    assert body["items"] == []


def test_admin_summary_empty_returns_zero_counts(admin_ctx) -> None:
    response = client.get("/api/v1/admin/summary")

    assert response.status_code == 200
    assert response.json() == {
        "total_users": 0,
        "providers": 0,
        "ngos": 0,
        "volunteers": 0,
        "total_donations": 0,
        "completed_redistributions": 0,
        "pending_claims": 0,
        "active_deliveries": 0,
    }


def test_admin_analytics_empty_returns_zero_metrics(admin_ctx) -> None:
    response = client.get("/api/v1/admin/analytics")

    assert response.status_code == 200
    assert response.json() == {
        "total_food_donated_kg": 0.0,
        "total_food_redistributed_kg": 0.0,
        "expired_donations": 0,
        "unclaimed_available_donations": 0,
        "successful_redistributions": 0,
        "completed_deliveries": 0,
    }


# ===========================================================================
# 2. Non-admin users are rejected with 403 [REQ 2]
# ===========================================================================
@pytest.mark.parametrize("path", _ALL_PATHS)
def test_non_admin_receives_403(monkeypatch: pytest.MonkeyPatch, path) -> None:
    fake = _FakeSupabase()
    monkeypatch.setattr("app.routers.admin.get_supabase_client", lambda: fake)
    app.dependency_overrides[get_current_profile] = lambda: {
        "id": "user-provider-1",
        "role": "provider",
    }
    try:
        response = client.get(path)
        assert response.status_code == 403
        assert "Insufficient role" in response.json()["detail"]
    finally:
        app.dependency_overrides.clear()


# ===========================================================================
# 3. Unauthenticated requests are rejected with 401 [REQ 3]
# ===========================================================================
def test_unauthenticated_receives_401() -> None:
    app.dependency_overrides.clear()
    response = client.get("/api/v1/admin/users")
    assert response.status_code == 401


# ===========================================================================
# 5. Users pagination + ordering [REQ 5]
# ===========================================================================
def test_users_pagination_slices_descending_order(admin_ctx) -> None:
    for i in range(25):
        created = (datetime(2026, 9, 1, 8, tzinfo=timezone.utc) + timedelta(minutes=i)).isoformat()
        admin_ctx.fake.seed(
            "users",
            [_user(f"user-{i:03d}", role="provider", created_at=created, updated_at=created)],
        )

    page_one = client.get("/api/v1/admin/users", params={"page": 1, "page_size": 10}).json()
    page_two = client.get("/api/v1/admin/users", params={"page": 2, "page_size": 10}).json()

    assert page_one["total"] == 25
    assert page_one["page_size"] == 10
    assert len(page_one["items"]) == 10
    assert page_two["total"] == 25
    assert len(page_two["items"]) == 10
    assert page_two["items"][0]["id"] == "user-014"
    assert page_two["items"][-1]["id"] == "user-005"
    returned_ids = [i["id"] for i in page_one["items"]] + [i["id"] for i in page_two["items"]]
    assert len(set(returned_ids)) == 20


def test_users_default_page_size_is_twenty(admin_ctx) -> None:
    for i in range(25):
        admin_ctx.fake.seed("users", [_user(f"user-{i:03d}")])
    response = client.get("/api/v1/admin/users")

    assert response.status_code == 200
    body = response.json()
    assert body["page_size"] == 20
    assert len(body["items"]) == 20
    assert body["total"] == 25


# ===========================================================================
# 6. Users role filter [REQ 6]
# ===========================================================================
def test_users_role_filter_returns_only_matching_role(admin_ctx) -> None:
    admin_ctx.fake.seed(
        "users",
        [
            _user("u-ngo-1", role="ngo"),
            _user("u-ngo-2", role="ngo"),
            _user("u-prov-1", role="provider"),
            _user("u-admin-1", role="admin"),
        ],
    )

    response = client.get("/api/v1/admin/users", params={"role": "ngo"})

    assert response.status_code == 200
    body = response.json()
    assert body["total"] == 2
    assert {item["id"] for item in body["items"]} == {"u-ngo-1", "u-ngo-2"}


def test_users_invalid_role_filter_is_422(admin_ctx) -> None:
    response = client.get("/api/v1/admin/users", params={"role": "superuser"})
    assert response.status_code == 422


# ===========================================================================
# 16. No endpoint ever exposes firebase credentials [REQ 16]
# ===========================================================================
def test_users_never_expose_firebase_uid(admin_ctx) -> None:
    admin_ctx.fake.seed(
        "users",
        [_user("u-ngo-9", role="ngo", firebase_uid="secret-firebase-uid")],
    )

    response = client.get("/api/v1/admin/users")

    assert response.status_code == 200
    assert "firebase_uid" not in response.text
    assert "secret-firebase-uid" not in response.text


def test_provider_ngo_volunteer_rows_never_include_firebase_uid(admin_ctx) -> None:
    admin_ctx.fake.seed("users", [_user("user-provider-1", role="provider")])
    admin_ctx.fake.seed("providers", [_provider()])
    admin_ctx.fake.seed("users", [_user("user-ngo-1", role="ngo")])
    admin_ctx.fake.seed("ngos", [_ngo()])
    admin_ctx.fake.seed("users", [_user("user-volunteer-1", role="volunteer")])
    admin_ctx.fake.seed("volunteers", [_volunteer()])

    for path in ("/api/v1/admin/providers", "/api/v1/admin/ngos", "/api/v1/admin/volunteers"):
        response = client.get(path)
        assert response.status_code == 200
        assert "firebase_uid" not in response.text
        assert "secret-firebase-uid" not in response.text


# ===========================================================================
# 7. Donation joins: provider + prediction [REQ 7]
# ===========================================================================
def _seed_donation_join_context(admin_ctx) -> None:
    admin_ctx.fake.seed("providers", [_provider()])
    admin_ctx.fake.seed(
        "food_predictions",
        [
            {
                "id": "pred-1",
                "prediction_date": "2026-09-20",
                "recommendation": "Prepare a bit less next time",
                "predicted_surplus": 12.5,
                "confidence_score": 70.0,
                "created_at": "2026-09-19T00:00:00+00:00",
            }
        ],
    )
    admin_ctx.fake.seed(
        "donations",
        [
            _donation(
                id="don-completed",
                provider_id="provider-1",
                prediction_id="pred-1",
                status="completed",
            ),
            _donation(id="don-plain", provider_id="provider-1", prediction_id=None),
            _donation(
                id="don-orphan",
                provider_id="missing-provider",
                prediction_id="ghost-prediction",
            ),
        ],
    )


def test_donations_join_provider_and_prediction(admin_ctx) -> None:
    _seed_donation_join_context(admin_ctx)

    response = client.get("/api/v1/admin/donations")

    assert response.status_code == 200
    body = response.json()
    assert body["total"] == 3
    items = {item["id"]: item for item in body["items"]}
    assert items["don-completed"]["provider"]["organization_name"] == "Fresh Bites Kitchen"
    assert items["don-completed"]["prediction"]["predicted_surplus"] == 12.5
    assert items["don-completed"]["prediction"]["recommendation"].startswith("Prepare")
    assert items["don-completed"]["prediction"]["confidence_score"] == 70.0


def test_donations_without_prediction_do_not_fabricate_one(admin_ctx) -> None:
    _seed_donation_join_context(admin_ctx)

    response = client.get("/api/v1/admin/donations")

    body = response.json()
    items = {item["id"]: item for item in body["items"]}
    assert "prediction" not in items["don-plain"]
    assert "prediction" not in items["don-orphan"]
    assert "provider" not in items["don-orphan"]


# ===========================================================================
# 8. Prediction info included when available (covered above); claims joins
# ===========================================================================
def test_claims_join_donation_provider_and_ngo(admin_ctx) -> None:
    admin_ctx.fake.seed("providers", [_provider()])
    admin_ctx.fake.seed("ngos", [_ngo()])
    admin_ctx.fake.seed(
        "donations",
        [_donation(id="don-1", provider_id="provider-1", prediction_id=None, status="claimed")],
    )
    admin_ctx.fake.seed(
        "claims",
        [_claim(id="claim-1", donation_id="don-1", ngo_id="ngo-1", status="accepted")],
    )

    response = client.get("/api/v1/admin/claims")

    assert response.status_code == 200
    body = response.json()
    item = body["items"][0]
    assert item["donation"]["food_name"] == "Vegetable Rice"
    assert item["donation"]["provider"]["organization_name"] == "Fresh Bites Kitchen"
    assert item["ngo"]["organization_name"] == "Feed The City"


# ===========================================================================
# 9. Delivery joins: donation + claim + ngo + volunteer [REQ 9]
# ===========================================================================
def test_deliveries_join_donation_claim_ngo_and_volunteer(admin_ctx) -> None:
    admin_ctx.fake.seed("providers", [_provider()])
    admin_ctx.fake.seed("ngos", [_ngo()])
    admin_ctx.fake.seed("volunteers", [_volunteer()])
    admin_ctx.fake.seed(
        "donations",
        [_donation(id="don-1", provider_id="provider-1", status="completed")],
    )
    admin_ctx.fake.seed(
        "claims",
        [_claim(id="claim-1", donation_id="don-1", ngo_id="ngo-1", status="accepted")],
    )
    admin_ctx.fake.seed(
        "deliveries",
        [_delivery(id="delivery-1", donation_id="don-1", claim_id="claim-1", volunteer_id="volunteer-1")],
    )

    response = client.get("/api/v1/admin/deliveries")

    assert response.status_code == 200
    item = response.json()["items"][0]
    assert item["donation"]["food_name"] == "Vegetable Rice"
    assert item["claim"]["status"] == "accepted"
    assert item["ngo"]["organization_name"] == "Feed The City"
    assert item["volunteer"]["availability_status"] == "available"
    assert item["volunteer"]["vehicle_type"] == "bike"


# ===========================================================================
# 10. NGO operating hours are returned [REQ 10]
# ===========================================================================
def test_ngos_return_operating_hours_and_user_label(admin_ctx) -> None:
    admin_ctx.fake.seed("users", [_user("user-ngo-1", role="ngo")])
    admin_ctx.fake.seed("ngos", [_ngo(available_from="07:00", available_to="22:00")])

    response = client.get("/api/v1/admin/ngos")

    assert response.status_code == 200
    item = response.json()["items"][0]
    assert item["available_from"] == "07:00"
    assert item["available_to"] == "22:00"
    assert item["user_full_name"] == "Name user-ngo-1"
    assert item["user_email"] == "user-ngo-1@example.com"


# ===========================================================================
# 11. Analytics: servings are NEVER treated as kg [REQ 11 + 12]
# ===========================================================================
def test_analytics_servings_never_counted_as_kg(admin_ctx) -> None:
    admin_ctx.fake.seed(
        "donations",
        [
            _donation(id="d-servings", quantity=10.0, unit="servings", status="completed"),
            _donation(id="d-missing", quantity=None, unit=None),
        ],
    )

    response = client.get("/api/v1/admin/analytics")

    assert response.status_code == 200
    body = response.json()
    assert body["total_food_donated_kg"] == 0.0
    assert body["successful_redistributions"] == 1


def test_analytics_sums_kg_and_grams_only(admin_ctx) -> None:
    admin_ctx.fake.seed(
        "donations",
        [
            _donation(id="d-kg", quantity=10.0, unit="kg"),
            _donation(id="d-grams", quantity=5000.0, unit="g"),
            _donation(id="d-plates", quantity=4.0, unit="plates"),
        ],
    )
    admin_ctx.fake.seed(
        "impact_records",
        [{"id": "ir-1", "donation_id": "d-kg", "food_weight_kg": 8.5}],
    )

    response = client.get("/api/v1/admin/analytics")

    assert response.status_code == 200
    body = response.json()
    assert body["total_food_donated_kg"] == 15.0
    assert body["total_food_redistributed_kg"] == 8.5


# ===========================================================================
# 12/13. Expired and unclaimed-available analytics [REQ 13]
# ===========================================================================
def test_analytics_expired_and_unclaimed_available(admin_ctx) -> None:
    past = (datetime.now(timezone.utc) - timedelta(hours=2)).isoformat()
    future = (datetime.now(timezone.utc) + timedelta(hours=2)).isoformat()
    admin_ctx.fake.seed(
        "donations",
        [
            _donation(id="d-expiry-passed", status="available", expiry_time=past),
            _donation(id="d-marked-expired", status="expired"),
            _donation(id="d-still-open", status="available", expiry_time=future),
            _donation(id="d-completed-past", status="completed", expiry_time=past),
        ],
    )

    response = client.get("/api/v1/admin/analytics")

    assert response.status_code == 200
    body = response.json()
    assert body["expired_donations"] == 2
    assert body["unclaimed_available_donations"] == 1


# ===========================================================================
# 14/15. Summary: active deliveries, pending claims, redistributions, counts
# ===========================================================================
def test_summary_active_deliveries_pending_claims_and_counts(admin_ctx) -> None:
    admin_ctx.fake.seed("users", [_user("u-1"), _user("u-2"), _user("u-3")])
    admin_ctx.fake.seed("providers", [_provider()])
    admin_ctx.fake.seed("ngos", [_ngo()])
    admin_ctx.fake.seed("volunteers", [_volunteer()])
    admin_ctx.fake.seed(
        "donations",
        [
            _donation(id="d1", status="available"),
            _donation(id="d2", status="completed"),
            _donation(id="d3", status="delivered"),
        ],
    )
    admin_ctx.fake.seed(
        "claims",
        [
            _claim(id="c1", status="pending"),
            _claim(id="c2", status="pending"),
            _claim(id="c3", status="accepted"),
            _claim(id="c4", status="completed"),
        ],
    )
    admin_ctx.fake.seed(
        "deliveries",
        [
            _delivery(id="del-1", status="assigned"),
            _delivery(id="del-2", status="accepted"),
            _delivery(id="del-3", status="picked_up"),
            _delivery(id="del-4", status="in_transit"),
            _delivery(id="del-5", status="delivered"),
            _delivery(id="del-6", status="failed"),
            _delivery(id="del-7", status="cancelled"),
        ],
    )

    response = client.get("/api/v1/admin/summary")

    assert response.status_code == 200
    body = response.json()
    assert body["total_users"] == 3
    assert body["providers"] == 1
    assert body["ngos"] == 1
    assert body["volunteers"] == 1
    assert body["total_donations"] == 3
    assert body["completed_redistributions"] == 2
    assert body["pending_claims"] == 2
    assert body["active_deliveries"] == 4


def test_analytics_completed_deliveries_count(admin_ctx) -> None:
    admin_ctx.fake.seed(
        "deliveries",
        [
            _delivery(id="del-1", status="delivered"),
            _delivery(id="del-2", status="delivered"),
            _delivery(id="del-3", status="failed"),
        ],
    )

    response = client.get("/api/v1/admin/analytics")

    assert response.status_code == 200
    assert response.json()["completed_deliveries"] == 2