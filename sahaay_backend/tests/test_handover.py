"""Tests for server-side handover verification and server-side enrichment.

Covers the batch-1 fixes:
  * GET/POST /api/v1/donations/{id}/handover* — the handover code lifecycle is
    owned by the backend: hash-only storage, expiry, attempt lock, NGO-scoped
    identity derived from the token, and photo persistence on the claim row.
  * POST /api/v1/profile/upload-photo — profile photo URL persisted server-side
    on the caller's own users row.
  * GET /api/v1/claims joins the claimed donation + provider (so the NGO
    "My Claims" screen renders real data, not session-local state).
  * GET /api/v1/donations joins the provider organisation details (so the
    claimed-donation screen shows the REAL restaurant name).

Only the Firebase-auth layer and the Supabase transport are faked; the real
FastAPI dependency chain (`require_role`, `get_current_profile`) runs.
"""

from __future__ import annotations

import hashlib
import threading
from datetime import datetime, timedelta, timezone
from types import SimpleNamespace

import pytest
from fastapi.testclient import TestClient

from app.config import Settings
from app.dependencies import get_current_firebase_user
from app.main import app
from app.routers.handover import CODE_TTL_MINUTES, MAX_VERIFY_ATTEMPTS

client = TestClient(app)

_PNG = b"\x89PNG\r\n\x1a\n" + b"fake-png-body"


# ---------------------------------------------------------------------------
# Fake Supabase: in-memory tables with real filter/order/limit/update semantics
# ---------------------------------------------------------------------------
def _matches(row: dict, filters: list, in_filters: list) -> bool:
    return all(row.get(k) == v for k, v in filters) and all(
        row.get(k) in values for k, values in in_filters
    )


class _Result:
    def __init__(self, data) -> None:
        self.data = data


class _Table:
    def __init__(self, store: dict, name: str) -> None:
        self._store = store
        self._name = name
        self._filters: list = []
        self._in_filters: list = []
        self._order: tuple | None = None
        self._limit: int | None = None
        self._update: dict | None = None
        self._single = False

    def select(self, *cols: str) -> "_Table":
        return self

    def eq(self, key: str, value: object) -> "_Table":
        self._filters.append((key, value))
        return self

    def in_(self, key: str, values) -> "_Table":
        self._in_filters.append((key, list(values)))
        return self

    def order(self, key: str, desc: bool = False) -> "_Table":
        self._order = (key, desc)
        return self

    def limit(self, n: int) -> "_Table":
        self._limit = n
        return self

    def maybe_single(self) -> "_Table":
        self._single = True
        return self

    def single(self) -> "_Table":
        self._single = True
        return self

    def insert(self, values: dict) -> "_Table":
        row = dict(values)
        rows = self._store.setdefault(self._name, [])
        row.setdefault("id", f"{self._name}-{len(rows) + 1}")
        rows.append(row)
        return self

    def update(self, values: dict) -> "_Table":
        self._update = dict(values)
        return self

    def execute(self):
        filters, in_filters = self._filters, self._in_filters
        order, limit = self._order, self._limit
        update, single = self._update, self._single
        self._filters, self._in_filters = [], []
        self._order, self._limit, self._update, self._single = None, None, None, False

        rows = self._store.setdefault(self._name, [])
        matched = [r for r in rows if _matches(r, filters, in_filters)]

        if update is not None:
            for row in matched:
                row.update(update)
            return _Result([dict(r) for r in matched])

        result = [dict(r) for r in matched]
        if order is not None:
            key, desc = order
            result.sort(key=lambda r: str(r.get(key) or ""), reverse=desc)
        if limit is not None:
            result = result[:limit]
        if single:
            if not result:
                return None  # real postgrest maybe_single() contract
            return _Result(result[0])
        return _Result(result)


