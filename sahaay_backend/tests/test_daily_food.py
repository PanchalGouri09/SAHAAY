"""
Tests for the mandatory DAILY FOOD ENTRY flow
(app/routers/daily_food.py) and for the provider gate it powers.

A daily food entry is NOT a donation, so two things are asserted throughout:
  * nothing is ever written to the `donations` table, and
  * no endpoint ever hands back another provider's row.

Boundaries mocked (test-only), matching the existing test convention:
  * AI HTTP transport -> httpx.MockTransport, so the REAL AIClient and the
    real SurplusPredictionRequest validation run. The AI service is not
    reimplemented or bypassed.
  * Supabase -> an in-memory recording double that actually stores rows and
    really enforces the (provider_id, entry_date) unique index, so the
    duplicate-entry path is exercised rather than asserted about a log line.
  * Auth -> dependency_overrides on the shared get_current_profile, the same
    dependency require_role("provider") consumes.

The test also proves the AI request body is exactly the existing contract and
that no provider identity is ever sent to the AI service.
"""

from __future__ import annotations

import json
from datetime import date

import httpx
import pytest
from fastapi.testclient import TestClient

from app.main import app
from app.dependencies import get_current_profile
from app.services.ai_client import AIClient, get_ai_client

client_session = TestClient(app)

TODAY = date.today().isoformat()


# ---------------------------------------------------------------------------
# In-memory Supabase double (test-only)
# ---------------------------------------------------------------------------
class _UniqueViolation(Exception):
    """Stands in for a Postgres 23505 unique_violation."""

    code = "23505"


class _Result:
    def __init__(self, data: list[dict]) -> None:
        self.data = data


class _FakeTable:
    def __init__(self, name: str, store: dict[str, list[dict]], log: list) -> None:
        self._name = name
        self._store = store
        self._log = log
        # supabase-py chains read as .insert(v).select().execute() /
        # .update(v).eq(k, v).select().execute() / .select("*").eq(k, v).execute().
        # A trailing .select() asks for the affected rows, it does not change
        # the operation, so `_op` and `_return_rows` are tracked separately.
        self._op: str | None = None
        self._return_rows = False
        self._filters: dict[str, object] = {}
        self._order: tuple[str, bool] | None = None
        self._limit: int | None = None
        self._pending: dict | None = None
        self._update_vals: dict | None = None

    def select(self, *cols: str) -> "_FakeTable":
        self._return_rows = True
        return self

    def insert(self, values: dict) -> "_FakeTable":
        self._op = "insert"
        self._log.append(("insert", self._name, dict(values)))
        self._pending = dict(values)
        return self

    def update(self, values: dict) -> "_FakeTable":
        self._op = "update"
        self._log.append(("update", self._name, dict(values)))
        self._update_vals = dict(values)
        return self

    def eq(self, key: str, value: object) -> "_FakeTable":
        self._filters[key] = value
        return self

    def order(self, key: str, desc: bool = False) -> "_FakeTable":
        self._order = (key, desc)
        return self

    def limit(self, count: int) -> "_FakeTable":
        self._limit = count
        return self

    def single(self) -> "_FakeTable":
        return self

    def maybe_single(self) -> "_FakeTable":
        return self

    def execute(self) -> _Result:
        if self._op == "insert":
            return self._insert()
        if self._op == "update":
            return self._update()
        return self._select()

    def _rows(self) -> list[dict]:
        return self._store.setdefault(self._name, [])

    def _insert(self) -> _Result:
        row = dict(self._pending or {})
        if self._name == "daily_food_entries":
            # Really enforce UNIQUE(provider_id, entry_date).
            for existing in self._rows():
                if (
                    existing.get("provider_id"),
                    existing.get("entry_date"),
                ) == (row.get("provider_id"), row.get("entry_date")):
                    raise _UniqueViolation(
                        "duplicate key value violates unique constraint "
                        "daily_food_entries_provider_date_key"
                    )
            row.setdefault("id", f"entry-{len(self._rows()) + 1}")
            row.setdefault("created_at", "2026-09-27T09:00:00+00:00")
            row.setdefault("updated_at", "2026-09-27T09:00:00+00:00")
            # The router never sends prediction_id on insert; Postgres still
            # returns the nullable column as NULL, as PostgREST does.
            row.setdefault("prediction_id", None)
            self._rows().append(row)
            return _Result([row])
        if self._name == "food_predictions":
            row.setdefault("id", f"pred-{len(self._rows()) + 1}")
            self._rows().append(row)
            return _Result([row])
        return _Result([row])

    def _update(self) -> _Result:
        matched = [r for r in self._rows() if self._matches(r)]
        for row in matched:
            row.update(self._update_vals or {})
        return _Result([dict(r) for r in matched])

    def _select(self) -> _Result:
        rows = [dict(r) for r in self._store.get(self._name, []) if self._matches(r)]
        if self._order is not None:
            key, desc = self._order
            rows.sort(key=lambda r: str(r.get(key) or ""), reverse=desc)
        if self._limit is not None:
            rows = rows[: self._limit]
        return _Result(rows)

    def _matches(self, row: dict) -> bool:
        return all(row.get(key) == value for key, value in self._filters.items())


