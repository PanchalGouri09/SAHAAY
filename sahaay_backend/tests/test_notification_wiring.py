"""End-to-end tests for Batch 2 business notification wiring.

Every real business event must:
    persist a `notifications` row (source of truth)
    -> send an FCM push to the SERVER-RESOLVED recipient
    -> never roll back the business transaction when FCM fails
    -> never duplicate an identical (user, type, donation, title) event
    -> never trust a client-supplied recipient

The fake Supabase below is filterable and mutable so recipients can be
asserted against the same database relationships production uses. The FCM
sender is replaced with a recorder (or a raiser) — no Firebase project is
touched.
"""

from __future__ import annotations

from datetime import datetime, timezone
from types import SimpleNamespace

import pytest
from fastapi.testclient import TestClient

from app.config import Settings
from app.dependencies import get_current_firebase_user, get_current_profile
from app.main import app
from app.services import notification_service

client = TestClient(app)


# ---------------------------------------------------------------------------
# Fake Supabase (filterable, mutable, with the real trigger side-effects that
# matter here: completing a donation when its delivery reaches 'delivered')
# ---------------------------------------------------------------------------
class _Result:
    def __init__(self, data) -> None:
        self.data = data


class _Table:
    def __init__(self, name: str, db: "_FakeSupabase") -> None:
        self._name = name
        self._db = db
        self._filters: list[tuple] = []
        self._mode = "query"
        self._insert: dict | None = None
        self._upsert: tuple[dict, str] | None = None
        self._update: dict | None = None
        self._seq = 0

    def select(self, *cols: str) -> "_Table":
        return self

    def eq(self, key: str, value: object) -> "_Table":
        self._filters.append(("eq", key, value))
        return self

    def or_(self, expression: str) -> "_Table":
        self._filters.append(("or", expression))
        return self

    def is_(self, key: str, value: object) -> "_Table":
        self._filters.append(("is", key, value))
        return self

    def in_(self, key: str, values) -> "_Table":
        self._filters.append(("in", key, list(values)))
        return self

    def order(self, col: str, **kwargs) -> "_Table":
        return self

    def limit(self, n: int) -> "_Table":
        return self

    def maybe_single(self) -> "_Table":
        self._mode = "maybe"
        return self

    def single(self) -> "_Table":
        self._mode = "single"
        return self

    def insert(self, values: dict) -> "_Table":
        self._insert = dict(values)
        return self

    def upsert(self, values: dict, *, on_conflict: str) -> "_Table":
        self._upsert = (dict(values), on_conflict)
        self._db.upserts.append((self._name, on_conflict))
        return self

    def update(self, values: dict) -> "_Table":
        self._update = dict(values)
        return self

    def delete(self) -> "_Table":
        self._mode = "delete"
        return self

    def _rows(self) -> list[dict]:
        rows = self._db.tables.setdefault(self._name, [])
        out = []
        for row in rows:
            keep = True
            for filter_item in self._filters:
                kind = filter_item[0]
                if kind == "or":
                    value = filter_item[1]
                    alternatives = []
                    for clause in value.split(","):
                        field, operator, raw = clause.split(".", 2)
                        if operator == "eq":
                            expected = (
                                raw == "true" if raw in {"true", "false"} else raw
                            )
                            alternatives.append((field, expected))
                    if not any(
                        row.get(field) == expected for field, expected in alternatives
                    ):
                        keep = False
                    continue
                _, key, value = filter_item
                if kind == "eq" and row.get(key) != value:
                    keep = False
                elif kind == "is" and row.get(key) is not value:
                    keep = False
                elif kind == "in" and row.get(key) not in value:
                    keep = False
            if keep:
                out.append(row)
        return out

    def execute(self):
        mode, insert, upsert, update = (
            self._mode,
            self._insert,
            self._upsert,
            self._update,
        )
        self._mode, self._insert, self._upsert, self._update = (
            "query",
            None,
            None,
            None,
        )
        rows = self._rows()

        if upsert is not None:
            values, on_conflict = upsert
            conflict_columns = [column.strip() for column in on_conflict.split(",")]
            table_rows = self._db.tables.setdefault(self._name, [])
            existing = next(
                (
                    row
                    for row in table_rows
                    if all(
                        row.get(column) == values.get(column)
                        for column in conflict_columns
                    )
                ),
                None,
            )
            if existing is not None:
                existing.update(values)
                return _Result([dict(existing)])
            row = dict(values)
            self._seq += 1
            row.setdefault("id", f"{self._name}-row-{self._seq}")
            table_rows.append(row)
            return _Result([dict(row)])

        if insert is not None:
            row = dict(insert)
            self._seq += 1
            row.setdefault("id", f"{self._name}-row-{self._seq}")
            row.setdefault("is_read", False)
            self._db.tables.setdefault(self._name, []).append(row)
            return _Result([dict(row)])

        if update is not None:
            for row in rows:
                row.update(update)
            # Mirrors the production record_delivery_impact trigger: a delivery
            # reaching 'delivered' completes its donation (the only real
            # completion signal in this application).
            if (
                self._name == "deliveries"
                and update.get("status") == "delivered"
                and self._db.simulate_completion_trigger
            ):
                for row in rows:
                    for donation in self._db.tables.setdefault("donations", []):
                        if str(donation.get("id")) == str(row.get("donation_id")):
                            donation["status"] = "completed"
            return _Result([dict(r) for r in rows])

        if mode == "maybe":
            return None if not rows else _Result(dict(rows[0]))
        if mode == "single":
            return _Result(dict(rows[0]) if rows else {})
        if mode == "delete":
            for row in rows:
                self._db.tables.get(self._name, []).remove(row)
            return _Result([])
        return _Result([dict(r) for r in rows])


class _Bucket:
    def __init__(self, storage: "_Storage", bucket: str) -> None:
        self._storage = storage
        self._bucket = bucket

    def upload(self, path, data, file_options=None) -> None:
        if self._storage.fail_upload:
            raise RuntimeError("storage unavailable")
        self._storage.objects[(self._bucket, path)] = bytes(data)

    def get_public_url(self, path) -> str:
        return f"https://storage.test/{self._bucket}/{path}"

    def download(self, path):
        return self._storage.objects[(self._bucket, path)]


class _Storage:
    def __init__(self) -> None:
        self.objects: dict[tuple, bytes] = {}
        self.fail_upload = False

    def get_bucket(self, name):
        return {"name": name}

    def create_bucket(self, name, options=None):
        return {"name": name}

    def from_(self, bucket):
        return _Bucket(self, bucket)


