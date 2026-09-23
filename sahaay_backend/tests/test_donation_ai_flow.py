"""
Focused tests for the Phase-1 provider donation -> AI safety -> surplus
prediction -> Supabase persistence flow (app/routers/donations.create_donation).

Boundaries mocked (test-only), as allowed by the task:
  * AI HTTP transport -> httpx.MockTransport, so the REAL AIClient (typed
    request construction, response-model validation, verdict literals, error
    mapping) runs end to end. No part of the AI logic is reimplemented or
    bypassed in production code.
  * Supabase -> recording fake, so nothing touches a live DB and no secrets
    are needed. Tests assert WHERE the router attempted to persist (donations
    vs food_predictions) and whether it wrote at all.
  * Auth -> dependency_overrides on the shared get_current_profile, the exact
    dependency require_role("provider") and every route consume, so no
    Firebase token / Supabase profile query is performed.

These are controlled integration-behavior tests; they do not judge AI "science".
"""

from __future__ import annotations

from typing import Callable

import httpx
import pytest
from fastapi.testclient import TestClient

from app.main import app
from app.dependencies import get_current_profile
from app.services.ai_client import AIClient, get_ai_client

client_session = TestClient(app)


# ---------------------------------------------------------------------------
# Recording fake Supabase (test-only)
# ---------------------------------------------------------------------------
class _FakeTable:
    def __init__(self, name: str, log: list[tuple]) -> None:
        self._name = name
        self._log = log
        self._pending: dict | None = None
        self._update_vals: dict | None = None

    def insert(self, values: dict) -> "_FakeTable":
        self._log.append(("insert", self._name, values))
        self._pending = dict(values)
        return self

    def update(self, values: dict) -> "_FakeTable":
        self._log.append(("update", self._name, values))
        self._update_vals = values
        return self

    def select(self, *cols: str) -> "_FakeTable":
        return self

    def eq(self, key: str, value: object) -> "_FakeTable":
        return self

    def single(self) -> "_FakeTable":
        return self

    def execute(self):
        row = self._pending or {}
        row.setdefault("id", "don-row-1" if self._name == "donations" else "pred-row-1")
        if self._update_vals:
            row.update(self._update_vals)
        return type("R", (), {"data": [row]})()

    def __getattr__(self, item):
        return lambda *a, **k: self


class _FakeSupabase:
    def __init__(self) -> None:
        self.log: list[tuple] = []
        self._bucket_exists = False

    def table(self, name: str) -> _FakeTable:
        return _FakeTable(name, self.log)

    @property
    def storage(self) -> "_FakeStorage":
        return _FakeStorage(self)


class _FakeStorageBucket:
    def __init__(self, owner: "_FakeSupabase") -> None:
        self._owner = owner

    def upload(self, path: str, data: bytes, file_options: dict | None = None) -> object:
        self._owner.log.append(("storage.upload", path, len(data)))
        return type("R", (), {"path": path, "full_path": f"donations/{path}"})()

    def get_public_url(self, path: str) -> str:
        self._owner.log.append(("storage.get_public_url", path))
        return f"https://project.supabase.co/storage/v1/object/public/donations/{path}"


class _FakeStorage:
    def __init__(self, owner: "_FakeSupabase") -> None:
        self._owner = owner

    def get_bucket(self, bucket: str) -> dict:
        self._owner.log.append(("storage.get_bucket", bucket))
        if not self._owner._bucket_exists:
            raise RuntimeError("bucket missing")
        return {"id": bucket, "public": True}

    def create_bucket(self, bucket: str, options: dict | None = None) -> dict:
        self._owner.log.append(("storage.create_bucket", bucket))
        self._owner._bucket_exists = True
        return {"id": bucket}

    def from_(self, bucket: str) -> _FakeStorageBucket:
        return _FakeStorageBucket(self._owner)