class _FakeSupabase:
    def __init__(self) -> None:
        self.log: list[tuple] = []
        self.store: dict[str, list[dict]] = {}

    def table(self, name: str) -> _FakeTable:
        return _FakeTable(name, self.store, self.log)

    def seed(self, table: str, rows: list[dict]) -> None:
        self.store.setdefault(table, []).extend(rows)


# ---------------------------------------------------------------------------
# Mock AI transport. Records every surplus-prediction request body.
# ---------------------------------------------------------------------------
def _make_ai_transport(
    *, fail: bool = False, calls: list[dict] | None = None
):
    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path != "/api/v1/prediction/predict-surplus":
            return httpx.Response(404, json={"detail": "not found"})
        payload = json.loads(request.content)
        if calls is not None:
            calls.append(payload)
        if fail:
            raise httpx.ConnectError("connection refused to AI")
        return httpx.Response(
            200,
            json={
                "predicted_surplus_kg": 12.5,
                "preparation_recommendation": "Prepare a bit less next time",
                "recommended_prepare_kg": 40.0,
                "input_echo": payload,
                "model_version": "v1",
            },
        )

    return handler


def _install_ai(*, fail: bool = False, calls: list[dict] | None = None) -> None:
    app.dependency_overrides[get_ai_client] = lambda: AIClient(
        base_url="http://ai.test",
        timeout=5.0,
        transport=httpx.MockTransport(_make_ai_transport(fail=fail, calls=calls)),
    )


def _provider_profile() -> dict:
    return {
        "id": "user-FAKE-001",
        "role": "provider",
        "providers": [{"id": "provider-FAKE-001"}],
    }


def _other_provider_profile() -> dict:
    return {
        "id": "user-FAKE-002",
        "role": "provider",
        "providers": [{"id": "provider-FAKE-002"}],
    }


def _body(**overrides) -> dict:
    payload = {
        "food_category": "Cooked Meals",
        "food_prepared_kg": 50.0,
        "food_sold_kg": 38.0,
    }
    payload.update(overrides)
    return payload


@pytest.fixture
def fake_supabase(monkeypatch: pytest.MonkeyPatch) -> _FakeSupabase:
    fake = _FakeSupabase()
    monkeypatch.setattr(
        "app.routers.daily_food.get_supabase_client", lambda: fake
    )
    app.dependency_overrides[get_current_profile] = lambda: _provider_profile()
    yield fake
    app.dependency_overrides.clear()


def _entries(fake: _FakeSupabase) -> list[dict]:
    return fake.store.get("daily_food_entries", [])


def _no_donation_writes(fake: _FakeSupabase) -> None:
    """A daily food entry must never create or touch a donation."""
    assert not [op for op in fake.log if op[1] == "donations"]