class _FakeSupabase:
    def __init__(self) -> None:
        self.tables: dict[str, list[dict]] = {}
        self.upserts: list[tuple[str, str]] = []
        self.storage = _Storage()
        self.simulate_completion_trigger = True

    def table(self, name: str) -> _Table:
        return _Table(name, self)

    def seed(self, name: str, rows: list[dict]) -> None:
        self.tables.setdefault(name, []).extend(dict(r) for r in rows)
        if name == "ngos":
            users = self.tables.setdefault("users", [])
            for ngo in rows:
                if not ngo.get("user_id"):
                    continue
                users.append(
                    {
                        "id": ngo["user_id"],
                        "role": "ngo",
                        "full_name": "NGO Contact",
                        "email": f"{ngo['id']}@example.org",
                        "phone": "+91 9876543210",
                    }
                )

    def rows(self, name: str) -> list[dict]:
        return self.tables.setdefault(name, [])

    def rpc(self, name: str, params: dict):
        if name == "issue_donation_handover_code":
            claim = next(
                row
                for row in self.rows("claims")
                if row.get("id") == params["p_claim_id"]
                and row.get("donation_id") == params["p_donation_id"]
            )
            claim.update(
                {
                    "handover_code_hash": params["p_code_hash"],
                    "handover_code_expires_at": params["p_expires_at"],
                    "handover_code_attempts": 0,
                }
            )
            return _Rpc({"status": "issued"})
        if name == "verify_donation_handover":
            claim = next(
                row
                for row in self.rows("claims")
                if row.get("id") == params["p_claim_id"]
                and row.get("donation_id") == params["p_donation_id"]
            )
            if claim.get("handover_verified_at"):
                return _Rpc(
                    {
                        "status": "already_verified",
                        "verified_at": claim["handover_verified_at"],
                    }
                )
            if claim["handover_code_hash"] != params["p_candidate_hash"]:
                claim["handover_code_attempts"] = (
                    claim.get("handover_code_attempts", 0) + 1
                )
                return _Rpc(
                    {
                        "status": "wrong_code",
                        "remaining_attempts": 10 - claim["handover_code_attempts"],
                    }
                )
            verified_at = datetime.now(timezone.utc).isoformat()
            claim.update(
                {
                    "status": "completed",
                    "handover_verified_at": verified_at,
                    "handover_code_hash": None,
                    "handover_code_expires_at": None,
                    "handover_code_attempts": 0,
                }
            )
            for donation in self.rows("donations"):
                if donation.get("id") == params["p_donation_id"]:
                    donation["status"] = "completed"
            return _Rpc({"status": "verified", "verified_at": verified_at})
        if name == "confirm_claim_volunteer_assignment":
            delivery = next(
                row
                for row in self.rows("deliveries")
                if row.get("id") == params["p_delivery_id"]
                and row.get("volunteer_id") is None
            )
            delivery.update(
                {"volunteer_id": params["p_volunteer_id"], "status": "assigned"}
            )
            coordination = next(
                row
                for row in self.rows("claim_transport_coordination")
                if row.get("claim_id") == delivery.get("claim_id")
                and row.get("status") == "searching_for_volunteers"
            )
            coordination.update(
                {"responsible_role": "volunteer", "status": "volunteer_assigned"}
            )
            return _Rpc(
                {
                    "delivery": dict(delivery),
                    "coordination": dict(coordination),
                }
            )
        if name == "respond_to_claim_transport":
            coordination = next(
                row
                for row in self.rows("claim_transport_coordination")
                if row.get("claim_id") == params["p_claim_id"]
            )
            role = params["p_actor_role"]
            coordination[f"{role}_response"] = params["p_response"]
            if params["p_response"] == "yes" and not coordination.get(
                "responsible_role"
            ):
                coordination["responsible_role"] = role
                coordination["status"] = f"{role}_transport"
            if (
                coordination.get("provider_response") == "no"
                and coordination.get("ngo_response") == "no"
            ):
                coordination["status"] = "searching_for_volunteers"
            return _Rpc(dict(coordination))
        raise AssertionError(f"Unexpected RPC: {name}")


class _Rpc:
    def __init__(self, result: dict) -> None:
        self._result = result

    def execute(self):
        return _Result(self._result)


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------
@pytest.fixture
def fake(monkeypatch: pytest.MonkeyPatch) -> _FakeSupabase:
    fake = _FakeSupabase()
    for module in (
        "app.dependencies.get_supabase_client",
        "app.routers.profile.get_supabase_client",
        "app.routers.donations.get_supabase_client",
        "app.routers.claims.get_supabase_client",
        "app.routers.deliveries.get_supabase_client",
        "app.routers.notifications.get_supabase_client",
        "app.routers.handover.get_supabase_client",
        "app.routers.transport_coordination.get_supabase_client",
        "app.routers.ai_features.get_supabase_client",
    ):
        monkeypatch.setattr(module, lambda: fake)
    # The completion hook resolves the AI client directly (it runs outside the
    # request DI graph). Pin it here so no test can ever open a real socket to
    # 127.0.0.1:8001 — the PDF pipeline itself is exercised in
    # test_acknowledgment_pipeline.py with a full mock transport.
    from app.services.ai_client import AIServiceUnavailableError

    monkeypatch.setattr(
        "app.services.acknowledgment.get_ai_client",
        lambda: SimpleNamespace(
            generate_acknowledgment=lambda *_a, **_k: (_ for _ in ()).throw(
                AIServiceUnavailableError()
            ),
            download_acknowledgment=lambda *_a, **_k: (_ for _ in ()).throw(
                AIServiceUnavailableError()
            ),
        ),
    )
    app.dependency_overrides[get_current_profile] = lambda: {
        "id": "user-unknown",
        "role": "volunteer",
        "volunteers": [{"id": "vol-unknown"}],
    }
    app.dependency_overrides[get_current_firebase_user] = lambda: {
        "uid": "firebase-volunteer",
        "email": "volunteer@example.org",
        "email_verified": True,
        "phone_number": "+919876543210",
    }
    monkeypatch.setattr(
        "app.config.get_settings",
        lambda: Settings(firebase_phone_auth_enabled=True),
    )
    yield fake
    app.dependency_overrides.clear()