# ---------------------------------------------------------------------------
# Mock AI transport factory. verdict mirrors the real service literals.
# raise_connect simulates the AI service being unreachable (transport error).
# ---------------------------------------------------------------------------
def _make_ai_transport(
    safety_verdict: str = "Eligible",
    *,
    raise_connect: bool = False,
) -> Callable[[httpx.Request], httpx.Response]:
    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path == "/api/v1/prediction/predict-surplus":
            return httpx.Response(
                200,
                json={
                    "predicted_surplus_kg": 12.5,
                    "preparation_recommendation": "Prepare a bit less next time",
                    "recommended_prepare_kg": 40.0,
                    "input_echo": {
                        "food_prepared_kg": 50.0,
                        "food_sold_kg": 38.0,
                        "food_category": "cooked",
                        "day_of_week": "Friday",
                        "date": "2026-08-28",
                    },
                    "model_version": "v1",
                },
            )
        if request.url.path == "/api/v1/safety/verify":
            if raise_connect:
                raise httpx.ConnectError("connection refused to AI")
            if safety_verdict == "Not Eligible":
                return httpx.Response(
                    200,
                    json={
                        "donation_id": "pending-1",
                        "verdict": "Not Eligible",
                        "hours_since_preparation": 8.0,
                        "reasons": ["Prepared too long ago."],
                    },
                )
            if safety_verdict == "Requires Manual Review":
                return httpx.Response(
                    200,
                    json={
                        "donation_id": "pending-1",
                        "verdict": "Requires Manual Review",
                        "hours_since_preparation": 3.5,
                        "reasons": ["Dairy stored at room temperature."],
                    },
                )
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

    return handler


def _provider_profile() -> dict:
    return {
        "id": "user-FAKE-001",
        "role": "provider",
        "providers": [{"id": "provider-FAKE-001"}],
    }


def _install_ai(transport) -> None:
    app.dependency_overrides[get_ai_client] = lambda: AIClient(
        base_url="http://ai.test",
        timeout=5.0,
        transport=httpx.MockTransport(transport),
    )


def _base_donation(**overrides) -> dict:
    payload = {
        "food_name": "Vegetable Rice",
        "food_category": "Cooked Meals",
        "quantity": 10.0,
        "unit": "servings",
        "veg_type": "vegetarian",
        "food_image_url": "https://project.supabase.co/storage/v1/object/public/donations/food-photos/provider-FAKE-001/photo.png",
        "storage_condition": "refrigerated",
        "prepared_at": "2026-08-28T12:00:00Z",
        "expiry_time": "2026-08-28T20:00:00Z",
        "pickup_deadline": "2026-08-28T18:00:00Z",
        "pickup_address": "123 MG Road, Pune",
    }
    payload.update(overrides)
    return payload


@pytest.fixture
def fake_supabase(monkeypatch: pytest.MonkeyPatch) -> _FakeSupabase:
    """Install a recording Supabase double in the router module namespace and
    a provider profile override for the shared auth dependency."""
    fake = _FakeSupabase()
    monkeypatch.setattr(
        "app.routers.donations.get_supabase_client", lambda: fake
    )
    app.dependency_overrides[get_current_profile] = lambda: _provider_profile()
    yield fake
    app.dependency_overrides.clear()


def _assert_created_in_donations(fake: _FakeSupabase) -> None:
    inserts = [op for op in fake.log if op[0] == "insert" and op[1] == "donations"]
    assert inserts, "expected a donations insert but the router wrote nothing"
    assert "provider_id" in inserts[0][2]
    assert inserts[0][2]["provider_id"] == "provider-FAKE-001"


def _assert_no_donations_insert(fake: _FakeSupabase) -> None:
    assert not [op for op in fake.log if op[0] == "insert" and op[1] == "donations"]


# ---------------------------------------------------------------------------
# Required test cases
# ---------------------------------------------------------------------------
def test_eligible_donation_calls_safety_and_is_created(fake_supabase) -> None:
    _install_ai(_make_ai_transport("Eligible", raise_connect=False))

    response = client_session.post("/api/v1/donations", json=_base_donation())

    assert response.status_code == 200
    assert response.json()["id"] == "don-row-1"
    assert response.json()["provider_id"] == "provider-FAKE-001"
    _assert_created_in_donations(fake_supabase)