# ---------------------------------------------------------------------------
# 1. Provider can create today's entry.
# ---------------------------------------------------------------------------
def test_provider_can_create_todays_entry(fake_supabase) -> None:
    _install_ai()

    response = client_session.post("/api/v1/daily-food", json=_body())

    assert response.status_code == 200
    body = response.json()
    assert body["provider_id"] == "provider-FAKE-001"
    assert body["entry_date"] == TODAY
    assert float(body["food_prepared_kg"]) == 50.0
    assert float(body["food_sold_kg"]) == 38.0
    assert body["prediction"]["status"] == "saved"
    # The entry lands in its own table and nowhere else.
    assert len(_entries(fake_supabase)) == 1
    _no_donation_writes(fake_supabase)


def test_meal_type_is_stored_when_supplied(fake_supabase) -> None:
    _install_ai()

    response = client_session.post(
        "/api/v1/daily-food", json=_body(meal_type="lunch")
    )

    assert response.status_code == 200
    assert _entries(fake_supabase)[0]["meal_type"] == "lunch"


def test_meal_type_may_be_omitted(fake_supabase) -> None:
    _install_ai()

    response = client_session.post("/api/v1/daily-food", json=_body())

    assert response.status_code == 200
    assert _entries(fake_supabase)[0]["meal_type"] is None


# ---------------------------------------------------------------------------
# 2. Provider cannot create two entries for the same date.
# ---------------------------------------------------------------------------
def test_duplicate_entry_for_same_date_is_rejected(fake_supabase) -> None:
    _install_ai()

    first = client_session.post("/api/v1/daily-food", json=_body())
    second = client_session.post("/api/v1/daily-food", json=_body())

    assert first.status_code == 200
    assert second.status_code == 409
    assert "already been submitted" in second.json()["detail"]
    assert len(_entries(fake_supabase)) == 1


# ---------------------------------------------------------------------------
# 3. Provider cannot create or read another provider's entry.
# ---------------------------------------------------------------------------
def test_client_supplied_provider_id_is_ignored(fake_supabase) -> None:
    """The client must never be able to choose the owning provider."""
    _install_ai()

    response = client_session.post(
        "/api/v1/daily-food",
        json=_body(provider_id="provider-FAKE-002", entry_date="1999-01-01"),
    )

    assert response.status_code == 200
    stored = _entries(fake_supabase)[0]
    assert stored["provider_id"] == "provider-FAKE-001"
    assert stored["entry_date"] == TODAY


def test_history_never_returns_another_providers_entries(fake_supabase) -> None:
    fake_supabase.seed(
        "daily_food_entries",
        [
            {
                "id": "mine",
                "provider_id": "provider-FAKE-001",
                "entry_date": TODAY,
                "food_category": "Cooked Meals",
                "food_prepared_kg": 10,
                "food_sold_kg": 4,
            },
            {
                "id": "theirs",
                "provider_id": "provider-FAKE-002",
                "entry_date": TODAY,
                "food_category": "Bakery",
                "food_prepared_kg": 99,
                "food_sold_kg": 1,
            },
        ],
    )
    _install_ai()

    response = client_session.get("/api/v1/daily-food/history")

    assert response.status_code == 200
    rows = response.json()["data"]
    assert [r["id"] for r in rows] == ["mine"]
    assert all(r["provider_id"] == "provider-FAKE-001" for r in rows)


def test_today_never_returns_another_providers_entry(fake_supabase) -> None:
    fake_supabase.seed(
        "daily_food_entries",
        [
            {
                "id": "theirs",
                "provider_id": "provider-FAKE-002",
                "entry_date": TODAY,
                "food_category": "Dairy",
                "food_prepared_kg": 5,
                "food_sold_kg": 1,
            }
        ],
    )
    _install_ai()

    response = client_session.get("/api/v1/daily-food/today")

    assert response.status_code == 200
    assert response.json()["entry_required"] is True
    assert response.json()["data"] is None


def test_two_providers_each_get_their_own_entry(fake_supabase) -> None:
    """One provider's entry must not block another provider's entry."""
    _install_ai()
    first = client_session.post("/api/v1/daily-food", json=_body())
    app.dependency_overrides[get_current_profile] = lambda: _other_provider_profile()
    second = client_session.post("/api/v1/daily-food", json=_body(food_category="Bakery"))

    assert first.status_code == 200
    assert second.status_code == 200
    assert {e["provider_id"] for e in _entries(fake_supabase)} == {
        "provider-FAKE-001",
        "provider-FAKE-002",
    }