def test_device_token_registration_uses_unique_token_conflict_target(fake) -> None:
    fake.seed(
        "user_device_tokens",
        [
            {
                "id": "existing-token",
                "user_id": "old-user",
                "token": "same-device-token",
                "platform": "android",
                "created_at": "2026-10-01T00:00:00+00:00",
            }
        ],
    )
    app.dependency_overrides[get_current_profile] = lambda: {
        "id": "current-user",
        "role": "volunteer",
        "volunteers": [{"id": "vol-current"}],
    }

    response = client.post(
        "/api/v1/notifications/device-token",
        json={"token": "same-device-token", "platform": "ios"},
    )

    assert response.status_code == 200
    assert response.json() == {"status": "ok"}
    assert fake.upserts == [("user_device_tokens", "token")]
    rows = fake.rows("user_device_tokens")
    assert len(rows) == 1
    assert rows[0]["id"] == "existing-token"
    assert rows[0]["user_id"] == "current-user"
    assert rows[0]["token"] == "same-device-token"
    assert rows[0]["platform"] == "ios"
    assert rows[0]["created_at"] == "2026-10-01T00:00:00+00:00"


class _FcmRecorder:
    """Stands in for fcm_sender.send_push_notification_to_user."""

    def __init__(self) -> None:
        self.calls: list[tuple] = []
        self.raise_error: Exception | None = None

    def __call__(self, user_id, title, body, data=None):
        if self.raise_error is not None:
            raise self.raise_error
        self.calls.append((user_id, title, body, data))
        return {"sent": 1, "failed": 0, "invalid": 0}


@pytest.fixture
def fcm(monkeypatch: pytest.MonkeyPatch) -> _FcmRecorder:
    recorder = _FcmRecorder()
    monkeypatch.setattr(
        "app.services.fcm_sender.send_push_notification_to_user", recorder
    )
    return recorder


def _login(role: str, profile_row: dict) -> dict:
    defaults = {
        "provider": {
            "organization_name": "Test Kitchen",
            "address": "1 Market Road",
            "city": "Pune",
            "latitude": 18.52,
            "longitude": 73.85,
        },
        "ngo": {
            "organization_name": "Test Pantry",
            "address": "2 Market Road",
            "city": "Pune",
            "latitude": 18.53,
            "longitude": 73.86,
            "available_from": "07:00",
            "available_to": "22:00",
            "max_capacity_kg": 25,
            "preferred_food_types": ["Cooked Meals"],
            "dietary_preferences": ["vegetarian"],
            "verified": False,
        },
        "volunteer": {},
    }[role]
    defaults.update(profile_row)
    app.dependency_overrides[get_current_profile] = lambda: {
        "id": profile_row.get("user_id_for_profile", f"user-{role}"),
        "role": role,
        "full_name": "Test Contact",
        "email": f"{role}@example.org",
        "phone": "+91 9876543210",
        **{f"{role}s": [defaults]},
    }
    app.dependency_overrides[get_current_firebase_user] = lambda: {
        "uid": f"firebase-{role}",
        "email": f"{role}@example.org",
        "email_verified": True,
        "phone_number": "+919876543210",
    }
    return defaults


def _notifications(fake: _FakeSupabase) -> list[dict]:
    return list(fake.rows("notifications"))


# ===========================================================================
# A. Donation created -> NGOs with complete matching logistics in the same city
# ===========================================================================
def _matching_ngo(user_id: str, ngo_id: str, city: str = "Pune", **overrides):
    return {
        "id": ngo_id,
        "user_id": user_id,
        "organization_name": "Community Pantry",
        "address": "1 Market Road",
        "city": city,
        "latitude": 18.53,
        "longitude": 73.86,
        "available_from": "07:00",
        "available_to": "22:00",
        "max_capacity_kg": 50,
        "preferred_food_types": ["Cooked Meals"],
        "dietary_preferences": ["vegetarian"],
        "verified": True,
        **overrides,
    }


def test_donation_created_notifies_only_same_city_complete_ngos(fake, fcm) -> None:
    fake.seed(
        "ngos",
        [
            _matching_ngo("u-ngo-1", "ngo-1"),
            _matching_ngo("u-ngo-2", "ngo-2"),
            _matching_ngo("u-ngo-3", "ngo-3", available_to=None),
            _matching_ngo("u-ngo-4", "ngo-4", city="Mumbai"),
        ],
    )
    donation = {
        "id": "don-1",
        "food_name": "Vegetable Rice",
        "quantity": 12.5,
        "unit": "kg",
    }

    notification_service.donation_created(
        fake,
        donation=donation,
        provider_row={"organization_name": "Tasty Kitchen", "city": "Pune"},
    )

    rows = _notifications(fake)
    assert {r["user_id"] for r in rows} == {"u-ngo-1", "u-ngo-2"}
    assert all(r["type"] == "new_nearby_donation" for r in rows)
    assert all(r["related_donation_id"] == "don-1" for r in rows)
    assert all(r["is_read"] is False for r in rows)
    assert all("Vegetable Rice" in r["title"] for r in rows)
    # FCM was pushed to exactly the persisted recipients.
    assert {c[0] for c in fcm.calls} == {"u-ngo-1", "u-ngo-2"}
    assert all(c[3]["type"] == "new_nearby_donation" for c in fcm.calls)
    assert all(c[3]["donation_id"] == "don-1" for c in fcm.calls)


def test_donation_created_notifies_profile_ready_ngo_without_legal_status(
    fake, fcm
) -> None:
    fake.seed(
        "ngos",
        [
            _matching_ngo("u-ngo-ready", "ngo-ready"),
            _matching_ngo("u-unready", "ngo-unready", preferred_food_types=[]),
        ],
    )

    notification_service.donation_created(
        fake,
        donation={"id": "don-demo", "food_name": "Rice"},
        provider_row={"organization_name": "Kitchen", "city": "Pune"},
    )

    assert {row["user_id"] for row in _notifications(fake)} == {"u-ngo-ready"}
    assert {call[0] for call in fcm.calls} == {"u-ngo-ready"}


def test_donation_created_without_provider_city_notifies_nobody(fake, fcm) -> None:
    fake.seed(
        "ngos",
        [
            _matching_ngo("u-ngo-1", "ngo-1"),
        ],
    )

    notification_service.donation_created(
        fake,
        donation={"id": "don-1", "food_name": "Rice"},
        provider_row={"organization_name": "Tasty Kitchen"},  # no city recorded
    )

    assert _notifications(fake) == []
    assert fcm.calls == []


