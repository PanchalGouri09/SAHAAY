from fastapi.testclient import TestClient

from app.dependencies import get_current_profile
from app.main import app
from app.routers import device_tokens
from app.schemas.device_token import DeviceTokenRegister


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
        self.operation = "upsert"
        self.values = values
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
            row for row in rows
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


def test_register_uses_authenticated_profile_and_upserts(monkeypatch):
    database = _Database()
    monkeypatch.setattr(device_tokens, "get_supabase_client", lambda: database)
    profile = {"id": "user-row-id", "firebase_uid": "firebase-uid"}
    payload = DeviceTokenRegister(token="fcm-token", platform="android")

    first = device_tokens.register_device_token(payload, profile)
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


def test_list_and_delete_are_scoped_to_authenticated_profile(monkeypatch):
    database = _Database()
    database.rows.extend(
        [
            {
                "id": "owned",
                "user_id": "user-a",
                "token": "token-a",
                "platform": "android",
                "created_at": "now",
                "updated_at": "now",
            },
            {
                "id": "other",
                "user_id": "user-b",
                "token": "token-b",
                "platform": "android",
                "created_at": "now",
                "updated_at": "now",
            },
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
