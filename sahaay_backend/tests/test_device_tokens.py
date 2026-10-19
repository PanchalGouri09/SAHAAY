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
    def __init__(self, database):
        self.database = database
        self.filters = {}
        self.values = None
        self.operation = "select"

    def upsert(self, values, on_conflict):
        assert on_conflict == "token"
        self.operation, self.values = "upsert", values
        return self

    def select(self, *_):
        return self

    def single(self):
        return self

    def maybe_single(self):
        return self

    def eq(self, key, value):
        self.filters[key] = value
        return self

    def delete(self):
        self.operation = "delete"
        return self

    def execute(self):
        rows = self.database.rows
        if self.operation == "upsert":
            row = next(
                (item for item in rows if item["token"] == self.values["token"]),
                None,
            )
            if row is None:
                row = {
                    "id": f"token-{len(rows) + 1}",
                    "created_at": "2026-10-18T00:00:00+00:00",
                    **self.values,
                }
                rows.append(row)
            else:
                row.update(self.values)
            return _Result(dict(row))

        matched = [
            row
            for row in rows
            if all(row.get(key) == value for key, value in self.filters.items())
        ]
        if self.operation == "delete":
            self.database.rows[:] = [row for row in rows if row not in matched]
        return _Result([dict(row) for row in matched])


class _Database:
    def __init__(self):
        self.rows = []

    def table(self, _):
        return _Query(self)


def test_device_token_routes_require_authentication():
    response = TestClient(app).post(
        "/api/v1/device-tokens",
        json={"token": "test-token", "platform": "android"},
    )
    assert response.status_code == 401


def test_generic_client_push_endpoint_is_not_exposed():
    app.dependency_overrides[get_current_profile] = lambda: {
        "id": "user-a",
        "role": "ngo",
    }
    try:
        response = TestClient(app).post(
            "/api/v1/notifications/send",
            params={"user_id": "user-b", "title": "title", "body": "body"},
        )
    finally:
        app.dependency_overrides.pop(get_current_profile, None)
    assert response.status_code == 404


def test_register_uses_profile_id_and_upserts(monkeypatch):
    database = _Database()
    monkeypatch.setattr(device_tokens, "get_supabase_client", lambda: database)
    profile = {"id": "user-row-id", "firebase_uid": "firebase-uid"}

    first = device_tokens.register_device_token(
        DeviceTokenRegister(token="fcm-token", platform="android"),
        profile,
    )
    second = device_tokens.register_device_token(
        DeviceTokenRegister(token="fcm-token", platform="ios"),
        profile,
    )

    assert first["user_id"] == "user-row-id"
    assert second["platform"] == "ios"
    assert len(database.rows) == 1
    assert "updated_at" in second


def test_register_endpoint_ignores_client_supplied_user_id(monkeypatch):
    database = _Database()
    monkeypatch.setattr(device_tokens, "get_supabase_client", lambda: database)
    app.dependency_overrides[get_current_profile] = lambda: {"id": "trusted-user"}
    try:
        response = TestClient(app).post(
            "/api/v1/device-tokens",
            json={
                "token": "fcm-token",
                "platform": "android",
                "user_id": "attacker-user",
            },
        )
    finally:
        app.dependency_overrides.pop(get_current_profile, None)

    assert response.status_code == 201, response.text
    assert response.json()["user_id"] == "trusted-user"


def test_invalid_platform_is_rejected():
    app.dependency_overrides[get_current_profile] = lambda: {"id": "trusted-user"}
    try:
        response = TestClient(app).post(
            "/api/v1/device-tokens",
            json={"token": "test-token", "platform": "desktop"},
        )
    finally:
        app.dependency_overrides.pop(get_current_profile, None)
    assert response.status_code == 422


def test_token_list_and_delete_are_scoped_to_profile(monkeypatch):
    database = _Database()
    database.rows.extend(
        [
            {"id": "owned", "user_id": "user-a", "token": "a"},
            {"id": "other", "user_id": "user-b", "token": "b"},
        ]
    )
    monkeypatch.setattr(device_tokens, "get_supabase_client", lambda: database)

    assert [
        row["id"] for row in device_tokens.list_device_tokens({"id": "user-a"})
    ] == ["owned"]
    try:
        device_tokens.remove_device_token("other", {"id": "user-a"})
        assert False, "deleting another user's token must fail"
    except Exception as error:
        assert getattr(error, "status_code", None) == 404
    assert [row["id"] for row in database.rows] == ["owned", "other"]


class _SenderQuery:
    def __init__(self, database):
        self.database = database
        self.key = None
        self.value = None
        self.deleting = False

    def select(self, *_):
        return self

    def eq(self, key, value):
        self.key, self.value = key, value
        return self

    def maybe_single(self):
        return self

    def delete(self):
        self.deleting = True
        return self

    def execute(self):
        matched = [row for row in self.database.rows if row.get(self.key) == self.value]
        if self.deleting:
            self.database.rows[:] = [
                row for row in self.database.rows if row not in matched
            ]
        return _Result([dict(row) for row in matched])