def test_creating_a_donation_wires_the_donation_created_event(
    fake, fcm, monkeypatch
) -> None:
    """The create endpoint notifies NGOs with matching-ready profiles."""
    import httpx

    from app.services.ai_client import AIClient, get_ai_client

    fake.seed(
        "ngos",
        [
            _matching_ngo("u-ngo-1", "ngo-1"),
            _matching_ngo("u-ngo-2", "ngo-2", city="Mumbai"),
        ],
    )
    app.dependency_overrides[get_current_profile] = lambda: {
        "id": "user-provider",
        "role": "provider",
        "full_name": "Provider Contact",
        "email": "provider@example.org",
        "phone": "+91 9876543210",
        "providers": [
            {
                "id": "prov-1",
                "user_id": "u-provider",
                "organization_name": "Tasty Kitchen",
                "city": "Pune",
                "address": "123 MG Road",
                "latitude": 18.52,
                "longitude": 73.85,
            }
        ],
    }
    app.dependency_overrides[get_current_firebase_user] = lambda: {
        "uid": "firebase-provider",
        "email": "provider@example.org",
        "email_verified": True,
        "phone_number": "+919876543210",
    }

    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path == "/api/v1/safety/verify":
            return httpx.Response(
                200,
                json={
                    "donation_id": "pending-1",
                    "verdict": "Eligible",
                    "hours_since_preparation": 2.0,
                    "reasons": [],
                },
            )
        return httpx.Response(404, json={"detail": "not found"})

    app.dependency_overrides[get_ai_client] = lambda: AIClient(
        base_url="http://ai.test",
        timeout=5.0,
        transport=httpx.MockTransport(handler),
    )

    response = client.post(
        "/api/v1/donations",
        json={
            "food_name": "Vegetable Rice",
            "food_category": "Cooked Meals",
            "quantity": 10.0,
            "unit": "servings",
            "veg_type": "vegetarian",
            "food_image_url": "https://project.supabase.co/storage/v1/object/public/donations/food-photos/x/photo.png",
            "storage_condition": "refrigerated",
            "prepared_at": "2026-08-28T12:00:00Z",
            "expiry_time": "2026-08-28T20:00:00Z",
            "pickup_deadline": "2026-08-28T18:00:00Z",
            "pickup_address": "123 MG Road, Pune",
        },
    )
    assert response.status_code in (200, 201), response.text

    rows = _notifications(fake)
    assert {r["user_id"] for r in rows} == {"u-ngo-1"}
    assert all(r["type"] == "new_nearby_donation" for r in rows)
    assert {c[0] for c in fcm.calls} == {"u-ngo-1"}


# ===========================================================================
# B. Claim created -> the donation's provider (recipient from DB only)
# ===========================================================================
# ClaimCreate validates donation_id as a real UUID, so claim-flow seeds use one.
_DONATION_UUID = "11111111-1111-1111-1111-111111111111"


def _seed_claim_target(fake) -> None:
    fake.seed(
        "providers",
        [
            {
                "id": "prov-1",
                "user_id": "u-provider",
                "organization_name": "Tasty Kitchen",
            },
        ],
    )
    fake.seed(
        "donations",
        [
            {
                "id": _DONATION_UUID,
                "provider_id": "prov-1",
                "food_name": "Vegetable Rice",
                "quantity": 10.0,
                "unit": "kg",
                "pickup_address": "5 Kitchen Road",
                "pickup_deadline": "2030-01-01T18:00:00Z",
                "status": "available",
            },
        ],
    )


def test_claim_created_notifies_provider_and_ignores_client_recipient(
    fake, fcm
) -> None:
    _seed_claim_target(fake)
    _login(
        "ngo",
        {
            "id": "ngo-1",
            "organization_name": "Feed The City",
            "address": "12 NGO Lane",
            "user_id_for_profile": "u-ngo",
        },
    )

    response = client.post(
        "/api/v1/claims",
        # A client-supplied recipient must be ignored entirely.
        json={
            "donation_id": _DONATION_UUID,
            "requested_quantity": 5.0,
            "user_id": "attacker-chosen-user",
            "ngo_id": "attacker-chosen-ngo",
        },
    )

    assert response.status_code == 201, response.text
    rows = _notifications(fake)
    assert len(rows) == 1
    assert rows[0]["user_id"] == "u-provider"  # server-derived recipient
    assert rows[0]["type"] == "claim_submitted"
    assert rows[0]["related_donation_id"] == _DONATION_UUID
    assert fcm.calls[0][0] == "u-provider"


def test_claim_creation_requires_ngo_role(fake, fcm) -> None:
    _seed_claim_target(fake)
    _login("provider", {"id": "prov-1", "organization_name": "Tasty Kitchen"})

    response = client.post(
        "/api/v1/claims",
        json={"donation_id": _DONATION_UUID, "requested_quantity": 5.0},
    )

    assert response.status_code == 403
    assert _notifications(fake) == []
    assert fcm.calls == []


# ===========================================================================
# C. Claim acceptance/status changes -> provider + displaced NGOs
# ===========================================================================
def test_claim_acceptance_notifies_provider_and_displaced_ngo(fake, fcm) -> None:
    fake.seed(
        "providers",
        [
            {
                "id": "prov-1",
                "user_id": "u-provider",
                "organization_name": "Tasty Kitchen",
            },
        ],
    )
    fake.seed(
        "donations",
        [
            {
                "id": "don-1",
                "provider_id": "prov-1",
                "food_name": "Vegetable Rice",
                "status": "available",
            },
        ],
    )
    fake.seed(
        "ngos",
        [
            {"id": "ngo-a", "user_id": "u-ngo-a", "organization_name": "NGO A"},
            {"id": "ngo-b", "user_id": "u-ngo-b", "organization_name": "NGO B"},
        ],
    )
    fake.seed(
        "claims",
        [
            {
                "id": "claim-a",
                "donation_id": "don-1",
                "ngo_id": "ngo-a",
                "status": "pending",
            },
            {
                "id": "claim-b",
                "donation_id": "don-1",
                "ngo_id": "ngo-b",
                "status": "pending",
            },
        ],
    )
    _login("ngo", {"id": "ngo-a", "organization_name": "NGO A"})

    response = client.patch("/api/v1/claims/claim-a", params={"status": "accepted"})

    assert response.status_code == 200, response.text
    rows = _notifications(fake)
    by_user = {r["user_id"]: r for r in rows}
    # Provider learns the claim was accepted...
    assert by_user["u-provider"]["type"] == "donation_claimed"
    assert by_user["u-provider"]["title"] == "Your donation has been accepted!"
    assert by_user["u-provider"]["message"] == (
        "NGO A has accepted your Vegetable Rice donation. Open SAHAAY to view "
        "the handover details."
    )
    assert "'accepted'" not in by_user["u-provider"]["message"]
    # The NGO that accepted the claim gets a confirmation without any raw IDs.
    assert by_user["u-ngo-a"]["title"] == "Donation confirmed"
    assert by_user["u-ngo-a"]["message"] == (
        "Your claim for Vegetable Rice is confirmed. Open SAHAAY to view pickup "
        "and handover details."
    )
    # ...the displaced NGO learns ITS claim was rejected...
    assert by_user["u-ngo-b"]["type"] == "claim_rejected"
    assert {c[0] for c in fcm.calls} == {"u-provider", "u-ngo-a", "u-ngo-b"}
    provider_push = next(call for call in fcm.calls if call[0] == "u-provider")
    assert provider_push[3] == {
        "type": "donation_claimed",
        "donation_id": "don-1",
        "screen": "donation_claims",
    }