class _Bucket:
    def __init__(self, owner: "_FakeSupabase") -> None:
        self._owner = owner

    def upload(self, path: str, data: bytes, file_options: dict | None = None) -> object:
        self._owner.log.append(("upload", path, len(data)))
        return object()

    def get_public_url(self, path: str) -> str:
        return f"https://project.supabase.co/storage/v1/object/public/donations/{path}"


class _Storage:
    def __init__(self, owner: "_FakeSupabase") -> None:
        self._owner = owner

    def get_bucket(self, bucket: str) -> dict:
        self._owner.log.append(("get_bucket", bucket))
        return {"id": bucket, "public": True}

    def create_bucket(self, bucket: str, options: dict | None = None) -> dict:
        self._owner.log.append(("create_bucket", bucket))
        return {"id": bucket}

    def from_(self, bucket: str) -> _Bucket:
        return _Bucket(self._owner)


class _FakeSupabase:
    def __init__(self) -> None:
        self.store: dict[str, list[dict]] = {}
        self.log: list = []
        self._rpc_lock = threading.Lock()

    def table(self, name: str) -> _Table:
        return _Table(self.store, name)

    def rpc(self, name: str, params: dict):
        return _Rpc(self, name, params)

    def _execute_rpc(self, name: str, params: dict) -> dict:
        claims = self.store.setdefault("claims", [])
        donations = self.store.setdefault("donations", [])
        donation = next(
            (row for row in donations if row.get("id") == params["p_donation_id"]),
            None,
        )
        if donation is None:
            return {"status": "donation_not_found"}
        claim = next(
            (
                row
                for row in claims
                if row.get("id") == params["p_claim_id"]
                and row.get("donation_id") == params["p_donation_id"]
            ),
            None,
        )
        if claim is None:
            return {"status": "claim_not_found"}

        now = datetime.now(timezone.utc)
        if name == "issue_donation_handover_code":
            expires = datetime.fromisoformat(params["p_expires_at"])
            if claim.get("handover_verified_at"):
                return {"status": "already_verified"}
            if claim.get("status") != "accepted" or donation.get("status") in {
                "available",
                "expired",
                "cancelled",
            }:
                return {"status": "claim_closed"}
            current_expiry = claim.get("handover_code_expires_at")
            if (
                claim.get("handover_code_hash")
                and current_expiry
                and datetime.fromisoformat(current_expiry) > now
            ):
                return {"status": "active_code"}
            claim.update(
                {
                    "handover_code_hash": params["p_code_hash"],
                    "handover_code_expires_at": expires.isoformat(),
                    "handover_code_attempts": 0,
                }
            )
            return {"status": "issued"}

        if name == "verify_donation_handover":
            if claim.get("handover_verified_at"):
                return {
                    "status": "already_verified",
                    "verified_at": claim["handover_verified_at"],
                }
            if claim.get("status") != "accepted" or donation.get("status") in {
                "available",
                "expired",
                "cancelled",
            }:
                return {"status": "claim_closed"}
            expiry = claim.get("handover_code_expires_at")
            if (
                not claim.get("handover_code_hash")
                or not expiry
                or datetime.fromisoformat(expiry) <= now
            ):
                return {"status": "expired"}
            attempts = int(claim.get("handover_code_attempts") or 0)
            if attempts >= MAX_VERIFY_ATTEMPTS:
                return {"status": "locked"}
            if claim["handover_code_hash"] != params["p_candidate_hash"]:
                attempts += 1
                claim["handover_code_attempts"] = attempts
                return {
                    "status": "wrong_code",
                    "remaining_attempts": max(MAX_VERIFY_ATTEMPTS - attempts, 0),
                }
            verified_at = now.isoformat()
            claim.update(
                {
                    "status": "completed",
                    "handover_verified_at": verified_at,
                    "handover_code_hash": None,
                    "handover_code_expires_at": None,
                    "handover_code_attempts": 0,
                }
            )
            donation.update({"status": "completed"})
            return {"status": "verified", "verified_at": verified_at}

        raise AssertionError(f"Unexpected RPC: {name}")

    @property
    def storage(self) -> _Storage:
        return _Storage(self)


