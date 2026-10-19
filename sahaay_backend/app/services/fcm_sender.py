"""Best-effort Firebase Cloud Messaging transport for SAHAAY notifications.

Durable notification rows are written by the notification service before this
module is called. Push failures therefore never block the underlying action.
"""

from __future__ import annotations

import logging
import re

from firebase_admin import messaging as firebase_messaging

from app import firebase_auth, supabase_client

logger = logging.getLogger("sahaay.fcm")

DEVICE_TOKENS_TABLE = "user_device_tokens"
ANDROID_CHANNEL_ID = "sahaay_notifications_v2"
ANDROID_NOTIFICATION_SOUND = "sahaay_ting_ting"
_SAFE_FCM_ERROR_CODE = re.compile(r"(?:messaging/)?[a-z0-9_-]{1,64}\Z")


def _device_tokens(client, user_id: str) -> list[dict]:
    rows = (
        client.table(DEVICE_TOKENS_TABLE)
        .select("token,platform")
        .eq("user_id", str(user_id))
        .execute()
    )
    return getattr(rows, "data", None) or []


def _prune_token(client, token: str) -> None:
    try:
        client.table(DEVICE_TOKENS_TABLE).delete().eq("token", token).execute()
    except Exception as exc:  # noqa: BLE001
        logger.warning(
            "Could not prune stale FCM token error_type=%s", type(exc).__name__
        )


def _android_config() -> "firebase_messaging.AndroidConfig":
    return firebase_messaging.AndroidConfig(
        priority="high",
        notification=firebase_messaging.AndroidNotification(
            channel_id=ANDROID_CHANNEL_ID,
            sound=ANDROID_NOTIFICATION_SOUND,
            default_sound=False,
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
    """Push to registered devices; acceptance by FCM does not confirm receipt."""
    result = {"accepted_by_fcm": 0, "failed": 0, "invalid": 0}
    if not user_id:
        return result

    try:
        client = supabase_client.get_supabase_client()
        tokens = _device_tokens(client, user_id)
    except Exception as exc:  # noqa: BLE001
        logger.warning(
            "FCM device-token lookup initialization failed error_type=%s",
            type(exc).__name__,
        )
        return result
    tokens = [
        row
        for row in tokens
        if isinstance(row, dict)
        and isinstance(row.get("token"), str)
        and row["token"].strip()
    ]
    logger.info("FCM send attempted recipient_count=%d", len(tokens))
    if not tokens:
        logger.info("FCM push skipped reason=no_registered_device_tokens")
        return result

    try:
        app = firebase_auth.get_firebase_app()
    except Exception as exc:  # noqa: BLE001
        logger.error("FCM initialization failed error_type=%s", type(exc).__name__)
        result["failed"] = len(tokens)
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
            result["accepted_by_fcm"] += 1
        except firebase_messaging.UnregisteredError:
            result["invalid"] += 1
            _prune_token(client, token)
            logger.info("FCM removed an unregistered device token")
        except Exception as exc:  # noqa: BLE001
            result["failed"] += 1
            code = getattr(exc, "code", None)
            safe_code = (
                code
                if isinstance(code, str) and _SAFE_FCM_ERROR_CODE.fullmatch(code)
                else "unknown"
            )
            logger.warning(
                "FCM send failed error_type=%s error_code=%s",
                type(exc).__name__,
                safe_code,
            )
    logger.info(
        "FCM send result accepted_by_fcm=%d failed=%d invalid=%d",
        result["accepted_by_fcm"],
        result["failed"],
        result["invalid"],
    )
    return result


def send_notification_to_ngo(
    ngo_id: str,
    title: str,
    body: str,
    data: dict | None = None,
) -> dict:
    """Resolve an NGO's associated user server-side before sending a push."""
    empty_result = {"accepted_by_fcm": 0, "failed": 0, "invalid": 0}
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
        logger.info(
            "Could not resolve NGO push recipient error_type=%s",
            type(exc).__name__,
        )
        return empty_result

    row = getattr(result, "data", None)
    if isinstance(row, list):
        row = row[0] if row else None
    user_id = row.get("user_id") if isinstance(row, dict) else None
    if not user_id:
        return empty_result
    return send_push_notification_to_user(user_id, title, body, data)
