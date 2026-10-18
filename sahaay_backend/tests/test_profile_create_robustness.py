"""Robustness tests for POST /api/v1/profile hardening.

Two gaps the original route left open, both of which produced a bare 500 with
no way to tell why:

  1. The duplicate lookups relied on the *shape* returned by
     ``maybe_single().execute()``. ``postgrest-py`` 2.x returns ``None`` for
     zero rows (verified against the pinned 2.31.0), but older clients returned
     a response object whose ``.data`` was ``None``/``[]`` - which the old
     ``is not None`` test read as "a row exists" and rejected a first-ever
     registration. [profile._single_or_none] now normalises every shape.

  2. The catch-all wrapped ANY failure into a generic 500 and logged nothing,
     so the real PostgREST/schema error was invisible.

These tests drive the real route against a small honoring fake; only the
app-auth and Supabase-transport layers are mocked.
"""

from __future__ import annotations

import logging

import pytest
from fastapi.testclient import TestClient

from app.dependencies import get_current_firebase_user
from app.main import app

client = TestClient(app)

_FIREBASE_UID = "firebase-uid-fresh"
_EMAIL = "fresh.registration@example.com"


class _RowResult:
    def __init__(self, data) -> None:
        self.data = data


class _LegacyEmptyResponse:
    """Mimics an older postgrest response for a zero-row maybe_single()."""

    def __init__(self, data=None) -> None:
        self.data = data


class _FakeTable:
    def __init__(self, store: dict[str, list[dict]], name: str, legacy_empty: bool) -> None:
        self._store = store
        self._name = name
        self._legacy_empty = legacy_empty
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

    def delete(self) -> "_FakeTable":
        self._mode = "delete"
        return self

    def insert(self, values: dict) -> "_FakeTable":
        if self._name == "volunteers":
            raise RuntimeError("simulated role-table write failure")
        row = dict(values)
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
            if rows:
                return _RowResult(rows[0])
            # The bug: an empty lookup returned an object, not None.
            return _LegacyEmptyResponse(None) if self._legacy_empty else None
        return _RowResult(rows)


class _FakeSupabase:
    def __init__(self, store: dict[str, list[dict]], legacy_empty: bool = False) -> None:
        self.store = store
        self._legacy_empty = legacy_empty

    def table(self, name: str) -> _FakeTable:
        return _FakeTable(self.store, name, self._legacy_empty)


def _install(monkeypatch: pytest.MonkeyPatch, fake: _FakeSupabase) -> None:
    monkeypatch.setattr("app.routers.profile.get_supabase_client", lambda: fake)
    app.dependency_overrides[get_current_firebase_user] = lambda: {"uid": _FIREBASE_UID}


def _payload() -> dict:
    return {
        "full_name": "Fresh User",
        "email": _EMAIL,
        "phone": "+919876543210",
        "role": "volunteer",
        "volunteer": {"availability_status": "available"},
    }


def test_legacy_empty_maybe_single_success_path(monkeypatch) -> None:
    """With a working role table, a first-ever registration is 201 even when the
    client reports an (empty) response object from maybe_single()."""
    fake = _FakeSupabase({"users": []}, legacy_empty=True)
    fake.store.setdefault("volunteers", [])
    # Patch the role-table insert to succeed for this test.
    original_insert = _FakeTable.insert

    def ok_insert(self, values):  # type: ignore[no-untyped-def]
        if self._name == "volunteers":
            row = dict(values)
            row.setdefault("id", "volunteer-1")
            self._store.setdefault(self._name, []).append(row)
            self._last_inserted = row
            self._mode = "insert"
            return self
        return original_insert(self, values)

    monkeypatch.setattr(_FakeTable, "insert", ok_insert)
    _install(monkeypatch, fake)
    try:
        response = client.post("/api/v1/profile", json=_payload())
    finally:
        app.dependency_overrides.clear()

    assert response.status_code == 201
    assert response.json()["firebase_uid"] == _FIREBASE_UID


def test_generic_failure_returns_500_and_rolls_back(monkeypatch, caplog) -> None:
    """A non-duplicate DB error is a 500, the users row is rolled back, and the
    real cause is logged (not silently swallowed)."""
    fake = _FakeSupabase({"users": []})
    _install(monkeypatch, fake)
    try:
        with caplog.at_level(logging.ERROR, logger="sahaay.profile"):
            response = client.post("/api/v1/profile", json=_payload())
    finally:
        app.dependency_overrides.clear()

    assert response.status_code == 500
    assert response.json()["detail"] == "Unable to create the SAHAAY profile."
    # No orphaned half-written account.
    assert fake.store.get("users") == []
    # The underlying failure is recorded, so a real 500 is diagnosable.
    assert any(
        record.levelno >= logging.ERROR and "create_profile failed" in record.getMessage()
        for record in caplog.records
    )


def test_ngo_registration_persists_matching_location_hours_and_kg_capacity(
    monkeypatch,
) -> None:
    fake = _FakeSupabase({"users": [], "ngos": []})
    _install(monkeypatch, fake)
    payload = {
        "full_name": "NGO Contact",
        "email": "ngo@example.com",
        "phone": "+919876543210",
        "role": "ngo",
        "ngo": {
            "organization_name": "Community Kitchen",
            "address": "12 Example Road",
            "city": "Pune",
            "latitude": 18.52,
            "longitude": 73.85,
            "food_capacity": 200,
            "max_capacity_kg": 25,
            "preferred_food_types": ["Cooked Meals"],
            "dietary_preferences": ["vegetarian"],
            "available_from": "07:00",
            "available_to": "22:00",
        },
    }

    try:
        response = client.post("/api/v1/profile", json=payload)
    finally:
        app.dependency_overrides.clear()

    assert response.status_code == 201
    stored = fake.store["ngos"][0]
    assert stored["latitude"] == 18.52
    assert stored["longitude"] == 73.85
    assert stored["available_from"] == "07:00"
    assert stored["available_to"] == "22:00"
    assert stored["max_capacity_kg"] == 25
