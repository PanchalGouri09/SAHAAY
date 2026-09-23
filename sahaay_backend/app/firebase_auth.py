from functools import lru_cache

import firebase_admin
from firebase_admin import auth, credentials
from fastapi import HTTPException, status

from app.config import get_settings


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
        get_firebase_app()
        return auth.verify_id_token(token, check_revoked=True)
    except Exception as exc:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid or expired Firebase authentication.",
            headers={"WWW-Authenticate": "Bearer"},
        ) from exc