class _Rpc:
    def __init__(self, owner: _FakeSupabase, name: str, params: dict) -> None:
        self._owner = owner
        self._name = name
        self._params = params

    def execute(self):
        with self._owner._rpc_lock:
            return SimpleNamespace(
                data=self._owner._execute_rpc(self._name, self._params)
            )


@pytest.fixture
def supabase(monkeypatch: pytest.MonkeyPatch) -> _FakeSupabase:
    fake = _FakeSupabase()
    for module in (
        "app.dependencies.get_supabase_client",
        "app.routers.handover.get_supabase_client",
        "app.routers.profile.get_supabase_client",
        "app.routers.claims.get_supabase_client",
        "app.routers.donations.get_supabase_client",
    ):
        monkeypatch.setattr(module, lambda: fake)
    app.dependency_overrides[get_current_firebase_user] = lambda: {
        "uid": "ngo-uid",
        "email": "test@example.org",
        "email_verified": True,
        "phone_number": "+919876543210",
    }
    settings = Settings(firebase_phone_auth_enabled=True)
    monkeypatch.setattr("app.config.get_settings", lambda: settings)
    monkeypatch.setattr("app.routers.handover.get_settings", lambda: settings)
    yield fake
    app.dependency_overrides.clear()


def _seed_ngo(fake: _FakeSupabase, *, role: str = "ngo", uid: str = "ngo-uid") -> None:
    fake.store.setdefault("users", []).append(
        {
            "id": "user-1",
            "firebase_uid": uid,
            "role": role,
            "full_name": "Test User",
            "email": "test@example.org",
            "phone": "+91 9876543210",
            "ngos": [{"id": "ngo-1", "organization_name": "Hope Foundation"}],
            "providers": [{"id": "provider-1", "organization_name": "Spice Garden"}],
            "volunteers": [],
        }
    )


def _seed_claim(fake: _FakeSupabase, **overrides) -> dict:
    row = {
        "id": "claim-1",
        "donation_id": "don-1",
        "ngo_id": "ngo-1",
        "status": "accepted",
        "requested_quantity": 10,
        "created_at": "2026-10-01T10:00:00+00:00",
        "handover_code_hash": None,
        "handover_code_expires_at": None,
        "handover_code_attempts": 0,
        "handover_verified_at": None,
        "handover_photo_url": None,
    }
    row.update(overrides)
    fake.store.setdefault("claims", []).append(row)
    donations = fake.store.setdefault("donations", [])
    if not any(donation.get("id") == "don-1" for donation in donations):
        donations.append({
            "id": "don-1",
            "provider_id": "provider-1",
            "status": "claimed",
            "acknowledgment_pdf_url": None,
        })
    return row


def _stored_claim(fake: _FakeSupabase) -> dict:
    return fake.store["claims"][0]


# ---------------------------------------------------------------------------
# Handover state
# ---------------------------------------------------------------------------
def test_handover_state_404_when_ngo_has_no_claim(supabase) -> None:
    _seed_ngo(supabase)

    response = client.get("/api/v1/donations/don-1/handover")

    assert response.status_code == 404


def test_handover_state_404_for_another_ngos_claim(supabase) -> None:
    _seed_ngo(supabase)
    _seed_claim(supabase, ngo_id="some-other-ngo")

    response = client.get("/api/v1/donations/don-1/handover")

    # 404 (not 403): the endpoint must not leak whether other NGOs claimed it.
    assert response.status_code == 404


def test_provider_can_read_owned_handover_state_but_only_ngo_can_issue_code(supabase) -> None:
    _seed_ngo(supabase, role="provider")
    _seed_claim(supabase)

    assert client.get("/api/v1/donations/don-1/handover").status_code == 200
    assert client.post("/api/v1/donations/don-1/handover/code").status_code == 403