def test_claim_acceptance_uses_human_copy_when_food_name_is_missing(fake, fcm) -> None:
    fake.seed("providers", [{"id": "prov-1", "user_id": "u-provider"}])
    fake.seed(
        "ngos",
        [
            {
                "id": "ngo-1",
                "user_id": "u-ngo",
                "organization_name": "8f347ca2-70f9-4c01-aeb3-2099302c1183",
            }
        ],
    )
    notification_service.claim_status_changed(
        fake,
        claim={"id": "claim-1", "donation_id": "don-1", "ngo_id": "ngo-1"},
        new_status="accepted",
        donation={"id": "don-1", "provider_id": "prov-1", "food_name": None},
    )

    rows = {row["user_id"]: row for row in _notifications(fake)}
    assert rows["u-provider"]["message"] == (
        "An NGO has accepted your donation. Open SAHAAY to view the handover details."
    )
    assert rows["u-ngo"]["message"] == (
        "Your claim is confirmed. Open SAHAAY to view pickup and handover details."
    )


def test_claim_cancelled_notifies_provider_with_cancelled_type(fake, fcm) -> None:
    fake.seed(
        "providers",
        [
            {
                "id": "prov-1",
                "user_id": "u-provider",
                "organization_name": "Tasty Kitchen",
            },
        ],
    )
    fake.seed(
        "donations",
        [
            {
                "id": "don-1",
                "provider_id": "prov-1",
                "food_name": "Vegetable Rice",
                "status": "claimed",
            },
        ],
    )
    fake.seed(
        "claims",
        [
            {
                "id": "claim-a",
                "donation_id": "don-1",
                "ngo_id": "ngo-a",
                "status": "accepted",
            },
        ],
    )
    _login("ngo", {"id": "ngo-a", "organization_name": "NGO A"})

    response = client.patch("/api/v1/claims/claim-a", params={"status": "cancelled"})

    assert response.status_code == 200
    rows = _notifications(fake)
    assert len(rows) == 1
    assert rows[0]["user_id"] == "u-provider"
    assert rows[0]["type"] == "claim_cancelled"


# ===========================================================================
# G. Auto-escalation -> the NGO whose claim was actually rejected
# ===========================================================================
def _escalation_ai(action: str = "escalate"):
    return SimpleNamespace(
        check_escalation=lambda payload: SimpleNamespace(
            donation_id=payload.donation_id,
            action=action,
            next_ngo_id=None,
            next_ngo_index=None,
            minutes_elapsed=42.0,
            message=(
                "The current NGO timed out. This internal ID is "
                "8f347ca2-70f9-4c01-aeb3-2099302c1183."
            ),
        )
    )


def test_escalation_rejection_notifies_the_claiming_ngo(fake, fcm) -> None:
    from app.services.escalation import assess_donation_escalation

    fake.seed("ngos", [{"id": "ngo-1", "user_id": "u-ngo-1"}])
    fake.seed("providers", [{"id": "prov-1", "user_id": "u-provider"}])
    donation = {
        "id": "don-1",
        "provider_id": "prov-1",
        "food_name": "Vegetable Rice",
        "status": "available",
        "expiry_time": "2099-01-01T20:00:00+00:00",
    }
    fake.seed("donations", [dict(donation)])
    fake.seed(
        "claims",
        [
            {
                "id": "claim-1",
                "donation_id": "don-1",
                "ngo_id": "ngo-1",
                "status": "pending",
                "created_at": "2026-01-01T10:00:00+00:00",
            },
        ],
    )

    response = assess_donation_escalation(fake, _escalation_ai(), donation)

    assert response["action"] == "escalate"
    rows = _notifications(fake)
    assert len(rows) == 1
    assert rows[0]["user_id"] == "u-ngo-1"  # the rejected claim's NGO
    assert rows[0]["type"] == "claim_rejected"
    assert rows[0]["related_donation_id"] == "don-1"
    assert rows[0]["message"] == (
        "The response period for your Vegetable Rice claim has ended. Open SAHAAY "
        "to review the latest status."
    )
    assert "8f347ca2-70f9-4c01-aeb3-2099302c1183" not in rows[0]["message"]
    assert fcm.calls[0][0] == "u-ngo-1"
    # The claim really was rejected by the shared row-guarded update.
    assert fake.rows("claims")[0]["status"] == "rejected"


def test_escalation_keep_waiting_notifies_nobody(fake, fcm) -> None:
    from app.services.escalation import assess_donation_escalation

    donation = {
        "id": "don-1",
        "provider_id": "prov-1",
        "food_name": "Rice",
        "status": "available",
        "expiry_time": "2099-01-01T20:00:00+00:00",
    }
    fake.seed("donations", [dict(donation)])
    fake.seed(
        "claims",
        [
            {
                "id": "claim-1",
                "donation_id": "don-1",
                "ngo_id": "ngo-1",
                "status": "pending",
                "created_at": "2026-01-01T10:00:00+00:00",
            },
        ],
    )

    response = assess_donation_escalation(
        fake, _escalation_ai("keep_waiting"), donation
    )

    assert response["action"] == "keep_waiting"
    assert _notifications(fake) == []
    assert fcm.calls == []


