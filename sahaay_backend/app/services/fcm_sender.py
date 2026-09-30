"""
SAHAAY backend Firebase Cloud Messaging sender.

Sends push notifications to registered device tokens via the Firebase Admin SDK.
Handles token validation and graceful failure so that FCM
unavailability never blocks business transactions.

Key design rules:
* Never crash a business operation because FCM failed.
* Invalid/unregistered tokens are detected and can be cleaned up.
* Tokens are looked up by user_id from the database (not trusted from client).
* Database notification persistence is handled separately by business routes.
"""

from firebase_admin import messaging as firebase_messaging
from firebase_admin import exceptions as firebase_exceptions
from fastapi import HTTPException, status



def send_push_notification_to_user(
    user_id: str,
    title: str,
    body: str,
    data: dict | None = None,
) -> dict:
    """Send a push notification to all registered device tokens for a user.

    Args:
        user_id: The backend-derived user ID from the users table.
        title: Notification title.
        body: Notification body.
        data: Optional data payload to include with the notification.

    Returns:
        Dict with send results summary.

    Raises:
        HTTPException: If the FCM service is not configured.
    """
    # Check if Firebase Admin is configured
    try:
        from app.firebase_auth import get_firebase_app
        get_firebase_app()  # Will raise if not configured
    except RuntimeError:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Firebase Admin SDK is not configured on this server.",
        )

    # Get all device tokens for this user
    from app.supabase_client import get_supabase_client
    supabase = get_supabase_client()

    tokens_response = (
        supabase.table("user_device_tokens")
        .select("token, platform")
        .eq("user_id", user_id)
        .execute()
    )

    tokens = tokens_response.data or []
    if not tokens:
        return {"sent": 0, "failed": 0, "invalid": 0, "message": "No device tokens registered for user."}

    results = {"sent": 0, "failed": 0, "invalid": 0}

    for token_entry in tokens:
        token = token_entry.get("token")
        if not token or token.strip() == "":
            results["invalid"] += 1
            continue

        try:
            # Build the message
            message = firebase_messaging.Message(
                notification=firebase_messaging.Notification(
                    title=title,
                    body=body,
                ),
                token=token,
                data={str(key): str(value) for key, value in (data or {}).items()},
            )

            # Send the message
            firebase_messaging.send(message)
            results["sent"] += 1

        except firebase_messaging.UnregisteredError:
            # Token is no longer valid — remove it from the database
            _remove_token(supabase, token)
            results["invalid"] += 1

        except firebase_exceptions.FirebaseError:
            # Transient API error — count as failed, don't remove token
            results["failed"] += 1

        except Exception:
            # Unknown error — count as failed
            results["failed"] += 1

    return results


def _remove_token(supabase, token: str) -> None:
    """Remove an invalid/unregistered device token from the database."""
    try:
        supabase.table("user_device_tokens").delete().eq("token", token).execute()
    except Exception:
        # Best-effort cleanup; don't raise to avoid breaking the sender flow
        pass


def send_notification_to_ngo(
    ngo_id: str,
    title: str,
    body: str,
    data: dict | None = None,
) -> dict:
    """Send a push notification to an NGO's registered device tokens.

    The NGO's user_id is resolved from its trusted backend database row.
    """
    from app.supabase_client import get_supabase_client
    supabase = get_supabase_client()

    # Get the NGO's user_id from the ngos table
    ngo_response = (
        supabase.table("ngos")
        .select("user_id")
        .eq("id", ngo_id)
        .maybe_single()
        .execute()
    )

    if not ngo_response.data:
        return {"sent": 0, "failed": 0, "invalid": 0, "message": "NGO not found."}

    user_id = ngo_response.data.get("user_id")
    if not user_id:
        return {"sent": 0, "failed": 0, "invalid": 0, "message": "NGO has no associated user."}

    return send_push_notification_to_user(user_id, title, body, data)