# ---------------------------------------------------------------------------
# 4-8. Validation, all rejected before anything is written.
# ---------------------------------------------------------------------------
def test_missing_prepared_kg_is_rejected(fake_supabase) -> None:
    _install_ai()
    body = _body()
    body.pop("food_prepared_kg")

    response = client_session.post("/api/v1/daily-food", json=body)

    assert response.status_code == 422
    assert "food_prepared_kg" in str(response.json()["detail"])
    assert not _entries(fake_supabase)


def test_missing_sold_kg_is_rejected(fake_supabase) -> None:
    _install_ai()
    body = _body()
    body.pop("food_sold_kg")

    response = client_session.post("/api/v1/daily-food", json=body)

    assert response.status_code == 422
    assert "food_sold_kg" in str(response.json()["detail"])
    assert not _entries(fake_supabase)


def test_sold_greater_than_prepared_is_rejected(fake_supabase) -> None:
    _install_ai()

    response = client_session.post(
        "/api/v1/daily-food", json=_body(food_prepared_kg=20.0, food_sold_kg=50.0)
    )

    assert response.status_code == 422
    assert "cannot exceed" in str(response.json()["detail"])
    assert not _entries(fake_supabase)


def test_zero_prepared_kg_is_rejected(fake_supabase) -> None:
    _install_ai()

    response = client_session.post(
        "/api/v1/daily-food", json=_body(food_prepared_kg=0.0, food_sold_kg=0.0)
    )

    assert response.status_code == 422
    assert not _entries(fake_supabase)


def test_negative_prepared_kg_is_rejected(fake_supabase) -> None:
    _install_ai()

    response = client_session.post(
        "/api/v1/daily-food", json=_body(food_prepared_kg=-5.0, food_sold_kg=0.0)
    )

    assert response.status_code == 422
    assert not _entries(fake_supabase)


def test_negative_sold_kg_is_rejected(fake_supabase) -> None:
    _install_ai()

    response = client_session.post(
        "/api/v1/daily-food", json=_body(food_prepared_kg=10.0, food_sold_kg=-1.0)
    )

    assert response.status_code == 422
    assert not _entries(fake_supabase)


def test_invalid_category_is_rejected_before_ai(fake_supabase) -> None:
    calls: list[dict] = []
    _install_ai(calls=calls)

    response = client_session.post(
        "/api/v1/daily-food", json=_body(food_category="Sushi Fusion")
    )

    assert response.status_code == 422
    assert not _entries(fake_supabase)
    assert calls == []  # the AI service is never called for an unmappable category


def test_other_category_is_rejected_because_ai_cannot_map_it(fake_supabase) -> None:
    """'Other' has no AI mapping, so it is rejected rather than guessed."""
    _install_ai()

    response = client_session.post(
        "/api/v1/daily-food", json=_body(food_category="Other")
    )

    assert response.status_code == 422
    assert not _entries(fake_supabase)


@pytest.mark.parametrize(
    "category,expected",
    [
        ("Cooked Meals", "cooked"),
        ("Rice", "cooked"),
        ("Bread", "bakery"),
        ("Bakery", "bakery"),
        ("Dairy", "dairy"),
        ("Packaged Food", "packaged"),
        ("Fruits", "raw"),
        ("Vegetables", "raw"),
    ],
)
def test_every_ai_mappable_category_is_accepted(
    fake_supabase, category: str, expected: str
) -> None:
    calls: list[dict] = []
    _install_ai(calls=calls)

    response = client_session.post(
        "/api/v1/daily-food", json=_body(food_category=category)
    )

    assert response.status_code == 200
    assert calls[0]["food_category"] == expected


def test_non_provider_cannot_create_entry(fake_supabase) -> None:
    _install_ai()
    app.dependency_overrides[get_current_profile] = lambda: {
        "id": "ngo-user-1",
        "role": "ngo",
        "ngos": [{"id": "ngo-1"}],
    }

    response = client_session.post("/api/v1/daily-food", json=_body())

    assert response.status_code == 403
    assert not _entries(fake_supabase)