# ===========================================================================
# D/F. Delivery: volunteer assignment + status changes
# ===========================================================================
def _seed_delivery(
    fake, *, delivery_status="assigned", donation_status="claimed"
) -> None:
    fake.seed(
        "providers",
        [
            {
                "id": "prov-1",
                "user_id": "u-provider",
                "organization_name": "Tasty Kitchen",
            },
        ],
    )
    fake.seed(
        "ngos",
        [
            {"id": "ngo-1", "user_id": "u-ngo", "organization_name": "Feed The City"},
        ],
    )
    fake.seed(
        "donations",
        [
            {
                "id": "don-1",
                "provider_id": "prov-1",
                "food_name": "Vegetable Rice",
                "quantity": 10.0,
                "unit": "kg",
                "status": donation_status,
                "expiry_time": "2030-01-01T20:00:00Z",
                "pickup_deadline": "2030-01-01T13:00:00Z",
            },
        ],
    )
    fake.seed(
        "claims",
        [
            {
                "id": "claim-1",
                "donation_id": "don-1",
                "ngo_id": "ngo-1",
                "status": "accepted",
                "handover_verified_at": "2030-01-01T10:00:00Z",
            },
        ],
    )
    fake.seed(
        "deliveries",
        [
            {
                "id": "del-1",
                "donation_id": "don-1",
                "claim_id": "claim-1",
                "volunteer_id": "vol-1",
                "status": delivery_status,
            },
        ],
    )
    fake.seed(
        "volunteers",
        [
            {"id": "vol-1", "user_id": "u-volunteer"},
        ],
    )


def _login_volunteer():
    _login("volunteer", {"id": "vol-1"})


def test_volunteer_acceptance_notifies_ngo_and_provider(fake, fcm) -> None:
    _seed_delivery(fake, delivery_status="unassigned", donation_status="available")
    fake.rows("deliveries")[0]["volunteer_id"] = None
    fake.seed(
        "claim_transport_coordination",
        [
            {
                "claim_id": "claim-1",
                "status": "searching_for_volunteers",
                "responsible_role": None,
            },
        ],
    )
    _login_volunteer()

    response = client.post("/api/v1/deliveries/del-1/accept")

    assert response.status_code == 200, response.text
    rows = _notifications(fake)
    assert {r["user_id"] for r in rows} == {"u-ngo", "u-provider"}
    assert all(r["type"] == "volunteer_assigned" for r in rows)
    assert {c[0] for c in fcm.calls} == {"u-ngo", "u-provider"}


def test_later_yes_responder_is_told_first_transport_winner(fake, fcm) -> None:
    fake.seed("providers", [{"id": "provider-1", "user_id": "u-provider"}])
    fake.seed("ngos", [{"id": "ngo-1", "user_id": "u-ngo"}])

    notification_service.transport_responsibility_confirmed(
        fake,
        donation={"id": "don-1", "provider_id": "provider-1", "food_name": "Rice"},
        claim={"id": "claim-1", "ngo_id": "ngo-1"},
        coordination={"responsible_role": "provider"},
        responding_role="ngo",
    )

    rows = _notifications(fake)
    assert len(rows) == 1
    assert rows[0]["user_id"] == "u-ngo"
    assert rows[0]["related_donation_id"] == "don-1"
    assert "provider confirmed transport first" in rows[0]["message"].lower()
    assert fcm.calls[0][0] == "u-ngo"


def test_later_yes_response_preserves_winner_and_notifies_responder(fake, fcm) -> None:
    fake.seed("providers", [{"id": "provider-1", "user_id": "u-provider"}])
    fake.seed("ngos", [{"id": "ngo-1", "user_id": "u-ngo"}])
    fake.seed(
        "donations",
        [
            {"id": "don-1", "provider_id": "provider-1", "food_name": "Rice"},
        ],
    )
    fake.seed(
        "claims",
        [
            {
                "id": "claim-1",
                "donation_id": "don-1",
                "ngo_id": "ngo-1",
                "status": "accepted",
            },
        ],
    )
    fake.seed(
        "claim_transport_coordination",
        [
            {
                "claim_id": "claim-1",
                "donation_id": "don-1",
                "provider_id": "provider-1",
                "ngo_id": "ngo-1",
                "provider_response": "yes",
                "provider_captain_name": "Provider Captain",
                "provider_captain_phone": "9876543210",
                "ngo_response": None,
                "responsible_role": "provider",
                "status": "provider_transport",
            },
        ],
    )
    _login("ngo", {"id": "ngo-1", "user_id_for_profile": "u-ngo"})

    response = client.post(
        "/api/v1/claims/claim-1/transport-coordination/respond",
        json={
            "response": "yes",
            "captain_name": "NGO Captain",
            "captain_phone": "9876543211",
        },
    )

    assert response.status_code == 200, response.text
    assert response.json()["responsible_role"] == "provider"
    assert response.json()["provider_captain_name"] == "Provider Captain"
    assert response.json()["provider_captain_phone"] == "9876543210"
    rows = _notifications(fake)
    assert len(rows) == 1
    assert rows[0]["user_id"] == "u-ngo"
    assert "provider confirmed transport first" in rows[0]["message"].lower()
    assert fcm.calls[0][0] == "u-ngo"


def test_delivered_status_notifies_both_parties(fake, fcm) -> None:
    _seed_delivery(fake, delivery_status="accepted")
    _login_volunteer()

    response = client.patch(
        "/api/v1/deliveries/del-1/status", json={"status": "delivered"}
    )

    assert response.status_code == 200, response.text
    rows = [r for r in _notifications(fake) if r["type"] == "delivery_completed"]
    assert {r["user_id"] for r in rows} == {"u-ngo", "u-provider"}
    assert fake.rows("donations")[0]["status"] == "completed"  # trigger simulated
    repeated = client.patch(
        "/api/v1/deliveries/del-1/status", json={"status": "delivered"}
    )
    assert repeated.status_code == 200
    assert (
        len([r for r in _notifications(fake) if r["type"] == "delivery_completed"]) == 2
    )
    reopened = client.patch(
        "/api/v1/deliveries/del-1/status", json={"status": "accepted"}
    )
    assert reopened.status_code == 409


def test_intermediate_pickup_notifies_only_the_claiming_ngo(fake, fcm) -> None:
    _seed_delivery(fake, delivery_status="accepted")
    _login_volunteer()

    response = client.patch(
        "/api/v1/deliveries/del-1/status", json={"status": "picked_up"}
    )

    assert response.status_code == 200
    rows = _notifications(fake)
    assert len(rows) == 1
    assert rows[0]["user_id"] == "u-ngo"
    assert rows[0]["type"] == "pickup_updated"
    assert "u-provider" not in {r["user_id"] for r in rows}


