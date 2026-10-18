import logging
from functools import lru_cache

from google.auth import exceptions as google_auth_exceptions
import firebase_admin
from firebase_admin import auth, credentials
from fastapi import HTTPException, status

from app.config import get_settings

logger = logging.getLogger("sahaay.firebase_auth")


def _safe_verification_diagnostic(exc: Exception) -> str:
    if not isinstance(exc, google_auth_exceptions.RefreshError):
        return "details redacted"

    message = " ".join(str(argument) for argument in exc.args).lower()
    if "invalid_grant" in message:
        return "credential refresh rejected (invalid_grant)"
    if "invalid_client" in message:
        return "credential refresh rejected (invalid_client)"
    if "unauthorized_client" in message:
        return "credential refresh rejected (unauthorized_client)"
    if "invalid_scope" in message:
        return "credential refresh rejected (invalid_scope)"
    if "invalid jwt signature" in message or "invalid_jwt" in message:
        return "credential assertion rejected (invalid JWT/signature)"
    if "timed out" in message or "timeout" in message:
        return "credential refresh timed out"
    if "connection" in message or "name resolution" in message:
        return "credential refresh connection failure"
    return "credential refresh failed (details redacted)"


@lru_cache
def get_firebase_app() -> firebase_admin.App:
    settings = get_settings()
    if not settings.firebase_configured:
        raise RuntimeError("Firebase Admin credentials are not configured")
    if firebase_admin._apps:
        return firebase_admin.get_app()

    private_key = settings.firebase_private_key.replace("\\n", "\n")
    credential = credentials.Certificate(
        {
            "type": "service_account",
            "project_id": settings.firebase_project_id,
            "private_key": private_key,
            "private_key_id": "configured-at-runtime",
            "client_email": settings.firebase_client_email,
            "client_id": "configured-at-runtime",
            "auth_uri": "https://accounts.google.com/o/oauth2/auth",
            "token_uri": "https://oauth2.googleapis.com/token",
            "auth_provider_x509_cert_url": "https://www.googleapis.com/oauth2/v1/certs",
            "client_x509_cert_url": "configured-at-runtime",
        }
    )
    return firebase_admin.initialize_app(credential)


def verify_firebase_token(token: str) -> dict:
    try:
        app = get_firebase_app()
    except Exception as exc:
        logger.error("Firebase Admin initialization failed (%s)", type(exc).__name__)
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Firebase authentication service is unavailable.",
            headers={"WWW-Authenticate": "Bearer"},
        ) from exc

    try:
        return auth.verify_id_token(token, app=app, check_revoked=True)
    except (auth.InvalidIdTokenError, auth.UserDisabledError) as exc:
        logger.info("Firebase ID token rejected (%s)", type(exc).__name__)
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid or expired Firebase authentication.",
            headers={"WWW-Authenticate": "Bearer"},
        ) from exc
    except Exception as exc:
        diagnostic = _safe_verification_diagnostic(exc)
        logger.error(
            "Firebase ID token verification failed (%s; %s)",
            type(exc).__name__,
            diagnostic,
        )
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Firebase authentication service is unavailable.",
            headers={"WWW-Authenticate": "Bearer"},
        ) from exc


def firebase_user_exists(uid: str) -> bool:
    """Whether `uid` still maps to a live Firebase Authentication user.

    Used to tell a genuinely active account apart from an *orphaned* SAHAAY
    row whose Firebase user was deleted. Only an explicit ``UserNotFoundError``
    is treated as "gone"; if liveness cannot be determined (Admin unavailable
    or a transient error) this stays conservative and reports ``True`` so the
    caller never re-links over a possibly-active account.
    """
    try:
        get_firebase_app()
    except Exception:  # noqa: BLE001 - misconfigured Admin -> treat as active
        return True
    try:
        auth.get_user(uid)
        return True
    except auth.UserNotFoundError:
        return False
    except Exception:  # noqa: BLE001 - unknown failure -> treat as active
        return True