def test_not_eligible_is_rejected_and_not_created(fake_supabase) -> None:
    _install_ai(_make_ai_transport("Not Eligible"))

    response = client_session.post("/api/v1/donations", json=_base_donation())

    assert response.status_code == 400
    assert "rejected" in response.json()["detail"]
    _assert_no_donations_insert(fake_supabase)


def test_requires_manual_review_is_not_silently_allowed(fake_supabase) -> None:
    _install_ai(_make_ai_transport("Requires Manual Review"))

    response = client_session.post("/api/v1/donations", json=_base_donation())

    assert response.status_code == 422
    _assert_no_donations_insert(fake_supabase)


def test_ai_unavailable_does_not_create_donation(fake_supabase) -> None:
    _install_ai(_make_ai_transport(raise_connect=True))

    response = client_session.post("/api/v1/donations", json=_base_donation())

    assert response.status_code == 503
    _assert_no_donations_insert(fake_supabase)


def test_prediction_persisted_when_inputs_provided(fake_supabase) -> None:
    _install_ai(_make_ai_transport("Eligible"))

    response = client_session.post(
        "/api/v1/donations",
        json=_base_donation(food_prepared_kg=50.0, food_sold_kg=38.0),
    )

    assert response.status_code == 200
    prediction = response.json().get("prediction")
    assert prediction is not None
    assert prediction["status"] == "saved"
    assert prediction["predicted_surplus_kg"] == 12.5
    # prediction persistence must be attempted against the CURRENT schema:
    assert ("insert", "food_predictions") in [
        (op[0], op[1]) for op in fake_supabase.log
    ]
    # and the donation gets linked to the prediction via the existing FK column
    assert ("update", "donations") in [(op[0], op[1]) for op in fake_supabase.log]


def test_skips_prediction_when_inputs_missing(fake_supabase) -> None:
    _install_ai(_make_ai_transport("Eligible"))

    response = client_session.post("/api/v1/donations", json=_base_donation())

    assert response.status_code == 200
    assert response.json().get("prediction") is None
    assert not [op for op in fake_supabase.log if op[1] == "food_predictions"]


def test_kg_inputs_are_persisted_when_provided(fake_supabase) -> None:
    _install_ai(_make_ai_transport("Eligible"))

    response = client_session.post(
        "/api/v1/donations",
        json=_base_donation(food_prepared_kg=50.0, food_sold_kg=38.0),
    )

    assert response.status_code == 200
    inserts = [op for op in fake_supabase.log if op[0] == "insert" and op[1] == "donations"]
    assert inserts[0][2]["food_prepared_kg"] == 50.0
    assert inserts[0][2]["food_sold_kg"] == 38.0
    # storage_condition stays an AI-only transient input: persisted nowhere.
    assert "storage_condition" not in inserts[0][2]


def test_only_prepared_kg_rejected_before_insert(fake_supabase) -> None:
    _install_ai(_make_ai_transport("Eligible"))

    response = client_session.post(
        "/api/v1/donations", json=_base_donation(food_prepared_kg=50.0)
    )

    assert response.status_code == 422
    _assert_no_donations_insert(fake_supabase)


def test_only_sold_kg_rejected_before_insert(fake_supabase) -> None:
    _install_ai(_make_ai_transport("Eligible"))

    response = client_session.post(
        "/api/v1/donations", json=_base_donation(food_sold_kg=38.0)
    )

    assert response.status_code == 422
    _assert_no_donations_insert(fake_supabase)


def test_sold_exceeding_prepared_rejected_before_insert(fake_supabase) -> None:
    _install_ai(_make_ai_transport("Eligible"))

    response = client_session.post(
        "/api/v1/donations",
        json=_base_donation(food_prepared_kg=20.0, food_sold_kg=50.0),
    )

    assert response.status_code == 422
    assert "food_sold_kg" in response.json()["detail"][0]["msg"] or "cannot exceed" in str(
        response.json()["detail"]
    )
    _assert_no_donations_insert(fake_supabase)