def test_no_notification_when_status_does_not_change(fake, fcm) -> None:
    _seed_delivery(fake, delivery_status="accepted")
    _login_volunteer()

    response = client.patch(
        "/api/v1/deliveries/del-1/status", json={"status": "accepted"}
    )

    assert response.status_code == 200
    assert _notifications(fake) == []
    assert fcm.calls == []


def test_failed_delivery_quotes_the_real_failure_reason(fake, fcm) -> None:
    _seed_delivery(fake, delivery_status="accepted")
    _login_volunteer()

    response = client.patch(
        "/api/v1/deliveries/del-1/status",
        json={"status": "failed", "failure_reason": "Recipient unavailable"},
    )

    assert response.status_code == 200
    rows = [r for r in _notifications(fake) if r["type"] == "delivery_failed"]
    assert {r["user_id"] for r in rows} == {"u-ngo", "u-provider"}
    assert all("Recipient unavailable" in r["message"] for r in rows)


# ===========================================================================
# E. Handover verified -> the provider
# ===========================================================================
def test_handover_verification_notifies_both_claim_participants(fake, fcm) -> None:
    fake.seed(
        "providers",
        [
            {
                "id": "prov-1",
                "user_id": "u-provider",
                "organization_name": "Tasty Kitchen",
            },
        ],
    )
    fake.seed("ngos", [{"id": "ngo-1", "user_id": "u-ngo"}])
    fake.seed(
        "donations",
        [
            {
                "id": "don-1",
                "provider_id": "prov-1",
                "food_name": "Vegetable Rice",
                "status": "claimed",
            },
        ],
    )
    fake.seed(
        "claims",
        [
            {
                "id": "claim-1",
                "donation_id": "don-1",
                "ngo_id": "ngo-1",
                "status": "accepted",
                "handover_code_hash": "hash",
                "handover_code_attempts": 0,
            },
        ],
    )
    _login("provider", {"id": "prov-1"})

    code_response = client.post("/api/v1/donations/don-1/handover/code")
    assert code_response.status_code == 200, code_response.text
    code = code_response.json()["handover_code"]
    _login("ngo", {"id": "ngo-1"})

    verify = client.post("/api/v1/donations/don-1/handover/verify", json={"code": code})

    assert verify.status_code == 200, verify.text
    rows = _notifications(fake)

    # Completion is relevant to both the provider and receiving NGO.
    verified = [r for r in rows if r["type"] == "handover_verified"]
    assert {r["user_id"] for r in verified} == {"u-provider", "u-ngo"}
    assert all(r["related_donation_id"] == "don-1" for r in verified)

    # In this scenario the receipt could not be persisted, so BOTH real
    # participants are additionally told the donation is completed and the
    # receipt is still being prepared (the previously-unwired
    # `handover_completed` event).
    completed = [r for r in rows if r["type"] == "handover_completed"]
    assert {r["user_id"] for r in completed} == {"u-provider", "u-ngo"}
    assert all("receipt is still being prepared" in r["message"] for r in completed)


# ===========================================================================
# FCM failure isolation + invalid token handling
# ===========================================================================
def test_fcm_failure_never_breaks_the_business_event(fake, fcm) -> None:
    _seed_claim_target(fake)
    _login(
        "ngo",
        {"id": "ngo-1", "organization_name": "Feed The City", "address": "12 NGO Lane"},
    )
    fcm.raise_error = RuntimeError("FCM endpoint unreachable")

    response = client.post(
        "/api/v1/claims",
        json={"donation_id": _DONATION_UUID, "requested_quantity": 5.0},
    )

    # The business transaction completed AND the durable record exists —
    # only the push was skipped.
    assert response.status_code == 201, response.text
    rows = _notifications(fake)
    assert len(rows) == 1
    assert rows[0]["user_id"] == "u-provider"
    assert fcm.calls == []


def test_fcm_failure_never_breaks_a_delivery_update(fake, fcm) -> None:
    _seed_delivery(fake, delivery_status="accepted")
    _login_volunteer()
    fcm.raise_error = RuntimeError("FCM endpoint unreachable")

    response = client.patch(
        "/api/v1/deliveries/del-1/status", json={"status": "delivered"}
    )

    assert response.status_code == 200, response.text
    assert (
        len([r for r in _notifications(fake) if r["type"] == "delivery_completed"]) == 2
    )


def test_invalid_token_sender_keeps_the_persisted_record(monkeypatch) -> None:
    """A real UnregisteredError from FCM removes the stale token but never
    raises — and the notification row it was pushed from stays durable."""
    from firebase_admin import messaging

    from app.services import fcm_sender

    class _SenderDb:
        def __init__(self) -> None:
            self.rows = [
                {"user_id": "u-1", "token": "stale-token", "platform": "android"}
            ]

        def table(self, _name):
            db = self.rows
            state = {"deleting": False, "key": None, "value": None}

            class _Q:
                def select(self, *_):
                    return self

                def eq(self, key, value):
                    state["key"], state["value"] = key, value
                    return self

                def delete(self):
                    state["deleting"] = True
                    return self

                def execute(self):
                    if state["deleting"]:
                        db[:] = [r for r in db if r.get(state["key"]) != state["value"]]
                        return _Result([])
                    return _Result(
                        [dict(r) for r in db if r.get(state["key"]) == state["value"]]
                    )

            return _Q()

    sender_db = _SenderDb()
    monkeypatch.setattr("app.firebase_auth.get_firebase_app", lambda: object())
    monkeypatch.setattr("app.supabase_client.get_supabase_client", lambda: sender_db)
    monkeypatch.setattr(
        fcm_sender.firebase_messaging,
        "send",
        lambda *_a, **_k: (_ for _ in ()).throw(
            messaging.UnregisteredError("unregistered")
        ),
    )

    fake = _FakeSupabase()
    row = notification_service.notify(
        fake,
        "u-1",
        title="T",
        message="B",
        notif_type="claim_submitted",
        related_donation_id="don-1",
    )

    assert row is not None
    assert len(fake.rows("notifications")) == 1
    assert sender_db.rows == []  # stale token cleaned up by the sender


def test_android_push_uses_the_shared_high_importance_ting_ting_channel() -> None:
    from app.services.fcm_sender import (
        ANDROID_CHANNEL_ID,
        ANDROID_NOTIFICATION_SOUND,
        _android_config,
    )

    notification = _android_config().notification

    assert ANDROID_CHANNEL_ID == "sahaay_notifications_v2"
    assert notification.channel_id == ANDROID_CHANNEL_ID
    assert notification.sound == ANDROID_NOTIFICATION_SOUND
    assert notification.default_sound is False
    assert ANDROID_NOTIFICATION_SOUND == "sahaay_ting_ting"


