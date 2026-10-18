"""Tests for POST /api/v1/profile/adopt.

The live/test Supabase project can end up with SAHAAY `users` rows whose
Firebase Authentication user was deleted. A person signing back in gets a NEW
Firebase UID, so GET /profile 404s by UID, the app sends them to enrollment,
and POST /profile then fails with "email already associated with another
SAHAAY account". `adopt` resolves that by re-linking the existing row to the
new UID - but ONLY when the old UID is verifiably gone, so a live account can
never be hijacked by a different identity.

These tests drive the real route against a small honoring fake of the Supabase
client; only the auth dependency and the Firebase liveness probe are mocked.
"""

from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from app.dependencies import get_current_firebase_user
from app.main import app

client = TestClient(app)

_NEW_UID = "firebase-uid-new"
_OLD_UID = "firebase-uid-old"
_EMAIL = "returning.user@example.com"


class _Result:
    def __init__(self, data) -> None:
        self.data = data


class _FakeTable:
    def __init__(self, store: dict[str, list[dict]], name: str) -> None:
        self._store = store
        self._name = name
        self._filters: list[tuple[str, object]] = []
        self._update: dict | None = None
        self._mode = "query"

    def select(self, *cols: str) -> "_FakeTable":
        return self

    def eq(self, key: str, value: object) -> "_FakeTable":
        self._filters.append((key, value))
        return self

    def update(self, values: dict) -> "_FakeTable":
        self._update = dict(values)
        return self

    def maybe_single(self) -> "_FakeTable":
        self._mode = "maybe_single"
        return self

    def execute(self):
        mode, self._mode = self._mode, "query"
        filters, self._filters = self._filters, []
        rows = [
            row
            for row in self._store.get(self._name, [])
            if all(row.get(key) == value for key, value in filters)
        ]
        if self._update is not None:
            for row in rows:
                row.update(self._update)
            self._update = None
            return _Result(rows[0] if rows else None)
        if mode == "maybe_single":
            return _Result(rows[0]) if rows else None
        return _Result(rows)


class _FakeSupabase:
    def __init__(self, store: dict[str, list[dict]]) -> None:
        self.store = store

    def table(self, name: str) -> _FakeTable:
        return _FakeTable(self.store, name)


def _user_row(uid: str, *, row_id: str = "user-1", role: str = "ngo") -> dict:
    return {
        "id": row_id,
        "firebase_uid": uid,
        "email": _EMAIL,
        "full_name": "Returning User",
        "role": role,
        f"{role}s": {"id": f"{role}-1", "organization_name": "Helping Hands"},
    }


def _install(monkeypatch, store, *, uid=_NEW_UID, email=_EMAIL, verified=True, liveness=None):
    fake = _FakeSupabase(store)
    monkeypatch.setattr("app.routers.profile.get_supabase_client", lambda: fake)
    if liveness is not None:
        monkeypatch.setattr("app.routers.profile.firebase_user_exists", liveness)
    app.dependency_overrides[get_current_firebase_user] = lambda: {
        "uid": uid,
        "email": email,
        "email_verified": verified,
    }
    return fake


def test_adopt_relinks_orphaned_row(monkeypatch) -> None:
    """A row whose old Firebase user is gone is re-linked to the new UID and
    returned, so the person logs straight in (no enrollment, no 409)."""
    store = {"users": [_user_row(_OLD_UID)]}
    calls: list[str] = []
    fake = _install(
        monkeypatch, store, liveness=lambda uid: calls.append(uid) or False
    )
    try:
        response = client.post("/api/v1/profile/adopt")
    finally:
        app.dependency_overrides.clear()

    assert response.status_code == 200
    body = response.json()
    assert body["firebase_uid"] == _NEW_UID
    assert body["profile"]["organization_name"] == "Helping Hands"
    assert calls == [_OLD_UID]
    assert fake.store["users"][0]["firebase_uid"] == _NEW_UID


def test_adopt_is_noop_for_current_uid(monkeypatch) -> None:
    """If the authenticated UID already owns a row, adopt is idempotent and
    never probes liveness or touches the row."""
    store = {"users": [_user_row(_NEW_UID)]}
    _install(monkeypatch, store, liveness=lambda uid: pytest.fail("must not probe liveness"))
    try:
        response = client.post("/api/v1/profile/adopt")
    finally:
        app.dependency_overrides.clear()

    assert response.status_code == 200
    assert response.json()["firebase_uid"] == _NEW_UID


def test_adopt_404_when_nothing_matches(monkeypatch) -> None:
    """Genuinely new email -> 404 so the caller enrolls normally."""
    store = {"users": [_user_row(_OLD_UID, row_id="other", role="provider")]}
    store["users"][0]["email"] = "someone.else@example.com"
    _install(monkeypatch, store)
    try:
        response = client.post("/api/v1/profile/adopt")
    finally:
        app.dependency_overrides.clear()

    assert response.status_code == 404


def test_adopt_refuses_live_account(monkeypatch) -> None:
    """If the matching row still has a LIVE Firebase user, do not hijack it."""
    store = {"users": [_user_row(_OLD_UID)]}
    fake = _install(monkeypatch, store, liveness=lambda uid: True)
    try:
        response = client.post("/api/v1/profile/adopt")
    finally:
        app.dependency_overrides.clear()

    assert response.status_code == 409
    assert fake.store["users"][0]["firebase_uid"] == _OLD_UID


def test_adopt_requires_verified_email(monkeypatch) -> None:
    """An unverified token email is not trusted to claim an existing row."""
    store = {"users": [_user_row(_OLD_UID)]}
    fake = _install(monkeypatch, store, verified=False)
    try:
        response = client.post("/api/v1/profile/adopt")
    finally:
        app.dependency_overrides.clear()

    assert response.status_code == 404
    assert fake.store["users"][0]["firebase_uid"] == _OLD_UID
