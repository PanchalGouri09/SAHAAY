from unittest.mock import Mock

import pytest
from firebase_admin import auth
from fastapi import HTTPException
from google.auth.exceptions import RefreshError

from app import firebase_auth


def test_verify_firebase_token_checks_revocation_and_returns_claims(monkeypatch) -> None:
    app = object()
    claims = {"uid": "firebase-user"}
    verify = Mock(return_value=claims)
    monkeypatch.setattr(firebase_auth, "get_firebase_app", lambda: app)
    monkeypatch.setattr(firebase_auth.auth, "verify_id_token", verify)

    result = firebase_auth.verify_firebase_token("test-id-token")

    assert result == claims
    verify.assert_called_once_with("test-id-token", app=app, check_revoked=True)


def test_admin_initialization_failure_is_not_reported_as_invalid_token(
    monkeypatch,
) -> None:
    def fail_initialization():
        raise RuntimeError("Admin credentials are unavailable")

    monkeypatch.setattr(firebase_auth, "get_firebase_app", fail_initialization)

    with pytest.raises(HTTPException) as error:
        firebase_auth.verify_firebase_token("test-id-token")

    assert error.value.status_code == 503
    assert error.value.detail == "Firebase authentication service is unavailable."


@pytest.mark.parametrize(
    "error",
    [
        auth.InvalidIdTokenError("Invalid token"),
        auth.ExpiredIdTokenError("Expired token", Exception("expired")),
        auth.RevokedIdTokenError("Revoked token"),
        auth.UserDisabledError("Disabled user"),
    ],
)
def test_invalid_firebase_credentials_remain_unauthorized(monkeypatch, error) -> None:
    monkeypatch.setattr(firebase_auth, "get_firebase_app", lambda: object())
    monkeypatch.setattr(
        firebase_auth.auth,
        "verify_id_token",
        Mock(side_effect=error),
    )

    with pytest.raises(HTTPException) as raised:
        firebase_auth.verify_firebase_token("test-id-token")

    assert raised.value.status_code == 401
    assert raised.value.detail == "Invalid or expired Firebase authentication."


def test_firebase_verification_service_error_is_unavailable(monkeypatch) -> None:
    monkeypatch.setattr(firebase_auth, "get_firebase_app", lambda: object())
    monkeypatch.setattr(
        firebase_auth.auth,
        "verify_id_token",
        Mock(
            side_effect=auth.CertificateFetchError(
                "Certificate fetch failed", Exception("network unavailable")
            )
        ),
    )

    with pytest.raises(HTTPException) as error:
        firebase_auth.verify_firebase_token("test-id-token")

    assert error.value.status_code == 503
    assert error.value.detail == "Firebase authentication service is unavailable."


def test_refresh_error_logs_safe_reason_without_credentials_or_tokens(
    monkeypatch, caplog
) -> None:
    monkeypatch.setattr(firebase_auth, "get_firebase_app", lambda: object())
    private_key = "-----BEGIN PRIVATE KEY-----sensitive-key-data"
    service_email = "firebase-admin@example.invalid"
    bearer_token = "eyJhbGciOiJIUzI1NiJ9.secret.payload"
    error = RefreshError(
        "invalid_grant: Invalid JWT Signature. "
        f"{private_key} {service_email} Bearer {bearer_token}"
    )
    monkeypatch.setattr(
        firebase_auth.auth,
        "verify_id_token",
        Mock(side_effect=error),
    )

    with pytest.raises(HTTPException) as raised:
        firebase_auth.verify_firebase_token("client-id-token")

    assert raised.value.status_code == 503
    assert "RefreshError" in caplog.text
    assert "invalid_grant" in caplog.text
    assert private_key not in caplog.text
    assert service_email not in caplog.text
    assert bearer_token not in caplog.text


def test_unknown_refresh_error_logs_only_redacted_diagnostic(
    monkeypatch, caplog
) -> None:
    monkeypatch.setattr(firebase_auth, "get_firebase_app", lambda: object())
    monkeypatch.setattr(
        firebase_auth.auth,
        "verify_id_token",
        Mock(side_effect=RefreshError("provider response contains sensitive data")),
    )

    with pytest.raises(HTTPException):
        firebase_auth.verify_firebase_token("client-id-token")

    assert "credential refresh failed (details redacted)" in caplog.text
    assert "provider response contains sensitive data" not in caplog.text