def test_provider_claims_include_owned_donation_and_safe_ngo_display_data(supabase) -> None:
    _seed_ngo(supabase, role="provider")
    supabase.store["donations"] = [
        {
            "id": "don-1",
            "provider_id": "provider-1",
            "food_name": "Jeera Rice",
            "food_category": "prepared_meals",
            "quantity": 4,
            "pickup_address": "12 Main Road, Pune",
        },
        {
            "id": "other-donation",
            "provider_id": "another-provider",
            "food_name": "Private donation",
        },
    ]
    supabase.store["providers"] = [
        {"id": "provider-1", "organization_name": "Spice Garden"}
    ]
    supabase.store["ngos"] = [
        {
            "id": "ngo-1",
            "organization_name": "Hope Foundation",
            "city": "Pune",
            "phone": "private-contact",
            "address": "private-address",
        }
    ]
    _seed_claim(supabase, status="accepted")
    supabase.store["claims"].append(
        {
            "id": "other-claim",
            "donation_id": "other-donation",
            "ngo_id": "ngo-1",
            "status": "accepted",
        }
    )

    response = client.get("/api/v1/claims/provider")

    assert response.status_code == 200
    claims = response.json()
    assert len(claims) == 1
    assert claims[0]["donation"]["food_name"] == "Jeera Rice"
    assert claims[0]["donation"]["pickup_address"] == "12 Main Road, Pune"
    assert claims[0]["donation"]["provider"]["organization_name"] == "Spice Garden"
    assert claims[0]["ngo"] == {
        "id": "ngo-1",
        "organization_name": "Hope Foundation",
        "city": "Pune",
        "phone": "private-contact",
        "address": "private-address",
    }


def test_handover_state_reflects_verified_and_photo(supabase) -> None:
    _seed_ngo(supabase)
    _seed_claim(
        supabase,
        handover_verified_at="2026-10-01T11:00:00+00:00",
        handover_photo_url="https://example/photo.png",
    )

    response = client.get("/api/v1/donations/don-1/handover")

    assert response.status_code == 200
    body = response.json()
    assert body["handover_verified"] is True
    assert body["handover_photo_url"] == "https://example/photo.png"
    assert body["claim_id"] == "claim-1"


# ---------------------------------------------------------------------------
# Code generation
# ---------------------------------------------------------------------------
def test_generate_code_returns_4digit_code_and_stores_hash_only(supabase) -> None:
    _seed_ngo(supabase)
    _seed_claim(supabase)

    response = client.post("/api/v1/donations/don-1/handover/code")

    assert response.status_code == 200
    body = response.json()
    code = body["handover_code"]
    assert len(code) == 4 and code.isdigit()
    assert body["has_active_code"] is True
    assert body["handover_verified"] is False

    stored = _stored_claim(supabase)
    expected_hash = hashlib.sha256(f"claim-1:{code}".encode()).hexdigest()
    assert stored["handover_code_hash"] == expected_hash
    assert code not in str(stored["handover_code_hash"])
    assert stored["handover_code_attempts"] == 0
    assert stored["handover_code_expires_at"] is not None
    assert body["handover_code_expires_at"] == stored["handover_code_expires_at"]
    # The plaintext code is never persisted as any column value.
    assert code not in [str(v) for v in stored.values()]


def test_generate_code_rejected_when_already_verified(supabase) -> None:
    _seed_ngo(supabase)
    _seed_claim(supabase, handover_verified_at="2026-10-01T11:00:00+00:00")

    response = client.post("/api/v1/donations/don-1/handover/code")

    assert response.status_code == 409


def test_generate_code_rejected_for_closed_claim(supabase) -> None:
    _seed_ngo(supabase)
    _seed_claim(supabase, status="cancelled")

    response = client.post("/api/v1/donations/don-1/handover/code")

    assert response.status_code == 409


def test_generate_code_requires_accepted_claim(supabase) -> None:
    _seed_ngo(supabase)
    _seed_claim(supabase, status="pending")

    response = client.post("/api/v1/donations/don-1/handover/code")

    assert response.status_code == 409
    assert _stored_claim(supabase)["handover_code_hash"] is None