def test_endpoints_require_authentication() -> None:
    app.dependency_overrides.clear()
    unauthorized = (
        client_session.post("/api/v1/daily-food", json=_body()),
        client_session.get("/api/v1/daily-food/today"),
        client_session.get("/api/v1/daily-food/history"),
    )
    for response in unauthorized:
        assert response.status_code in (401, 403), response.request.url


# ---------------------------------------------------------------------------
# 9. A successful entry calls the EXISTING AI prediction service.
# ---------------------------------------------------------------------------
def test_successful_entry_calls_existing_ai_service(fake_supabase) -> None:
    calls: list[dict] = []
    _install_ai(calls=calls)

    response = client_session.post("/api/v1/daily-food", json=_body())

    assert response.status_code == 200
    assert len(calls) == 1
    # Exactly the existing AI request contract — no extra and no missing keys.
    assert set(calls[0]) == {
        "food_prepared_kg",
        "food_sold_kg",
        "food_category",
        "day_of_week",
        "date",
    }
    assert calls[0]["food_prepared_kg"] == 50.0
    assert calls[0]["food_sold_kg"] == 38.0
    assert calls[0]["food_category"] == "cooked"
    # day_of_week and date are derived server-side from the entry date.
    assert calls[0]["date"] == TODAY
    assert calls[0]["day_of_week"] == date.today().strftime("%A")


def test_provider_identity_is_never_sent_to_the_ai_service(fake_supabase) -> None:
    calls: list[dict] = []
    _install_ai(calls=calls)

    client_session.post("/api/v1/daily-food", json=_body())

    body = json.dumps(calls[0])
    assert "provider" not in body.lower()
    assert "provider-FAKE-001" not in body


def test_prediction_values_are_returned_from_the_ai_response(fake_supabase) -> None:
    _install_ai()

    response = client_session.post("/api/v1/daily-food", json=_body())

    prediction = response.json()["prediction"]
    assert prediction["status"] == "saved"
    assert prediction["predicted_surplus_kg"] == 12.5
    assert prediction["recommended_prepare_kg"] == 40.0
    assert prediction["preparation_recommendation"] == "Prepare a bit less next time"


# ---------------------------------------------------------------------------
# 10. The prediction is persisted and linked.
# ---------------------------------------------------------------------------
def test_prediction_is_persisted_and_linked(fake_supabase) -> None:
    _install_ai()

    response = client_session.post("/api/v1/daily-food", json=_body())

    stored_predictions = fake_supabase.store["food_predictions"]
    assert len(stored_predictions) == 1
    row = stored_predictions[0]
    assert row["provider_id"] == "provider-FAKE-001"
    assert row["prediction_date"] == TODAY
    assert row["day_of_week"] == date.today().strftime("%A")
    assert row["predicted_surplus"] == 12.5
    assert row["recommendation"] == "Prepare a bit less next time"
    assert row["model_version"] == "v1"
    # The existing integer planned_quantity column is filled, not redesigned.
    assert row["planned_quantity"] == 40
    # The entry carries the new prediction id.
    assert _entries(fake_supabase)[0]["prediction_id"] == row["id"]
    assert response.json()["prediction_id"] == row["id"]


def test_ai_unreachable_still_saves_the_entry(fake_supabase) -> None:
    """Same non-fatal behavior the donation flow already has."""
    _install_ai(fail=True)

    response = client_session.post("/api/v1/daily-food", json=_body())

    assert response.status_code == 200
    assert len(_entries(fake_supabase)) == 1
    assert _entries(fake_supabase)[0]["prediction_id"] is None
    assert response.json()["prediction"]["status"] == "skipped"


