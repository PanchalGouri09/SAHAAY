"""Registration conflict tests for POST /api/v1/profile.

The live device failure this guards against: Firebase account creation
succeeds, GET /profile correctly 404s for the brand-new UID, but the INSERT
into `users` then dies on the UNIQUE `users_email_key` constraint because the
submitted email already belongs to a *different* Firebase account — surfacing
as a generic 500 ("Unable to create the SAHAAY profile.").

These tests drive the real `create_profile()` route against a fake Supabase
that, unlike the deliberately filter-blind fake in `test_no_row_guards.py`,
honors `.eq()` filters and enforces the UNIQUE(users.email) constraint the
way Postgres does (raising a 23505-like error on a duplicate insert). Only
the app-auth (`get_current_firebase_user`) and Supabase-transport layers are
mocked; no Firebase tokens and no live Supabase are required.

Invariants covered:
  * new firebase_uid + new email -> 201, exactly one users row created,
  * existing email + DIFFERENT firebase_uid -> 409 with a clear message,
    the pre-existing row is neither overwritten nor reassigned,
  * existing firebase_uid (the original check) -> 409, no second row,
  * no duplicate users row is ever created by a rejected registration,
  * the unique users.email constraint still exists in the migrations and is
    never dropped by a later one.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from app.dependencies import get_current_firebase_user
from app.main import app

client = TestClient(app)

MIGRATIONS_DIR = Path(__file__).resolve().parents[1] / "supabase" / "migrations"
ORIGINAL_SCHEMA = MIGRATIONS_DIR / "20260912112505_remote_schema.sql"

_FIREBASE_UID = "firebase-uid-new"
_OTHER_FIREBASE_UID = "firebase-uid-legacy"
_EMAIL = "panchalgouri2008@gmail.com"


# ---------------------------------------------------------------------------
# Fake Supabase honoring .eq() filters and the UNIQUE(users.email) constraint
# ---------------------------------------------------------------------------
class _APIError(Exception):
    """Mimics `postgrest.exceptions.APIError` (23505 duplicate key)."""

    def __init__(self, message: str, code: str) -> None:
        super().__init__(message)
        self.message = message
        self.code = code


class _RowResult:
    def __init__(self, data) -> None:
        self.data = data


class _FakeTable:
    def __init__(self, store: dict[str, list[dict]], name: str) -> None:
        self._store = store
        self._name = name
        self._filters: list[tuple[str, object]] = []
        self._mode = "query"
        self._last_inserted: dict | None = None

    def select(self, *cols: str) -> "_FakeTable":
        return self

    def eq(self, key: str, value: object) -> "_FakeTable":
        self._filters.append((key, value))
        return self

    def maybe_single(self) -> "_FakeTable":
        self._mode = "maybe_single"
        return self

    def single(self) -> "_FakeTable":
        self._mode = "single"
        return self

    def delete(self) -> "_FakeTable":
        self._mode = "delete"
        return self

    def insert(self, values: dict) -> "_FakeTable":
        row = dict(values)
        if self._name == "users" and row.get("email") is not None:
            for existing in self._store.get("users", []):
                if existing.get("email") == row["email"]:
                    # Same failure Postgres raises on users_email_key (23505).
                    raise _APIError(
                        'duplicate key value violates unique constraint "users_email_key"',
                        code="23505",
                    )
        row.setdefault("id", f"{self._name}-row-{len(self._store.get(self._name, [])) + 1}")
        self._store.setdefault(self._name, []).append(row)
        self._last_inserted = row
        self._mode = "insert"
        return self

    def execute(self):
        mode, self._mode = self._mode, "query"
        filters, self._filters = self._filters, []
        rows = [
            row
            for row in self._store.get(self._name, [])
            if all(row.get(key) == value for key, value in filters)
        ]
        if mode == "insert":
            return _RowResult([self._last_inserted])
        if mode == "delete":
            self._store[self._name] = [
                row for row in self._store.get(self._name, []) if row not in rows
            ]
            return _RowResult(rows)
        if mode == "maybe_single":
            # postgrest-py 2.31: zero matches -> None, not an empty response.
            return _RowResult(rows[0]) if rows else None
        if mode == "single":
            if len(rows) != 1:
                raise RuntimeError("single() expected exactly one row")
            return _RowResult(rows[0])
        return _RowResult(rows)


class _FakeSupabase:
    def __init__(self, store: dict[str, list[dict]]) -> None:
        self.store = store

    def table(self, name: str) -> _FakeTable:
        return _FakeTable(self.store, name)


@pytest.fixture
def supabase(monkeypatch: pytest.MonkeyPatch) -> _FakeSupabase:
    fake = _FakeSupabase({"users": []})
    for module in (
        "app.dependencies.get_supabase_client",
        "app.routers.profile.get_supabase_client",
    ):
        monkeypatch.setattr(module, lambda: fake)
    app.dependency_overrides[get_current_firebase_user] = lambda: {"uid": _FIREBASE_UID}
    yield fake
    app.dependency_overrides.clear()


def _payload(**overrides) -> dict:
    payload = {
        "full_name": "Gouri Panchal",
        "email": _EMAIL,
        "phone": "+919876543210",
        "role": "volunteer",
        "volunteer": {"availability_status": "available"},
    }
    payload.update(overrides)
    return payload


# ---------------------------------------------------------------------------
# create_profile() conflict handling
# ---------------------------------------------------------------------------
def test_new_firebase_uid_with_new_email_creates_profile(supabase) -> None:
    response = client.post("/api/v1/profile", json=_payload())

    assert response.status_code == 201
    body = response.json()
    assert body["firebase_uid"] == _FIREBASE_UID
    assert body["email"] == _EMAIL
    users = supabase.store["users"]
    assert len(users) == 1
    assert users[0]["firebase_uid"] == _FIREBASE_UID


def test_new_ngo_registration_schedules_immediate_matching_refresh(
    supabase, monkeypatch
) -> None:
    refresh_calls = []
    monkeypatch.setattr(
        "app.routers.profile._refresh_open_donation_matches",
        lambda: refresh_calls.append(True),
    )
    response = client.post(
        "/api/v1/profile",
        json=_payload(
            role="ngo",
            ngo={
                "organization_name": "Community Pantry",
                "address": "2 Market Road",
                "city": "Pune",
                "latitude": 18.53,
                "longitude": 73.86,
                "available_from": "07:00",
                "available_to": "22:00",
                "max_capacity_kg": 25,
                "preferred_food_types": ["Cooked Meals"],
                "dietary_preferences": ["vegetarian"],
            },
        ),
    )

    assert response.status_code == 201, response.text
    assert response.json()["profile_completion"]["percentage"] == 100
    assert refresh_calls == [True]
    assert response.json()["profile"].get("verified") is not True


def test_existing_email_with_different_firebase_uid_returns_409(supabase) -> None:
    supabase.store["users"].append(
        {
            "id": "user-legacy",
            "firebase_uid": _OTHER_FIREBASE_UID,
            "email": _EMAIL,
            "full_name": "Legacy Account",
            "role": "ngo",
        }
    )

    response = client.post("/api/v1/profile", json=_payload())

    assert response.status_code == 409
    detail = response.json()["detail"]
    assert "already associated with another SAHAAY account" in detail
    # No duplicate row, no overwrite, no reassignment of the existing account.
    users = supabase.store["users"]
    assert len(users) == 1
    assert users[0]["id"] == "user-legacy"
    assert users[0]["firebase_uid"] == _OTHER_FIREBASE_UID
    assert users[0]["full_name"] == "Legacy Account"


def test_existing_firebase_uid_returns_conflict_without_duplicate_row(supabase) -> None:
    supabase.store["users"].append(
        {
            "id": "user-existing",
            "firebase_uid": _FIREBASE_UID,
            "email": _EMAIL,
            "full_name": "Already Registered",
            "role": "provider",
        }
    )

    response = client.post("/api/v1/profile", json=_payload())

    assert response.status_code == 409
    assert response.json()["detail"] == "A SAHAAY profile already exists."
    assert len(supabase.store["users"]) == 1
    # The original check (firebase_uid -> users.id) still runs first and wins.
    assert supabase.store["users"][0]["id"] == "user-existing"


def test_rejected_registration_creates_no_role_row(supabase) -> None:
    supabase.store["users"].append(
        {
            "id": "user-legacy",
            "firebase_uid": _OTHER_FIREBASE_UID,
            "email": _EMAIL,
            "role": "volunteer",
        }
    )

    response = client.post("/api/v1/profile", json=_payload())

    assert response.status_code == 409
    assert "volunteers" not in supabase.store


def test_db_still_rejects_duplicate_email_insert() -> None:
    """The UNIQUE constraint is the last line of defence if a race slips past
    the pre-check: prove the modelled (and therefore real, by the migration
    test below) constraint still raises 23505 instead of inserting twice."""
    fake = _FakeSupabase(
        {"users": [{"id": "user-1", "firebase_uid": "uid-1", "email": _EMAIL}]}
    )
    with pytest.raises(_APIError) as excinfo:
        fake.table("users").insert(
            {"firebase_uid": "uid-2", "email": _EMAIL, "role": "volunteer"}
        )
    assert excinfo.value.code == "23505"
    assert len(fake.store["users"]) == 1


# ---------------------------------------------------------------------------
# Schema: unique users.email constraint remains intact
# ---------------------------------------------------------------------------
def test_unique_users_email_constraint_exists_in_migrations() -> None:
    sql = ORIGINAL_SCHEMA.read_text(encoding="utf-8")
    assert (
        "CREATE UNIQUE INDEX users_email_key ON public.users USING btree (email);"
        in sql
    )
    assert (
        'add constraint "users_email_key" UNIQUE using index "users_email_key"' in sql
    )


def test_no_later_migration_drops_users_email_unique() -> None:
    drop_pattern = re.compile(
        r"drop\s+(?:constraint|index)\s+(?:if\s+exists\s+)?\"?users_email_key",
        re.IGNORECASE,
    )
    for path in sorted(MIGRATIONS_DIR.glob("*.sql")):
        sql = path.read_text(encoding="utf-8")
        assert not drop_pattern.search(sql), f"users_email_key dropped in {path.name}"