def test_generate_code_requires_trusted_contact_verification(supabase) -> None:
    _seed_ngo(supabase)
    _seed_claim(supabase)
    app.dependency_overrides[get_current_firebase_user] = lambda: {
        "uid": "ngo-uid",
        "email": "test@example.org",
        "email_verified": False,
        "phone_number": None,
    }

    response = client.post("/api/v1/donations/don-1/handover/code")

    assert response.status_code == 403
    assert _stored_claim(supabase)["handover_code_hash"] is None


def test_generate_code_does_not_replace_an_active_code(supabase) -> None:
    _seed_ngo(supabase)
    _seed_claim(supabase)

    first = client.post("/api/v1/donations/don-1/handover/code")
    second = client.post("/api/v1/donations/don-1/handover/code")

    assert first.status_code == 200
    assert second.status_code == 409
    assert _stored_claim(supabase)["handover_code_hash"] == hashlib.sha256(
        f"claim-1:{first.json()['handover_code']}".encode()
    ).hexdigest()


# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------
def _generate_code(supabase) -> str:
    response = client.post("/api/v1/donations/don-1/handover/code")
    assert response.status_code == 200
    return response.json()["handover_code"]


def test_verify_wrong_code_increments_attempts(supabase) -> None:
    _seed_ngo(supabase)
    _seed_claim(supabase)
    code = _generate_code(supabase)
    wrong = "0000" if code != "0000" else "0001"

    response = client.post(
        "/api/v1/donations/don-1/handover/verify", json={"code": wrong}
    )

    assert response.status_code == 400
    assert "not correct" in response.json()["detail"]
    assert _stored_claim(supabase)["handover_code_attempts"] == 1
    assert _stored_claim(supabase)["handover_verified_at"] is None


def test_verify_correct_code_records_handover(supabase) -> None:
    _seed_ngo(supabase)
    _seed_claim(supabase)
    code = _generate_code(supabase)

    response = client.post(
        "/api/v1/donations/don-1/handover/verify", json={"code": code}
    )

    assert response.status_code == 200
    assert response.json()["handover_verified"] is True

    stored = _stored_claim(supabase)
    assert stored["handover_verified_at"] is not None
    # Code material is cleared once used.
    assert stored["handover_code_hash"] is None
    assert stored["handover_code_expires_at"] is None
    assert supabase.store["donations"][0]["status"] == "completed"


def test_provider_can_verify_only_their_own_donation(supabase) -> None:
    _seed_ngo(supabase)
    _seed_claim(supabase)
    code = _generate_code(supabase)
    supabase.store["users"][0]["role"] = "provider"

    response = client.post(
        "/api/v1/donations/don-1/handover/verify", json={"code": code}
    )

    assert response.status_code == 200
    assert response.json()["handover_verified"] is True


def test_provider_cannot_verify_another_providers_donation(supabase) -> None:
    _seed_ngo(supabase, role="provider")
    _seed_claim(supabase)
    _stored_claim(supabase)["handover_code_hash"] = hashlib.sha256(
        b"claim-1:1234"
    ).hexdigest()
    _stored_claim(supabase)["handover_code_expires_at"] = (
        datetime.now(timezone.utc) + timedelta(minutes=5)
    ).isoformat()
    supabase.store["donations"][0]["provider_id"] = "another-provider"

    response = client.post(
        "/api/v1/donations/don-1/handover/verify", json={"code": "1234"}
    )

    assert response.status_code == 404
    assert _stored_claim(supabase)["handover_verified_at"] is None


def test_verify_after_reassignment_is_rejected(supabase) -> None:
    _seed_ngo(supabase)
    _seed_claim(supabase)
    code = _generate_code(supabase)
    _stored_claim(supabase)["ngo_id"] = "another-ngo"

    response = client.post(
        "/api/v1/donations/don-1/handover/verify", json={"code": code}
    )

    assert response.status_code == 404
    assert _stored_claim(supabase)["handover_verified_at"] is None


