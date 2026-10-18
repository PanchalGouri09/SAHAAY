"""Automatic donation-completion acknowledgment PDF tests (Batch 2).

Covers the real pipeline:

    delivery reaches 'delivered'
        -> (production trigger) donation becomes 'completed'
        -> auto generation from REAL rows through the AI service
        -> PDF persisted to storage + reference persisted on the donation
        -> provider notified the PDF is ready
        -> provider/claiming NGO can download the persisted copy later

Also asserts the honesty gates: only completed donations, only real weights,
no invented volunteer/impact/handover facts, and no leak of another account's
PDF.
"""

from __future__ import annotations

import json
from types import SimpleNamespace

import httpx
import pytest
from fastapi.testclient import TestClient

from app.dependencies import get_current_profile
from app.main import app

client_session = TestClient(app)

_PROVIDER_ID = "prov-1"
_DONATION_ID = "don-1"


# ---------------------------------------------------------------------------
# Fake Supabase with storage + the production completion trigger simulated
# ---------------------------------------------------------------------------
class _Result:
    def __init__(self, data) -> None:
        self.data = data


class _Table:
    def __init__(self, name: str, db: "_FakeSupabase") -> None:
        self._name, self._db = name, db
        self._filters: list[tuple] = []
        self._mode = "query"
        self._insert: dict | None = None
        self._update: dict | None = None
        self._seq = 0

    def select(self, *cols):
        return self

    def eq(self, key, value):
        self._filters.append(("eq", key, value))
        return self

    def is_(self, key, value):
        self._filters.append(("is", key, value))
        return self

    def in_(self, key, values):
        self._filters.append(("in", key, list(values)))
        return self

    def order(self, *a, **k):
        return self

    def limit(self, n):
        return self

    def maybe_single(self):
        self._mode = "maybe"
        return self

    def single(self):
        self._mode = "single"
        return self

    def insert(self, values):
        self._insert = dict(values)
        return self

    def update(self, values):
        self._update = dict(values)
        return self

    def _rows(self):
        out = []
        for row in self._db.tables.setdefault(self._name, []):
            keep = True
            for kind, key, value in self._filters:
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
        mode, insert, update = self._mode, self._insert, self._update
        self._mode, self._insert, self._update = "query", None, None
        rows = self._rows()

        if insert is not None:
            row = dict(insert)
            self._seq += 1
            row.setdefault("id", f"{self._name}-row-{self._seq}")
            self._db.tables.setdefault(self._name, []).append(row)
            return _Result([dict(row)])

        if update is not None:
            for row in rows:
                row.update(update)
            # Production behaviour of record_delivery_impact: a delivery that
            # reaches 'delivered' completes its donation (the only real
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
        return _Result([dict(r) for r in rows])


class _Bucket:
    def __init__(self, storage, bucket):
        self._storage, self._bucket = storage, bucket

    def upload(self, path, data, file_options=None):
        if self._storage.fail_upload:
            raise RuntimeError("storage unavailable")
        self._storage.objects[(self._bucket, path)] = bytes(data)

    def get_public_url(self, path):
        return f"https://storage.test/{self._bucket}/{path}"

    def download(self, path):
        if (self._bucket, path) not in self._storage.objects:
            raise KeyError(path)
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
        self.storage = _Storage()
        self.simulate_completion_trigger = True

    def table(self, name):
        return _Table(name, self)

    def seed(self, name, rows):
        self.tables.setdefault(name, []).extend(dict(r) for r in rows)

    def rows(self, name):
        return self.tables.setdefault(name, [])


