"""Best-effort Firebase Cloud Messaging transport for SAHAAY notifications.

Durable notification rows are written by the notification service before this
module is called. Push failures therefore never block the underlying action.
"""

from __future__ import annotations

import logging

from firebase_admin import messaging as firebase_messaging

from app import firebase_auth, supabase_client

logger = logging.getLogger("sahaay.fcm")

DEVICE_TOKENS_TABLE = "user_device_tokens"
ANDROID_CHANNEL_ID = "sahaay_notifications"


def _device_tokens(client, user_id: str) -> list[dict]:
    try:
        rows = (
            client.table(DEVICE_TOKENS_TABLE)
            .select("token,platform")
            .eq("user_id", str(user_id))
            .execute()
        )
    except Exception as exc:  # noqa: BLE001
        logger.info("Could not load device tokens for %s: %s", user_id, exc)
        return []
    return getattr(rows, "data", None) or []


def _prune_token(client, token: str) -> None:
    try:
        client.table(DEVICE_TOKENS_TABLE).delete().eq("token", token).execute()
    except Exception as exc:  # noqa: BLE001
        logger.info("Could not prune stale device token: %s", exc)


def _android_config() -> "firebase_messaging.AndroidConfig":
    return firebase_messaging.AndroidConfig(
        priority="high",
        notification=firebase_messaging.AndroidNotification(
            channel_id=ANDROID_CHANNEL_ID,
            sound="default",
            default_sound=True,
            priority="high",
            default_vibrate_timings=True,
        ),
    )


def _apns_config() -> "firebase_messaging.APNSConfig":
    return firebase_messaging.APNSConfig(
        payload=firebase_messaging.APNSPayload(
            aps=firebase_messaging.Aps(sound="default", content_available=True),
        ),
    )


def send_push_notification_to_user(
    user_id: str,
    title: str,
    body: str,
    data: dict | None = None,
) -> dict:
    """Push to every device registered to ``user_id``; never raise."""
    result = {"sent": 0, "failed": 0, "invalid": 0}
    if not user_id:
        return result

    try:
        client = supabase_client.get_supabase_client()
        tokens = _device_tokens(client, user_id)
    except Exception as exc:  # noqa: BLE001
        logger.info("Could not initialize device-token lookup: %s", exc)
        return result
    if not tokens:
        return result

    try:
        app = firebase_auth.get_firebase_app()
    except Exception as exc:  # noqa: BLE001
        logger.info("FCM is not configured; push skipped: %s", exc)
        return result

    payload = {str(key): str(value) for key, value in (data or {}).items()}
    for row in tokens:
        token = row.get("token")
        if not token:
            continue
        try:
            message = firebase_messaging.Message(
                notification=firebase_messaging.Notification(title=title, body=body),
                data=payload,
                token=token,
                android=_android_config(),
                apns=_apns_config(),
            )
            firebase_messaging.send(message, app=app)
            result["sent"] += 1
        except firebase_messaging.UnregisteredError:
            result["invalid"] += 1
            _prune_token(client, token)
        except Exception as exc:  # noqa: BLE001
            result["failed"] += 1
            logger.info("FCM send failed for user %s: %s", user_id, exc)
    return result


def send_notification_to_ngo(
    ngo_id: str,
    title: str,
    body: str,
    data: dict | None = None,
) -> dict:
    """Resolve an NGO's associated user server-side before sending a push."""
    empty_result = {"sent": 0, "failed": 0, "invalid": 0}
    try:
        result = (
            supabase_client.get_supabase_client()
            .table("ngos")
            .select("user_id")
            .eq("id", ngo_id)
            .maybe_single()
            .execute()
        )
    except Exception as exc:  # noqa: BLE001
        logger.info("Could not resolve NGO push recipient: %s", exc)
        return empty_result

    row = getattr(result, "data", None)
    if isinstance(row, list):
        row = row[0] if row else None
    user_id = row.get("user_id") if isinstance(row, dict) else None
    if not user_id:
        return empty_result
    return send_push_notification_to_user(user_id, title, body, data)