def test_verify_after_cancellation_is_rejected(supabase) -> None:
    _seed_ngo(supabase)
    _seed_claim(supabase)
    code = _generate_code(supabase)
    supabase.store["donations"][0]["status"] = "cancelled"

    response = client.post(
        "/api/v1/donations/don-1/handover/verify", json={"code": code}
    )

    assert response.status_code == 409
    assert _stored_claim(supabase)["handover_verified_at"] is None


def test_concurrent_verification_completes_handover_once(supabase) -> None:
    from concurrent.futures import ThreadPoolExecutor

    _seed_ngo(supabase)
    _seed_claim(supabase)
    code = _generate_code(supabase)

    def verify():
        return client.post(
            "/api/v1/donations/don-1/handover/verify", json={"code": code}
        )

    with ThreadPoolExecutor(max_workers=2) as pool:
        responses = list(pool.map(lambda _: verify(), range(2)))

    assert [response.status_code for response in responses] == [200, 200]
    assert sum(response.json().get("already_verified", False) for response in responses) == 1
    assert _stored_claim(supabase)["status"] == "completed"
    assert supabase.store["donations"][0]["status"] == "completed"


def test_verify_after_verified_returns_already_verified(supabase) -> None:
    _seed_ngo(supabase)
    _seed_claim(supabase, handover_verified_at="2026-10-01T11:00:00+00:00")

    response = client.post(
        "/api/v1/donations/don-1/handover/verify", json={"code": "1234"}
    )

    assert response.status_code == 200
    assert response.json()["already_verified"] is True


def test_verify_expired_code_returns_410(supabase) -> None:
    _seed_ngo(supabase)
    _seed_claim(supabase)
    code = _generate_code(supabase)
    past = (datetime.now(timezone.utc) - timedelta(minutes=1)).isoformat()
    _stored_claim(supabase)["handover_code_expires_at"] = past

    response = client.post(
        "/api/v1/donations/don-1/handover/verify", json={"code": code}
    )

    assert response.status_code == 410
    assert _stored_claim(supabase)["handover_verified_at"] is None


def test_verify_locked_after_max_attempts_returns_429(supabase) -> None:
    _seed_ngo(supabase)
    _seed_claim(supabase)
    code = _generate_code(supabase)
    _stored_claim(supabase)["handover_code_attempts"] = MAX_VERIFY_ATTEMPTS

    response = client.post(
        "/api/v1/donations/don-1/handover/verify", json={"code": code}
    )

    assert response.status_code == 429
    assert _stored_claim(supabase)["handover_verified_at"] is None


def test_verify_blank_code_is_rejected(supabase) -> None:
    _seed_ngo(supabase)
    _seed_claim(supabase)
    _generate_code(supabase)

    response = client.post(
        "/api/v1/donations/don-1/handover/verify", json={"code": ""}
    )

    assert response.status_code == 422


def test_code_ttl_is_bounded(supabase) -> None:
    _seed_ngo(supabase)
    _seed_claim(supabase)

    _generate_code(supabase)
    expires = datetime.fromisoformat(_stored_claim(supabase)["handover_code_expires_at"])
    remaining = expires - datetime.now(timezone.utc)

    assert timedelta(0) < remaining <= timedelta(minutes=CODE_TTL_MINUTES + 1)


def test_atomic_handover_migration_locks_and_restricts_rpc_execution():
    from pathlib import Path

    migration = (
        Path(__file__).parents[1]
        / "supabase"
        / "migrations"
        / "20261017000000_atomic_handover_workflow.sql"
    ).read_text(encoding="utf-8").lower()

    assert "for update" in migration
    assert "update public.claims" in migration
    assert "update public.donations" in migration
    assert "revoke all" in migration
    assert "to service_role" in migration
    assert "from public, anon, authenticated" in migration