def test_zero_prepared_kg_rejected_before_insert(fake_supabase) -> None:
    _install_ai(_make_ai_transport("Eligible"))

    response = client_session.post(
        "/api/v1/donations", json=_base_donation(food_prepared_kg=0.0, food_sold_kg=0.0)
    )

    assert response.status_code == 422
    _assert_no_donations_insert(fake_supabase)


def test_donation_without_food_image_rejected_before_insert(fake_supabase) -> None:
    """A provider cannot create a donation without a food image (backend guard)."""
    body = _base_donation()
    body.pop("food_image_url")

    response = client_session.post("/api/v1/donations", json=body)

    assert response.status_code == 422
    assert "food_image_url" in str(response.json()["detail"])
    _assert_no_donations_insert(fake_supabase)


def test_kg_and_image_values_persist_exactly(fake_supabase) -> None:
    """Prepared/Sold KG must land in the INSERT unpchanged (never converted to
    servings) and food_image_url must be the exact URL that was returned by the
    upload step."""
    _install_ai(_make_ai_transport("Eligible"))
    image_url = (
        "https://project.supabase.co/storage/v1/object/public/donations/"
        "food-photos/provider-FAKE-001/food.png"
    )

    response = client_session.post(
        "/api/v1/donations",
        json=_base_donation(
            food_prepared_kg=10.0,
            food_sold_kg=2.0,
            food_image_url=image_url,
        ),
    )

    assert response.status_code == 200
    inserts = [op for op in fake_supabase.log if op[0] == "insert" and op[1] == "donations"]
    assert inserts[0][2]["food_prepared_kg"] == 10.0
    assert inserts[0][2]["food_sold_kg"] == 2.0
    assert inserts[0][2]["food_image_url"] == image_url


def test_invalid_food_category_is_rejected_before_ai(fake_supabase) -> None:
    _install_ai(_make_ai_transport("Eligible"))

    response = client_session.post(
        "/api/v1/donations", json=_base_donation(food_category="Sushi Fusion")
    )

    assert response.status_code == 422
    _assert_no_donations_insert(fake_supabase)


def test_missing_storage_condition_is_rejected_before_ai(fake_supabase) -> None:
    body = _base_donation()
    body.pop("storage_condition")

    response = client_session.post("/api/v1/donations", json=body)

    assert response.status_code == 400
    _assert_no_donations_insert(fake_supabase)


def test_non_provider_cannot_create_donation(fake_supabase) -> None:
    _install_ai(_make_ai_transport("Eligible"))
    app.dependency_overrides[get_current_profile] = lambda: {
        "id": "ngo-user-1",
        "role": "ngo",
        "ngos": [{"id": "ngo-1"}],
    }

    response = client_session.post("/api/v1/donations", json=_base_donation())

    assert response.status_code == 403
    _assert_no_donations_insert(fake_supabase)


def test_food_category_mapping_explicit() -> None:
    from app.services.food_mapping import map_food_category

    cases = {
        "Cooked Meals": "cooked",
        "Rice": "cooked",
        "Bread": "bakery",
        "Bakery": "bakery",
        "Fruits": "raw",
        "Vegetables": "raw",
        "Packaged Food": "packaged",
        "Other": None,
    }
    for source, expected in cases.items():
        assert map_food_category(source) == expected, source


# ---------------------------------------------------------------------------
# Food photo upload (app/routers/donations.upload_donation_image)
# ---------------------------------------------------------------------------
def test_food_photo_upload_returns_public_url(fake_supabase) -> None:
    response = client_session.post(
        "/api/v1/donations/upload",
        files={"file": ("photo.jpg", b"fake-image-bytes", "image/jpeg")},
    )

    assert response.status_code == 200
    url = response.json()["food_image_url"]
    assert url.startswith(
        "https://project.supabase.co/storage/v1/object/public/donations/food-photos/provider-FAKE-001/"
    )
    uploads = [op for op in fake_supabase.log if op[0] == "storage.upload"]
    assert len(uploads) == 1
    assert uploads[0][2] == len(b"fake-image-bytes")


