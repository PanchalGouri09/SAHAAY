from fastapi.testclient import TestClient

from app.dependencies import get_current_profile
from app.main import app
from app.routers import device_tokens
from app.schemas.device_token import DeviceTokenRegister
from app.services import fcm_sender


class _Result:
    def __init__(self, data):
        self.data = data


class _Query:
    def __init__(self, db):
        self.db = db
        self.filters = {}
        self.values = None
        self.operation = "select"

    def upsert(self, values, on_conflict):
        assert on_conflict == "user_id,token"
        self.operation, self.values = "upsert", values
        return self

    def select(self, *_):
        return self

    def single(self):
        return self

    def eq(self, key, value):
        self.filters[key] = value
        return self

    def delete(self):
        self.operation = "delete"
        return self

    def execute(self):
        rows = self.db.rows
        if self.operation == "upsert":
            row = next((r for r in rows if r["user_id"] == self.values["user_id"] and r["token"] == self.values["token"]), None)
            if row is None:
                row = {"id": "token-1", "created_at": "now", "updated_at": "now", **self.values}
                rows.append(row)
            else:
                row.update(platform=self.values["platform"], updated_at="later")
            return _Result(dict(row))
        matched = [r for r in rows if all(r.get(k) == v for k, v in self.filters.items())]
        if self.operation == "delete":
            self.db.rows[:] = [r for r in rows if r not in matched]
        return _Result([dict(r) for r in matched])


class _DB:
    def __init__(self):
        self.rows = []

    def table(self, _):
        return _Query(self)


def test_device_token_requires_authentication():
    response = TestClient(app).post("/api/v1/device-tokens", json={"token": "t", "platform": "android"})
    assert response.status_code == 401


def test_generic_client_push_endpoint_is_not_exposed():
    app.dependency_overrides[get_current_profile] = lambda: {"id": "user-a", "role": "ngo"}
    try:
        response = TestClient(app).post(
            "/api/v1/notifications/send",
            params={"user_id": "user-b", "title": "title", "body": "body"},
        )
    finally:
        app.dependency_overrides.pop(get_current_profile, None)
    assert response.status_code == 404


def test_token_registration_uses_profile_id_and_upserts(monkeypatch):
    db = _DB()
    monkeypatch.setattr(device_tokens, "get_supabase_client", lambda: db)
    profile = {"id": "user-row-id", "firebase_uid": "firebase-uid"}
    first = device_tokens.register_device_token(
        DeviceTokenRegister(token="fcm-token", platform="android"), profile
    )
    second = device_tokens.register_device_token(
        DeviceTokenRegister(token="fcm-token", platform="ios"), profile
    )
    assert first["user_id"] == "user-row-id"
    assert second["platform"] == "ios"
    assert len(db.rows) == 1
    assert "updated_at" in second


def test_token_list_and_delete_are_scoped_to_profile(monkeypatch):
    db = _DB()
    db.rows.extend([
        {"id": "owned", "user_id": "user-a", "token": "a"},
        {"id": "other", "user_id": "user-b", "token": "b"},
    ])
    monkeypatch.setattr(device_tokens, "get_supabase_client", lambda: db)
    assert [row["id"] for row in device_tokens.list_device_tokens({"id": "user-a"})] == ["owned"]
    try:
        device_tokens.remove_device_token("other", {"id": "user-a"})
        assert False, "deleting another user's token must fail"
    except Exception as exc:
        assert getattr(exc, "status_code", None) == 404
    assert [row["id"] for row in db.rows] == ["owned", "other"]


class _SenderQuery:
    def __init__(self, db):
        self.db = db
        self.key = None
        self.value = None
        self.deleting = False

    def select(self, *_):
        return self

    def eq(self, key, value):
        self.key, self.value = key, value
        return self

    def delete(self):
        self.deleting = True
        return self

    def execute(self):
        if self.deleting:
            self.db.rows[:] = [r for r in self.db.rows if r.get(self.key) != self.value]
            return _Result([])
        return _Result([dict(r) for r in self.db.rows if r.get(self.key) == self.value])


class _SenderDB:
    def __init__(self):
        self.rows = [{"user_id": "user-a", "token": "invalid-token", "platform": "android"}]

    def table(self, _):
        return _SenderQuery(self)


def test_sender_cleans_unregistered_token_and_does_not_raise(monkeypatch):
    from firebase_admin import messaging

    db = _SenderDB()
    monkeypatch.setattr("app.firebase_auth.get_firebase_app", lambda: object())
    monkeypatch.setattr("app.supabase_client.get_supabase_client", lambda: db)
    monkeypatch.setattr(
        fcm_sender.firebase_messaging,
        "send",
        lambda _: (_ for _ in ()).throw(messaging.UnregisteredError("gone")),
    )

    result = fcm_sender.send_push_notification_to_user("user-a", "Title", "Body")

    assert result["invalid"] == 1
    assert db.rows == []


def test_sender_isolates_transient_fcm_failure(monkeypatch):
    db = _SenderDB()
    monkeypatch.setattr("app.firebase_auth.get_firebase_app", lambda: object())
    monkeypatch.setattr("app.supabase_client.get_supabase_client", lambda: db)
    monkeypatch.setattr(
        fcm_sender.firebase_messaging,
        "send",
        lambda _: (_ for _ in ()).throw(RuntimeError("offline")),
    )

    result = fcm_sender.send_push_notification_to_user("user-a", "Title", "Body")

    assert result["failed"] == 1
    assert db.rows


def test_ngo_push_recipient_is_resolved_from_ngo_relationship(monkeypatch):
    class NGOQuery:
        def select(self, *_):
            return self

        def eq(self, key, value):
            assert key == "id"
            assert value == "ngo-row-7"
            return self

        def maybe_single(self):
            return self

        def execute(self):
            return _Result({"user_id": "user-row-9"})

    class NGODB:
        def table(self, name):
            assert name == "ngos"
            return NGOQuery()

    sent = []
    monkeypatch.setattr("app.supabase_client.get_supabase_client", lambda: NGODB())
    monkeypatch.setattr(
        fcm_sender,
        "send_push_notification_to_user",
        lambda user_id, *_args, **_kwargs: sent.append(user_id) or {"sent": 1},
    )

    result = fcm_sender.send_notification_to_ngo("ngo-row-7", "title", "body")

    assert result == {"sent": 1}
    assert sent == ["user-row-9"]