# ---------------------------------------------------------------------------
# AI transport (real typed AIClient over httpx.MockTransport)
# ---------------------------------------------------------------------------
class _AIHandler:
    def __init__(self, *, raise_connect: bool = False) -> None:
        self.requests: list[httpx.Request] = []
        self.raise_connect = raise_connect
        self.missing_download = False

    @property
    def paths_hit(self) -> list[str]:
        return [r.url.path for r in self.requests]

    def body_for(self, path: str) -> dict:
        request = next(r for r in self.requests if r.url.path == path)
        return json.loads(request.content)

    def handler(self, request: httpx.Request) -> httpx.Response:
        self.requests.append(request)
        if self.raise_connect:
            raise httpx.ConnectError("connection refused to AI")
        if request.url.path == "/api/v1/donation/generate-acknowledgment":
            body = json.loads(request.content)
            return httpx.Response(
                200,
                json={
                    "donation_id": body["donation_id"],
                    "pdf_filename": f"acknowledgment_{body['donation_id']}.pdf",
                    "file_path": f"/tmp/acknowledgment_{body['donation_id']}.pdf",
                    "message": "Acknowledgment PDF generated successfully.",
                },
            )
        if request.url.path.startswith("/api/v1/donation/download/"):
            if self.missing_download:
                return httpx.Response(404, json={"detail": "No acknowledgment PDF found."})
            return httpx.Response(
                200,
                content=b"%PDF-1.4 completion acknowledgment",
                headers={"content-type": "application/pdf"},
            )
        return httpx.Response(404, json={"detail": "not found"})


# ---------------------------------------------------------------------------
# Fixtures & seeds
# ---------------------------------------------------------------------------
@pytest.fixture
def ctx(monkeypatch: pytest.MonkeyPatch):
    fake = _FakeSupabase()
    for module in (
        "app.dependencies.get_supabase_client",
        "app.routers.profile.get_supabase_client",
        "app.routers.donations.get_supabase_client",
        "app.routers.claims.get_supabase_client",
        "app.routers.deliveries.get_supabase_client",
        "app.routers.notifications.get_supabase_client",
        "app.routers.ai_features.get_supabase_client",
    ):
        monkeypatch.setattr(module, lambda: fake)

    ai = _AIHandler()

    def _client():
        from app.services.ai_client import AIClient

        return AIClient(
            base_url="http://ai.test",
            timeout=5.0,
            transport=httpx.MockTransport(ai.handler),
        )

    # Direct auto-generation calls resolve the AI client by name; DI-based
    # endpoints resolve it through Depends(get_ai_client). Pin both seams.
    from app.services.ai_client import get_ai_client

    monkeypatch.setattr("app.services.acknowledgment.get_ai_client", _client)
    app.dependency_overrides[get_ai_client] = _client

    app.dependency_overrides[get_current_profile] = lambda: {
        "id": "u-provider",
        "role": "provider",
        "providers": [
            {"id": _PROVIDER_ID, "organization_name": "Tasty Kitchen"}
        ],
    }
    yield SimpleNamespace(fake=fake, ai=ai)
    app.dependency_overrides.clear()


def _seed_full(ctx, *, status="completed", unit="kg", with_volunteer=True) -> None:
    """A donation that genuinely completed, with every related real row."""
    fake = ctx.fake
    fake.seed("providers", [
        {"id": _PROVIDER_ID, "user_id": "u-provider",
         "organization_name": "Tasty Kitchen"},
    ])
    fake.seed("ngos", [
        {"id": "ngo-1", "user_id": "u-ngo", "organization_name": "Feed The City"},
    ])
    fake.seed("donations", [
        {
            "id": _DONATION_ID,
            "provider_id": _PROVIDER_ID,
            "food_name": "Vegetable Rice",
            "quantity": 10.0,
            "unit": unit,
            "servings": 40,
            "prepared_at": "2026-09-29T12:00:00+00:00",
            "expiry_time": "2026-09-30T18:00:00+00:00",
            "status": status,
        },
    ])
    fake.seed("claims", [
        {
            "id": "claim-1",
            "donation_id": _DONATION_ID,
            "ngo_id": "ngo-1",
            "status": "accepted",
            "handover_verified_at": "2026-09-29T16:05:00+00:00",
            "handover_photo_url": "https://storage.test/handover.jpg",
        },
    ])
    fake.seed("impact_records", [
        {"donation_id": _DONATION_ID, "meals_rescued": 8,
         "food_weight_kg": 10.0, "estimated_co2_saved": 25.0},
    ])
    if with_volunteer:
        fake.seed("users", [{"id": "u-vol", "full_name": "Ravi Kumar"}])
        fake.seed("volunteers", [{"id": "vol-1", "user_id": "u-vol"}])
        fake.seed("deliveries", [
            {"id": "del-1", "donation_id": _DONATION_ID, "claim_id": "claim-1",
             "volunteer_id": "vol-1", "status": "accepted"},
        ])