def test_food_photo_upload_creates_bucket_when_missing(fake_supabase) -> None:
    response = client_session.post(
        "/api/v1/donations/upload",
        files={"file": ("photo.png", b"png-data", "image/png")},
    )

    assert response.status_code == 200
    assert ("storage.get_bucket", "donations") in fake_supabase.log
    assert ("storage.create_bucket", "donations") in fake_supabase.log


def test_food_photo_upload_rejects_non_image(fake_supabase) -> None:
    response = client_session.post(
        "/api/v1/donations/upload",
        files={"file": ("notes.txt", b"hello", "text/plain")},
    )

    assert response.status_code == 415
    assert not [op for op in fake_supabase.log if op[0] == "storage.upload"]


def test_food_photo_upload_rejects_oversized_image(fake_supabase, monkeypatch) -> None:
    from app.config import Settings

    monkeypatch.setattr(
        "app.routers.donations.get_settings",
        lambda: Settings(max_food_photo_size_mb=1),
    )

    response = client_session.post(
        "/api/v1/donations/upload",
        files={"file": ("photo.jpg", b"x" * (2 * 1024 * 1024), "image/jpeg")},
    )

    assert response.status_code == 413
    assert not [op for op in fake_supabase.log if op[0] == "storage.upload"]


def test_food_photo_upload_non_provider_is_403(fake_supabase) -> None:
    app.dependency_overrides[get_current_profile] = lambda: {
        "id": "ngo-user-1",
        "role": "ngo",
        "ngos": [{"id": "ngo-1"}],
    }

    response = client_session.post(
        "/api/v1/donations/upload",
        files={"file": ("photo.jpg", b"fake-image-bytes", "image/jpeg")},
    )

    assert response.status_code == 403
    assert not [op for op in fake_supabase.log if op[0] == "storage.upload"]


def test_png_upload_accepted_despite_mismatched_mime(fake_supabase) -> None:
    """A real PNG must be accepted even if the multipart MIME string is wrong:
    validity is decided from the file bytes, not the MIME header."""
    png_bytes = b"\x89PNG\r\n\x1a\n" + b"\x00\x00\x00\x0dIHDR-rest-of-png"

    response = client_session.post(
        "/api/v1/donations/upload",
        files={"file": ("photo", png_bytes, "text/plain")},
    )

    assert response.status_code == 200
    url = response.json()["food_image_url"]
    assert url.endswith(".png")
    uploads = [op for op in fake_supabase.log if op[0] == "storage.upload"]
    assert len(uploads) == 1
    assert uploads[0][2] == len(png_bytes)


def test_jpeg_upload_accepted_despite_octet_stream_mime(fake_supabase) -> None:
    """A real JPEG must be accepted even when the client sends the generic
    application/octet-stream content type (what image_picker cache paths do)."""
    jpeg_bytes = b"\xff\xd8\xff\xe0" + b"JFIF-rest-of-jpeg"

    response = client_session.post(
        "/api/v1/donations/upload",
        files={"file": ("photo.jpg", jpeg_bytes, "application/octet-stream")},
    )

    assert response.status_code == 200
    assert response.json()["food_image_url"].endswith(".jpg")


def test_food_photo_upload_rejects_non_image_bytes(fake_supabase) -> None:
    """Bytes that are neither a sniffable image nor declared/identified as an
    image type are rejected."""
    response = client_session.post(
        "/api/v1/donations/upload",
        files={"file": ("notes.txt", b"plain text, not an image", "text/plain")},
    )

    assert response.status_code == 415
    assert not [op for op in fake_supabase.log if op[0] == "storage.upload"]