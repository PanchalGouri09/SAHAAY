"""
Tests for the real, database-backed Public Impact Leaderboard (FR-19).

Drives the real FastAPI routes against a fake Supabase that models only the
postgrest calls used by app/routers/leaderboard.py. Firebase auth is overridden
so the 401 gate and every aggregation branch can be asserted without tokens or
a live database.

Required coverage:
* unauthenticated -> 401
* nobody opted in -> honest empty list (never seeded/demo rows)
* only organizations whose owner set `leaderboard_public = true` appear
* providers are credited for their published donations; NGOs only for the
  donations their accepted/completed claim received (pending claims excluded)
* ranking is by real redistributed kilograms (descending), ties by meals
* an impact row that recorded no real weight/meals is not a ranking
* the visibility endpoint writes only the caller's own users row
* no response exposes firebase_uid
"""

from __future__ import annotations

from types import SimpleNamespace

import pytest
from fastapi.testclient import TestClient

from app.dependencies import get_current_profile
from app.main import app

client = TestClient(app)


class _FakeTable:
    def __init__(self, rows: list[dict]) -> None:
        self._rows = rows
        self._filters: list[tuple[str, object]] = []
        self._update: dict | None = None

    def select(self, *args, **kwargs) -> "_FakeTable":
        return self

    def eq(self, key: str, value: object) -> "_FakeTable":
        self._filters.append((key, value))
        return self

    def update(self, values: dict) -> "_FakeTable":
        self._update = values
        return self

    def _matching(self) -> list[dict]:
        rows = list(self._rows)
        for key, value in self._filters:
            rows = [r for r in rows if r.get(key) == value]
        return rows

    def execute(self) -> SimpleNamespace:
        matched = self._matching()
        if self._update is not None:
            for row in matched:
                row.update(self._update)
        return SimpleNamespace(data=[dict(r) for r in matched])


class _FakeSupabase:
    def __init__(self) -> None:
        self.tables: dict[str, list[dict]] = {}

    def table(self, name: str) -> _FakeTable:
        return _FakeTable(self.tables.setdefault(name, []))

    def seed(self, name: str, rows: list[dict]) -> None:
        self.tables.setdefault(name, []).extend(list(rows))


def _seed(fake: _FakeSupabase) -> None:
    fake.seed("users", [
        {"id": "u-provider-public", "role": "provider", "leaderboard_public": True},
        {"id": "u-provider-private", "role": "provider", "leaderboard_public": False},
        {"id": "u-ngo-public", "role": "ngo", "leaderboard_public": True},
    ])
    fake.seed("providers", [
        {"id": "provider-1", "user_id": "u-provider-public",
         "organization_name": "Spice Garden", "city": "Pune"},
        {"id": "provider-2", "user_id": "u-provider-private",
         "organization_name": "Hidden Kitchen", "city": "Pune"},
    ])
    fake.seed("ngos", [
        {"id": "ngo-1", "user_id": "u-ngo-public",
         "organization_name": "Helping Hands", "city": "Pune"},
    ])
    fake.seed("donations", [
        {"id": "don-1", "provider_id": "provider-1"},
        {"id": "don-2", "provider_id": "provider-1"},
        {"id": "don-3", "provider_id": "provider-2"},
    ])
    fake.seed("claims", [
        {"donation_id": "don-1", "ngo_id": "ngo-1", "status": "accepted"},
        {"donation_id": "don-2", "ngo_id": "ngo-1", "status": "pending"},
        {"donation_id": "don-3", "ngo_id": "ngo-1", "status": "completed"},
    ])
    fake.seed("impact_records", [
        {"donation_id": "don-1", "food_weight_kg": 10, "meals_rescued": 20,
         "estimated_co2_saved": 5},
        {"donation_id": "don-2", "food_weight_kg": 4, "meals_rescued": 8,
         "estimated_co2_saved": 2},
        {"donation_id": "don-3", "food_weight_kg": 6, "meals_rescued": 12,
         "estimated_co2_saved": 3},
    ])


@pytest.fixture
def leaderboard_ctx(monkeypatch: pytest.MonkeyPatch):
    fake = _FakeSupabase()
    _seed(fake)
    monkeypatch.setattr("app.routers.leaderboard.get_supabase_client", lambda: fake)
    monkeypatch.setattr("app.routers.profile.get_supabase_client", lambda: fake)
    app.dependency_overrides[get_current_profile] = lambda: {
        "id": "u-provider-public",
        "role": "provider",
    }
    yield fake
    app.dependency_overrides.clear()


def test_leaderboard_requires_authentication() -> None:
    response = client.get("/api/v1/leaderboard")
    assert response.status_code == 401


def test_leaderboard_ranks_real_impact_and_respects_opt_in(leaderboard_ctx) -> None:
    response = client.get("/api/v1/leaderboard")
    assert response.status_code == 200
    body = response.json()
    entries = body["entries"]

    # Two orgs are opted in with real impact; "Hidden Kitchen" is opted out.
    assert [e["name"] for e in entries] == ["Helping Hands", "Spice Garden"]

    ngo, provider = entries
    assert ngo["rank"] == 1 and ngo["type"] == "ngo"
    # NGO received don-1 (accepted) + don-3 (completed); don-2 is only pending.
    assert ngo["kg_redistributed"] == 16.0
    assert ngo["meals_rescued"] == 32
    assert ngo["donations"] == 2

    assert provider["rank"] == 2 and provider["type"] == "provider"
    assert provider["kg_redistributed"] == 14.0
    assert provider["meals_rescued"] == 28
    assert provider["donations"] == 2

    assert "Hidden Kitchen" not in [e["name"] for e in entries]
    assert "generated_at" in body


def test_leaderboard_is_empty_when_nobody_opted_in(monkeypatch, leaderboard_ctx) -> None:
    leaderboard_ctx.tables["users"] = [
        {"id": "u-provider-private", "role": "provider", "leaderboard_public": False},
    ]
    response = client.get("/api/v1/leaderboard")
    assert response.status_code == 200
    assert response.json()["entries"] == []


def test_leaderboard_ignores_zero_impact_records(leaderboard_ctx) -> None:
    # A real recorded row that carries no weight and no meals is not a ranking.
    leaderboard_ctx.tables["impact_records"] = [
        {"donation_id": "don-1", "food_weight_kg": None, "meals_rescued": 0,
         "estimated_co2_saved": None},
    ]
    response = client.get("/api/v1/leaderboard")
    assert response.status_code == 200
    assert response.json()["entries"] == []


def test_leaderboard_never_exposes_credentials(leaderboard_ctx) -> None:
    body = client.get("/api/v1/leaderboard").text
    assert "firebase_uid" not in body
    assert "email" not in body
    assert "phone" not in body


def test_visibility_endpoint_writes_own_row(leaderboard_ctx) -> None:
    response = client.patch(
        "/api/v1/profile/leaderboard-visibility", json={"public": False}
    )
    assert response.status_code == 200
    assert response.json() == {"status": "ok", "leaderboard_public": False}

    row = next(
        u for u in leaderboard_ctx.tables["users"] if u["id"] == "u-provider-public"
    )
    assert row["leaderboard_public"] is False
    # Another account is untouched.
    other = next(
        u for u in leaderboard_ctx.tables["users"] if u["id"] == "u-ngo-public"
    )
    assert other["leaderboard_public"] is True


def test_visibility_endpoint_rejects_non_boolean(leaderboard_ctx) -> None:
    response = client.patch(
        "/api/v1/profile/leaderboard-visibility", json={"public": "yes"}
    )
    assert response.status_code == 422
