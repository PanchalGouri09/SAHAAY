from collections.abc import Callable

from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

from app.firebase_auth import verify_firebase_token
from app.supabase_client import get_supabase_client

bearer_scheme = HTTPBearer(auto_error=False)


def get_current_firebase_user(
    credentials: HTTPAuthorizationCredentials | None = Depends(bearer_scheme),
) -> dict:
    if credentials is None or credentials.scheme.lower() != "bearer":
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Bearer authentication is required.",
            headers={"WWW-Authenticate": "Bearer"},
        )
    return verify_firebase_token(credentials.credentials)


def get_current_profile(current_user: dict = Depends(get_current_firebase_user)) -> dict:
    firebase_uid = current_user.get("uid")
    if not firebase_uid:
        raise HTTPException(status_code=401, detail="Firebase token has no user identity.")
    record = (
        get_supabase_client()
        .table("users")
        .select("*, providers(*), ngos(*), volunteers(*)")
        .eq("firebase_uid", firebase_uid)
        .maybe_single()
        .execute()
    )
    if record is None:
        raise HTTPException(status_code=404, detail="SAHAAY profile not found.")
    return record.data


def require_role(role: str) -> Callable:
    def dependency(profile: dict = Depends(get_current_profile)) -> dict:
        if profile.get("role") != role:
            raise HTTPException(status_code=403, detail="Insufficient role for this operation.")
        return profile

    return dependency


def require_any_role(*roles: str) -> Callable:
    """Like require_role, but admits any of several roles.

    Used where an action is legitimately performed by more than one party
    (e.g. handover verification, which either the donating provider or the
    receiving NGO may confirm). The route itself must still scope the data to
    the caller's own organisation.
    """

    allowed = set(roles)

    def dependency(profile: dict = Depends(get_current_profile)) -> dict:
        if profile.get("role") not in allowed:
            raise HTTPException(status_code=403, detail="Insufficient role for this operation.")
        return profile

    return dependency
