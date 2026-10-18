"""Firebase Cloud Messaging push transport for SAHAAY notifications.

This is the ONLY module that talks to Firebase Cloud Messaging. It resolves a
user's registered device tokens from `user_device_tokens` (RLS-enabled,
service-role only) and fans a single notification out to every device the user
has registered.

Guarantees:
  * Best-effort: it never raises into the caller. `notification_service.notify`
    persists the durable `notifications` row FIRST, so a push failure can never
    lose a notification.
  * Stale-token pruning: a token Firebase reports as unregistered is deleted
    from the table so dead tokens do not accumulate.
  * Server-resolved recipients only: the token set comes from the database
    relationship (users.id -> user_device_tokens), never from a request body.

The push requests a high-importance Android channel with the OS default
notification sound and an APNs alert with sound. Actual audibility remains
subject to OS permissions, channel settings, silent mode, and Do Not Disturb.
The channel id must match the one registered by the Flutter client.
"""

from __future__ import annotations

import logging

from firebase_admin import messaging as firebase_messaging

from app import firebase_auth, supabase_client

logger = logging.getLogger("sahaay.fcm")

DEVICE_TOKENS_TABLE = "user_device_tokens"

# Must match the high-importance channel the Flutter client creates. The
# channel owns the sound/vibration, so the same channel id here is what makes
# the alert audible on Android 8+.
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
    user_id: str, title: str, body: str, data: dict | None = None
) -> dict:
    """Push to every device registered to `user_id`. Never raises.

    Returns a summary {"sent", "failed", "invalid"} for observability.
    """
    result = {"sent": 0, "failed": 0, "invalid": 0}
    if not user_id:
        return result

    client = supabase_client.get_supabase_client()
    tokens = _device_tokens(client, user_id)
    if not tokens:
        return result

    try:
        app = firebase_auth.get_firebase_app()
    except Exception as exc:  # noqa: BLE001
        # Push is optional in this build. The durable row already exists, so the
        # app still shows the notification when it next reads the table.
        logger.info("FCM is not configured; push skipped: %s", exc)
        return result

    payload = {str(k): str(v) for k, v in (data or {}).items()}
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