# ===========================================================================
# Duplicate prevention
# ===========================================================================
def test_identical_event_is_only_persisted_once(fake, fcm) -> None:
    kwargs = dict(
        title="New donation near you: Rice",
        message="Tasty Kitchen posted 10 kg of Rice.",
        notif_type="new_nearby_donation",
        related_donation_id="don-1",
    )
    first = notification_service.notify(fake, "u-ngo", **kwargs)
    second = notification_service.notify(fake, "u-ngo", **kwargs)

    assert first is not None
    assert second is None
    assert len(_notifications(fake)) == 1
    # The suppressed duplicate is also suppressed as a push (one push total).
    assert len(fcm.calls) == 1


@pytest.mark.parametrize(
    ("title", "message", "expected_title", "expected_message"),
    [
        (
            "Offer 11111111-2222-3333-4444-555555555555",
            "A real update is available.",
            "SAHAAY update",
            "A real update is available.",
        ),
        (
            "Donation update",
            '{"detail":"SQLSTATE 42P10"}',
            "Donation update",
            "There is an update about your donation. Open SAHAAY to see the latest status.",
        ),
        (
            "Donation update",
            "PostgREST APIError: HTTP 503 internal server error",
            "Donation update",
            "There is an update about your donation. Open SAHAAY to see the latest status.",
        ),
        (
            "Donation update",
            "FCM token A" + "b" * 40,
            "Donation update",
            "There is an update about your donation. Open SAHAAY to see the latest status.",
        ),
        (
            "Donation update",
            "The next NGO ID: 843719.",
            "Donation update",
            "There is an update about your donation. Open SAHAAY to see the latest status.",
        ),
    ],
)
def test_notification_copy_never_exposes_ids_tokens_json_or_diagnostics(
    fake, fcm, title, message, expected_title, expected_message
) -> None:
    row = notification_service.notify(
        fake,
        "u-1",
        title=title,
        message=message,
        notif_type="claim_submitted",
        related_donation_id="don-1",
    )

    assert row is not None
    assert row["title"] == expected_title
    assert row["message"] == expected_message
    assert fcm.calls[0][1:3] == (expected_title, expected_message)


def test_push_payload_is_minimal_and_excludes_internal_identifiers(fake, fcm):
    notification_service.notify(
        fake,
        "u-ngo",
        title="Donation offer: Rice",
        message="Please review the offer in SAHAAY.",
        notif_type="donation_offer",
        related_donation_id="don-1",
        data={
            "screen": "my_offers",
            "offer_id": "offer-2",
            "expires_at": "2026-10-14T00:05:00+00:00",
            "candidate_rank": 2,
            "token": "private-device-token",
        },
    )

    _, title, message, payload = fcm.calls[0]
    assert title == "Donation offer: Rice"
    assert message == "Please review the offer in SAHAAY."
    assert payload == {
        "type": "donation_offer",
        "screen": "my_offers",
        "donation_id": "don-1",
    }
    assert all(isinstance(value, str) for value in payload.values())


def test_different_titles_on_same_donation_are_both_kept(fake, fcm) -> None:
    base = dict(
        message="claimed your donation",
        notif_type="claim_submitted",
        related_donation_id="don-1",
    )
    notification_service.notify(fake, "u-provider", title="NGO A claimed Rice", **base)
    notification_service.notify(fake, "u-provider", title="NGO B claimed Rice", **base)

    assert len(_notifications(fake)) == 2
    assert len(fcm.calls) == 2


def test_phone_contact_update_notification_is_in_app_and_unverified(fake, fcm):
    notification_service.contact_phone_updated(
        fake,
        user_id="u-volunteer",
        previous_phone=None,
    )

    rows = _notifications(fake)
    assert len(rows) == 1
    assert rows[0]["title"] == "Phone number added"
    assert rows[0]["type"] is None
    assert "format is valid" in rows[0]["message"]
    assert "not been verified" in rows[0]["message"]
    assert len(fcm.calls) == 1
    assert "SMS" not in rows[0]["message"]


# ===========================================================================
# Role authorization on the notification surface
# ===========================================================================
def test_notifications_require_authentication(fake) -> None:
    app.dependency_overrides.pop(get_current_profile, None)
    app.dependency_overrides.pop(get_current_firebase_user, None)
    assert client.get("/api/v1/notifications").status_code == 401


def test_notifications_list_is_scoped_to_the_authenticated_user(fake) -> None:
    fake.seed(
        "notifications",
        [
            {
                "id": "n-1",
                "user_id": "u-1",
                "title": "Mine",
                "message": "m",
                "is_read": False,
            },
            {
                "id": "n-2",
                "user_id": "u-2",
                "title": "Theirs",
                "message": "m",
                "is_read": False,
            },
        ],
    )
    app.dependency_overrides[get_current_profile] = lambda: {
        "id": "u-1",
        "role": "volunteer",
        "volunteers": [{"id": "vol-1"}],
    }

    response = client.get("/api/v1/notifications")

    assert response.status_code == 200
    rows = response.json()
    assert [r["id"] for r in rows] == ["n-1"]


def test_cannot_mark_another_users_notification_read(fake) -> None:
    fake.seed(
        "notifications",
        [
            {
                "id": "n-2",
                "user_id": "u-2",
                "title": "Theirs",
                "message": "m",
                "is_read": False,
            },
        ],
    )
    app.dependency_overrides[get_current_profile] = lambda: {
        "id": "u-1",
        "role": "volunteer",
        "volunteers": [{"id": "vol-1"}],
    }

    response = client.patch("/api/v1/notifications/n-2/read")

    assert response.status_code == 404
    assert fake.rows("notifications")[0]["is_read"] is False


def test_own_notification_can_be_marked_read(fake) -> None:
    fake.seed(
        "notifications",
        [
            {
                "id": "n-1",
                "user_id": "u-1",
                "title": "Mine",
                "message": "m",
                "is_read": False,
            },
        ],
    )
    app.dependency_overrides[get_current_profile] = lambda: {
        "id": "u-1",
        "role": "volunteer",
        "volunteers": [{"id": "vol-1"}],
    }

    response = client.patch("/api/v1/notifications/n-1/read")

    assert response.status_code == 200
    assert fake.rows("notifications")[0]["is_read"] is True