# ---------------------------------------------------------------------------
# Handover photo
# ---------------------------------------------------------------------------
def test_handover_photo_uploads_and_persists_url(supabase) -> None:
    _seed_ngo(supabase)
    _seed_claim(supabase)

    response = client.post(
        "/api/v1/donations/don-1/handover/photo",
        files={"file": ("handover.png", _PNG, "image/png")},
    )

    assert response.status_code == 200
    url = response.json()["handover_photo_url"]
    assert url.endswith(".png")
    assert "handover-photos/claim-1/" in url
    assert _stored_claim(supabase)["handover_photo_url"] == url


def test_handover_photo_rejects_non_image(supabase) -> None:
    _seed_ngo(supabase)
    _seed_claim(supabase)

    response = client.post(
        "/api/v1/donations/don-1/handover/photo",
        files={"file": ("notes.txt", b"definitely not an image", "text/plain")},
    )

    assert response.status_code == 415
    assert _stored_claim(supabase)["handover_photo_url"] is None


# ---------------------------------------------------------------------------
# Profile photo upload
# ---------------------------------------------------------------------------
def test_profile_photo_upload_persists_on_own_users_row(supabase) -> None:
    _seed_ngo(supabase, role="volunteer")

    response = client.post(
        "/api/v1/profile/upload-photo",
        files={"file": ("me.png", _PNG, "image/png")},
    )

    assert response.status_code == 200
    url = response.json()["profile_image_url"]
    assert "profile-photos/user-1/" in url
    assert supabase.store["users"][0]["profile_image_url"] == url


def test_profile_photo_upload_rejects_non_image(supabase) -> None:
    _seed_ngo(supabase, role="volunteer")

    response = client.post(
        "/api/v1/profile/upload-photo",
        files={"file": ("malware.exe", b"MZ\x90\x00", "application/octet-stream")},
    )

    assert response.status_code == 415
    assert "profile_image_url" not in supabase.store["users"][0]


# ---------------------------------------------------------------------------
# List enrichment (real provider names / claimed-donation data)
# ---------------------------------------------------------------------------
def test_claims_list_joins_donation_and_provider(supabase) -> None:
    _seed_ngo(supabase)
    _seed_claim(supabase, status="pending")
    supabase.store["donations"][0].update(
        {"food_name": "Vegetable Rice", "pickup_address": "12 MG Road"}
    )
    supabase.store.setdefault("providers", []).append(
        {
            "id": "provider-1",
            "organization_name": "Spice Garden",
            "address": "12 MG Road",
            "city": "Pune",
            "phone": "+91 12345",
        }
    )

    response = client.get("/api/v1/claims")

    assert response.status_code == 200
    body = response.json()
    assert len(body) == 1
    assert body[0]["donation"]["food_name"] == "Vegetable Rice"
    assert body[0]["donation"]["provider"]["organization_name"] == "Spice Garden"
    # Raw claim facts are still present.
    assert body[0]["status"] == "pending"


def test_claims_list_survives_missing_donation(supabase) -> None:
    _seed_ngo(supabase)
    _seed_claim(supabase)  # no donations row for don-1
    supabase.store["donations"].clear()

    response = client.get("/api/v1/claims")

    assert response.status_code == 200
    body = response.json()
    assert len(body) == 1
    assert "donation" not in body[0]


def test_donations_list_joins_provider_for_provider_role(supabase) -> None:
    _seed_ngo(supabase, role="provider")
    supabase.store.setdefault("donations", []).append(
        {
            "id": "don-1",
            "provider_id": "provider-1",
            "food_name": "Vegetable Rice",
            "status": "available",
        }
    )
    supabase.store.setdefault("providers", []).append(
        {
            "id": "provider-1",
            "organization_name": "Spice Garden",
            "address": "12 MG Road",
            "city": "Pune",
            "phone": "+91 12345",
        }
    )

    response = client.get("/api/v1/donations")

    assert response.status_code == 200
    body = response.json()
    assert len(body) == 1
    assert body[0]["provider"]["organization_name"] == "Spice Garden"
    assert body[0]["provider"]["phone"] == "+91 12345"