# ===========================================================================
# Gating: only an actually completed donation can produce a completion PDF
# ===========================================================================
def test_auto_refuses_when_donation_is_not_completed(ctx) -> None:
    _seed_full(ctx, status="claimed")
    ctx.fake.simulate_completion_trigger = False

    from app.services.acknowledgment import auto_generate_acknowledgment

    assert auto_generate_acknowledgment(ctx.fake, _DONATION_ID) is None
    assert "/api/v1/donation/generate-acknowledgment" not in ctx.ai.paths_hit
    assert ctx.fake.rows("donations")[0].get("acknowledgment_pdf_url") is None


def test_auto_refuses_a_completed_donation_without_a_claim(ctx) -> None:
    _seed_full(ctx)
    ctx.fake.tables["claims"] = []  # donation completed but no real claim

    from app.services.acknowledgment import auto_generate_acknowledgment

    assert auto_generate_acknowledgment(ctx.fake, _DONATION_ID) is None
    assert "/api/v1/donation/generate-acknowledgment" not in ctx.ai.paths_hit


def test_auto_refuses_servings_instead_of_inventing_kg(ctx) -> None:
    _seed_full(ctx, unit="servings")

    from app.services.acknowledgment import auto_generate_acknowledgment

    assert auto_generate_acknowledgment(ctx.fake, _DONATION_ID) is None
    assert "/api/v1/donation/generate-acknowledgment" not in ctx.ai.paths_hit
    assert ctx.fake.rows("donations")[0].get("acknowledgment_pdf_url") is None


def test_manual_generate_still_rejects_non_completed_status(ctx) -> None:
    _seed_full(ctx, status="claimed")

    response = client_session.post(
        "/api/v1/donations/don-1/acknowledgment/generate"
    )

    assert response.status_code == 400
    assert "completed" in response.json()["detail"]
    assert "/api/v1/donation/generate-acknowledgment" not in ctx.ai.paths_hit


# ===========================================================================
# The automatic completion pipeline (delivery -> completed -> PDF -> notify)
# ===========================================================================
def test_delivered_status_auto_generates_and_persists_pdf(ctx) -> None:
    _seed_full(ctx, status="claimed")
    _login_volunteer()

    response = client_session.patch(
        "/api/v1/deliveries/del-1/status", json={"status": "delivered"}
    )

    assert response.status_code == 200, response.text
    # The trigger completed the donation, then the PDF pipeline ran for real.
    assert ctx.fake.rows("donations")[0]["status"] == "completed"
    assert "/api/v1/donation/generate-acknowledgment" in ctx.ai.paths_hit
    assert "/api/v1/donation/download/don-1" in ctx.ai.paths_hit

    donation = ctx.fake.rows("donations")[0]
    assert donation["acknowledgment_pdf_url"] == (
        "https://storage.test/donations/acknowledgments/acknowledgment_don-1.pdf"
    )
    assert donation["acknowledgment_generated_at"]
    # The bytes really live in storage (survives app + AI-service restarts).
    stored = ctx.fake.storage.objects[
        ("donations", "acknowledgments/acknowledgment_don-1.pdf")
    ]
    assert stored.startswith(b"%PDF-1.4")

    # The provider was told the PDF is ready.
    ack_notes = [
        r for r in ctx.fake.rows("notifications")
        if r["type"] == "acknowledgment_ready"
    ]
    assert len(ack_notes) == 1
    assert ack_notes[0]["user_id"] == "u-provider"


