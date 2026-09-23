from fastapi.testclient import TestClient

from app.main import app

client = TestClient(app)


def test_health() -> None:
    response = client.get("/health")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


def test_profile_requires_bearer_token() -> None:
    response = client.get("/api/v1/profile")
    assert response.status_code == 401


def test_profile_creation_requires_authentication() -> None:
    response = client.post("/api/v1/profile", json={"full_name": "Test", "email": "test@example.com", "role": "provider"})
    assert response.status_code == 401


def test_notifications_require_authentication() -> None:
    response = client.get("/api/v1/notifications")
    assert response.status_code == 401
    assert response.json()["detail"] == "Bearer authentication is required."


def test_profile_rejects_invalid_bearer_token() -> None:
    response = client.get("/api/v1/profile", headers={"Authorization": "Bearer invalid"})
    assert response.status_code == 401


def test_provider_route_requires_authentication() -> None:
    response = client.post("/api/v1/donations", json={})
    assert response.status_code == 401