# ---------------------------------------------------------------------------
# 11. GET /today returns the entry (and gates when it is missing).
# ---------------------------------------------------------------------------
def test_get_today_returns_the_entry(fake_supabase) -> None:
    _install_ai()
    client_session.post("/api/v1/daily-food", json=_body())

    response = client_session.get("/api/v1/daily-food/today")

    assert response.status_code == 200
    body = response.json()
    assert body["entry_required"] is False
    assert body["data"]["provider_id"] == "provider-FAKE-001"
    assert body["prediction"]["status"] == "saved"
    assert body["prediction"]["predicted_surplus_kg"] == 12.5
    assert body["prediction"]["prediction_date"] == TODAY


def test_get_today_reports_missing_entry_without_raising(fake_supabase) -> None:
    _install_ai()

    response = client_session.get("/api/v1/daily-food/today")

    assert response.status_code == 200
    body = response.json()
    assert body["entry_required"] is True
    assert body["data"] is None
    assert body["prediction"] is None
    assert body["entry_date"] == TODAY


def test_get_today_reports_a_failed_prediction_without_raising(fake_supabase) -> None:
    _install_ai(fail=True)
    client_session.post("/api/v1/daily-food", json=_body())

    response = client_session.get("/api/v1/daily-food/today")

    assert response.status_code == 200
    body = response.json()
    assert body["entry_required"] is False
    assert body["prediction"]["status"] == "unavailable"


# ---------------------------------------------------------------------------
# 12. GET /history is provider-scoped and newest-first.
# ---------------------------------------------------------------------------
def test_get_history_returns_only_current_providers_entries(fake_supabase) -> None:
    fake_supabase.seed(
        "daily_food_entries",
        [
            {"id": "a", "provider_id": "provider-FAKE-001", "entry_date": "2026-09-25"},
            {"id": "b", "provider_id": "provider-FAKE-001", "entry_date": "2026-09-26"},
            {"id": "c", "provider_id": "provider-FAKE-002", "entry_date": "2026-09-27"},
        ],
    )
    _install_ai()

    response = client_session.get("/api/v1/daily-food/history")

    assert response.status_code == 200
    rows = response.json()["data"]
    assert [r["id"] for r in rows] == ["b", "a"]  # newest first
    assert all(r["provider_id"] == "provider-FAKE-001" for r in rows)


def test_get_history_is_empty_when_nothing_recorded(fake_supabase) -> None:
    _install_ai()

    response = client_session.get("/api/v1/daily-food/history")

    assert response.status_code == 200
    assert response.json()["data"] == []


def test_get_history_exposes_no_donation_fields(fake_supabase) -> None:
    """A daily entry carries no donation-shaped data."""
    _install_ai()
    client_session.post("/api/v1/daily-food", json=_body())

    row = client_session.get("/api/v1/daily-food/history").json()["data"][0]

    for forbidden in (
        "quantity",
        "unit",
        "servings",
        "pickup_address",
        "expiry_time",
        "pickup_deadline",
        "status",
        "ngo_id",
        "food_image_url",
    ):
        assert forbidden not in row, forbidden


# ---------------------------------------------------------------------------
# 13-14. The gate itself.
# ---------------------------------------------------------------------------
def test_provider_without_todays_entry_is_gated(fake_supabase) -> None:
    """13. The backend is the authority: no entry -> entry_required."""
    _install_ai()

    response = client_session.get("/api/v1/daily-food/today")

    assert response.status_code == 200
    assert response.json()["entry_required"] is True


def test_provider_with_todays_entry_is_not_blocked(fake_supabase) -> None:
    """14. After a successful entry the gate opens and stays open."""
    _install_ai()
    client_session.post("/api/v1/daily-food", json=_body())

    first = client_session.get("/api/v1/daily-food/today")
    second = client_session.get("/api/v1/daily-food/today")

    assert first.json()["entry_required"] is False
    # Re-checking does not re-open the form.
    assert second.json()["entry_required"] is False


# ---------------------------------------------------------------------------
# 15. A daily entry must not disturb the existing donation flow.
# ---------------------------------------------------------------------------
def test_daily_entry_does_not_create_a_donation(fake_supabase) -> None:
    _install_ai()

    client_session.post("/api/v1/daily-food", json=_body())

    _no_donation_writes(fake_supabase)
    assert list(fake_supabase.store.keys()) == ["daily_food_entries", "food_predictions"]