def test_auto_request_carries_only_real_data(ctx) -> None:
    _seed_full(ctx)

    from app.services.acknowledgment import auto_generate_acknowledgment

    assert auto_generate_acknowledgment(ctx.fake, _DONATION_ID) is not None
    body = ctx.ai.body_for("/api/v1/donation/generate-acknowledgment")

    assert body["donation_id"] == _DONATION_ID
    assert body["restaurant_name"] == "Tasty Kitchen"   # providers row
    assert body["ngo_name"] == "Feed The City"          # completed claim's NGO
    assert body["food_details"] == "Vegetable Rice"
    assert body["quantity_kg"] == 10.0
    assert body["unit"] == "kg"
    assert body["completion_status"] == "Completed"
    assert body["donation_datetime"].startswith("2026-09-29T12:00:00")
    # Real handover / delivery / impact / volunteer facts — nothing invented.
    assert body["handover_verified_at"].startswith("2026-09-29T16:05:00")
    assert body["handover_photo_url"] == "https://storage.test/handover.jpg"
    assert body["meals_rescued"] == 8
    assert body["food_weight_kg"] == 10.0
    assert body["estimated_co2_saved"] == 25.0
    assert body["volunteer_transport_used"] is True
    assert body["volunteer_name"] == "Ravi Kumar"       # users.full_name, real


def test_no_volunteer_facts_when_no_volunteer_was_used(ctx) -> None:
    _seed_full(ctx, with_volunteer=True)
    # A delivery exists but no volunteer ever took it.
    ctx.fake.rows("deliveries")[0]["volunteer_id"] = None

    from app.services.acknowledgment import auto_generate_acknowledgment

    assert auto_generate_acknowledgment(ctx.fake, _DONATION_ID) is not None
    body = ctx.ai.body_for("/api/v1/donation/generate-acknowledgment")
    assert body["volunteer_transport_used"] is False
    assert body["volunteer_name"] is None               # never fabricated


def test_missing_optional_data_does_not_crash_generation(ctx) -> None:
    _seed_full(ctx)
    # Strip every optional fact: no impact, no delivery, no handover, no photo.
    ctx.fake.tables["impact_records"] = []
    ctx.fake.tables["deliveries"] = []
    claim = ctx.fake.rows("claims")[0]
    claim["handover_verified_at"] = None
    claim["handover_photo_url"] = None

    from app.services.acknowledgment import auto_generate_acknowledgment

    outcome = auto_generate_acknowledgment(ctx.fake, _DONATION_ID)
    assert outcome is not None and outcome["persisted"] is True
    body = ctx.ai.body_for("/api/v1/donation/generate-acknowledgment")
    assert body["meals_rescued"] is None
    assert body["food_weight_kg"] is None
    assert body["estimated_co2_saved"] is None
    assert body["delivered_at"] is None
    assert body["handover_verified_at"] is None
    assert body["handover_photo_url"] is None
    assert body["volunteer_transport_used"] is False


def test_auto_generation_is_idempotent(ctx) -> None:
    _seed_full(ctx)

    from app.services.acknowledgment import auto_generate_acknowledgment

    first = auto_generate_acknowledgment(ctx.fake, _DONATION_ID)
    assert first is not None and first["persisted"] is True
    calls_after_first = len(ctx.ai.paths_hit)

    second = auto_generate_acknowledgment(ctx.fake, _DONATION_ID)

    assert second is not None and second.get("already_generated") is True
    assert len(ctx.ai.paths_hit) == calls_after_first  # no duplicate work


def test_ai_failure_never_breaks_the_delivery_update(ctx) -> None:
    _seed_full(ctx, status="claimed")
    ctx.ai.raise_connect = True
    _login_volunteer()

    response = client_session.patch(
        "/api/v1/deliveries/del-1/status", json={"status": "delivered"}
    )

    # The business update succeeded; only the PDF was skipped, honestly.
    assert response.status_code == 200, response.text
    donation = ctx.fake.rows("donations")[0]
    assert donation["status"] == "completed"
    assert donation.get("acknowledgment_pdf_url") is None
    assert not [
        r for r in ctx.fake.rows("notifications")
        if r["type"] == "acknowledgment_ready"
    ]