class _SenderDatabase:
    def __init__(self):
        self.rows = [
            {"user_id": "user-a", "token": "invalid-token", "platform": "android"}
        ]

    def table(self, _):
        return _SenderQuery(self)


def test_sender_cleans_unregistered_token_and_does_not_raise(monkeypatch):
    from firebase_admin import messaging

    database = _SenderDatabase()
    monkeypatch.setattr("app.firebase_auth.get_firebase_app", lambda: object())
    monkeypatch.setattr("app.supabase_client.get_supabase_client", lambda: database)

    def raise_unregistered(*_args, **_kwargs):
        raise messaging.UnregisteredError("gone")

    monkeypatch.setattr(fcm_sender.firebase_messaging, "send", raise_unregistered)

    result = fcm_sender.send_push_notification_to_user("user-a", "Title", "Body")

    assert result["invalid"] == 1
    assert database.rows == []


def test_sender_skips_firebase_initialization_when_user_has_no_tokens(monkeypatch):
    database = _SenderDatabase()
    database.rows.clear()
    monkeypatch.setattr("app.supabase_client.get_supabase_client", lambda: database)
    monkeypatch.setattr(
        "app.firebase_auth.get_firebase_app",
        lambda: (_ for _ in ()).throw(AssertionError("must not initialize")),
    )

    result = fcm_sender.send_push_notification_to_user(
        "user-without-device", "Title", "Body"
    )

    assert result == {"accepted_by_fcm": 0, "failed": 0, "invalid": 0}


def test_sender_builds_audible_fcm_message_and_logs_acceptance_privately(
    monkeypatch, caplog
):
    import logging

    database = _SenderDatabase()
    messages = []
    monkeypatch.setattr("app.firebase_auth.get_firebase_app", lambda: object())
    monkeypatch.setattr("app.supabase_client.get_supabase_client", lambda: database)
    monkeypatch.setattr(
        fcm_sender.firebase_messaging,
        "send",
        lambda message, **_kwargs: messages.append(message) or "fcm-message-id",
    )
    caplog.set_level(logging.INFO, logger="sahaay.fcm")

    result = fcm_sender.send_push_notification_to_user(
        "user-a", "Pickup update", "A delivery needs attention.", {"type": "pickup"}
    )

    assert result == {"accepted_by_fcm": 1, "failed": 0, "invalid": 0}
    assert len(messages) == 1
    assert messages[0].android.notification.channel_id == "sahaay_notifications_v2"
    assert messages[0].android.notification.sound == "sahaay_ting_ting"
    assert messages[0].data == {"type": "pickup"}
    assert "recipient_count=1" in caplog.text
    assert "accepted_by_fcm=1" in caplog.text
    assert "fcm-message-id" not in caplog.text
    assert "invalid-token" not in caplog.text


def test_sender_logs_firebase_initialization_failure_without_sensitive_data(
    monkeypatch, caplog
):
    import logging

    database = _SenderDatabase()
    monkeypatch.setattr("app.supabase_client.get_supabase_client", lambda: database)
    monkeypatch.setattr(
        "app.firebase_auth.get_firebase_app",
        lambda: (_ for _ in ()).throw(RuntimeError("private credential data")),
    )
    caplog.set_level(logging.ERROR, logger="sahaay.fcm")

    result = fcm_sender.send_push_notification_to_user("user-a", "Title", "Body")

    assert result == {"accepted_by_fcm": 0, "failed": 1, "invalid": 0}
    assert "FCM initialization failed" in caplog.text
    assert "RuntimeError" in caplog.text
    assert "private credential data" not in caplog.text
    assert "invalid-token" not in caplog.text


def test_sender_isolates_transient_fcm_failure_without_logging_token(
    monkeypatch, caplog
):
    import logging

    database = _SenderDatabase()
    monkeypatch.setattr("app.firebase_auth.get_firebase_app", lambda: object())
    monkeypatch.setattr("app.supabase_client.get_supabase_client", lambda: database)
    caplog.set_level(logging.WARNING, logger="sahaay.fcm")

    def raise_transient(*_args, **_kwargs):
        raise RuntimeError("offline invalid-token")

    monkeypatch.setattr(fcm_sender.firebase_messaging, "send", raise_transient)

    result = fcm_sender.send_push_notification_to_user("user-a", "Title", "Body")

    assert result["failed"] == 1
    assert database.rows
    assert "RuntimeError" in caplog.text
    assert "invalid-token" not in caplog.text


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

    class NGODatabase:
        def table(self, name):
            assert name == "ngos"
            return NGOQuery()

    sent = []
    monkeypatch.setattr(
        "app.supabase_client.get_supabase_client", lambda: NGODatabase()
    )
    monkeypatch.setattr(
        fcm_sender,
        "send_push_notification_to_user",
        lambda user_id, *_args, **_kwargs: sent.append(user_id)
        or {"accepted_by_fcm": 1},
    )

    result = fcm_sender.send_notification_to_ngo("ngo-row-7", "title", "body")

    assert result == {"accepted_by_fcm": 1}
    assert sent == ["user-row-9"]