def test_storage_failure_is_reported_not_pretended(ctx) -> None:
    _seed_full(ctx)
    ctx.fake.storage.fail_upload = True

    from app.services.acknowledgment import generate_and_persist

    outcome = generate_and_persist(ctx.fake, ctx.fake.rows("donations")[0])

    # The PDF exists and is returned, but persistence honestly failed.
    assert outcome["pdf_bytes"].startswith(b"%PDF-1.4")
    assert outcome["persisted"] is False
    assert outcome["url"] is None
    assert ctx.fake.rows("donations")[0].get("acknowledgment_pdf_url") is None


# ===========================================================================
# Retrieval + authorization: who may download a saved acknowledgment
# ===========================================================================
def _login_volunteer():
    app.dependency_overrides[get_current_profile] = lambda: {
        "id": "u-vol", "role": "volunteer", "volunteers": [{"id": "vol-1"}],
    }


def _login_ngo(with_claim: bool = True):
    app.dependency_overrides[get_current_profile] = lambda: {
        "id": "u-ngo", "role": "ngo", "ngos": [{"id": "ngo-1"}],
    }


def test_provider_downloads_persisted_copy_without_touching_ai(ctx) -> None:
    _seed_full(ctx)
    from app.services.acknowledgment import auto_generate_acknowledgment

    auto_generate_acknowledgment(ctx.fake, _DONATION_ID)
    ai_calls = len(ctx.ai.paths_hit)

    response = client_session.get("/api/v1/donations/don-1/acknowledgment")
    repeated = client_session.get("/api/v1/donations/don-1/acknowledgment")

    assert response.status_code == 200
    assert response.content.startswith(b"%PDF-1.4")
    assert repeated.status_code == 200
    assert repeated.content == response.content
    assert len(ctx.ai.paths_hit) == ai_calls  # served from persisted storage


def test_claiming_ngo_can_download_its_acknowledgment(ctx) -> None:
    _seed_full(ctx)
    from app.services.acknowledgment import auto_generate_acknowledgment

    auto_generate_acknowledgment(ctx.fake, _DONATION_ID)
    _login_ngo()

    response = client_session.get("/api/v1/donations/don-1/acknowledgment")

    assert response.status_code == 200
    assert response.content.startswith(b"%PDF-1.4")


def test_ngo_without_claim_cannot_download(ctx) -> None:
    _seed_full(ctx)
    ctx.fake.tables["claims"] = []
    _login_ngo(with_claim=False)

    response = client_session.get("/api/v1/donations/don-1/acknowledgment")

    assert response.status_code == 403


def test_another_provider_cannot_download(ctx) -> None:
    _seed_full(ctx)
    app.dependency_overrides[get_current_profile] = lambda: {
        "id": "u-other", "role": "provider",
        "providers": [{"id": "prov-OTHER", "organization_name": "Other Kitchen"}],
    }

    response = client_session.get("/api/v1/donations/don-1/acknowledgment")

    assert response.status_code == 403


def test_volunteer_role_cannot_download(ctx) -> None:
    _seed_full(ctx)
    _login_volunteer()

    response = client_session.get("/api/v1/donations/don-1/acknowledgment")

    assert response.status_code == 403


def test_download_requires_authentication(ctx) -> None:
    _seed_full(ctx)
    app.dependency_overrides.pop(get_current_profile, None)

    response = client_session.get("/api/v1/donations/don-1/acknowledgment")

    assert response.status_code == 401


def test_missing_acknowledgment_returns_honest_404(ctx) -> None:
    _seed_full(ctx)  # completed, but never generated
    ctx.ai.missing_download = True

    response = client_session.get("/api/v1/donations/don-1/acknowledgment")

    # Nothing persisted and the AI service has nothing either -> honest 404.
    assert response.status_code == 404
    assert "Generate it first" in response.json()["detail"]
