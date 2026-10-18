import 'dart:convert';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'notification_copy.dart';

/// Firebase Cloud Messaging + local rendering for SAHAAY.
///
/// FCM delivers the push; this service requests the OS default sound on Android:
///  * it creates the high-importance `sahaay_notifications` channel the backend
///    targets, so a background/terminated push is shown in the tray and requests
///    the default sound when permitted by the OS and channel settings;
///  * it renders a foreground push itself (FCM does not show foreground
///    messages), again through the same channel.
class PushNotifications {
  PushNotifications._();

  static const String channelId = 'sahaay_notifications';
  static const String channelName = 'SAHAAY Notifications';
  static const String channelDescription =
      'Donation, claim, pickup and delivery updates from SAHAAY.';

  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  static void Function(String? payload)? onNotificationTap;

  static const NotificationDetails _foregroundDetails = NotificationDetails(
    android: AndroidNotificationDetails(
      channelId,
      channelName,
      channelDescription: channelDescription,
      icon: 'ic_stat_sahaay',
      largeIcon: DrawableResourceAndroidBitmap('sahaay_notification_large'),
      importance: Importance.max,
      priority: Priority.high,
      playSound: true,
      enableVibration: true,
    ),
  );

  /// Creates the Android channel and initialises local notifications. Safe to
  /// call more than once; a failure is best-effort and cannot block normal app
  /// use. Android may retain the channel's original user-selected sound.
  static Future<void> initialize() async {
    try {
      const initSettings = InitializationSettings(
        android: AndroidInitializationSettings('ic_stat_sahaay'),
        iOS: DarwinInitializationSettings(),
      );
      await _plugin.initialize(
        initSettings,
        onDidReceiveNotificationResponse: (response) {
          onNotificationTap?.call(response.payload);
        },
      );
      if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
      final android = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      await android?.createNotificationChannel(
        const AndroidNotificationChannel(
          channelId,
          channelName,
          description: channelDescription,
          importance: Importance.max,
          playSound: true,
          enableVibration: true,
        ),
      );
    } catch (_) {
      // Push is best-effort; the app must still run without it.
    }
  }

  /// Asks the OS for notification permission (Android 13+ / iOS). Returns true
  /// when notifications are allowed.
  static Future<bool> requestPermission() async {
    try {
      final settings = await FirebaseMessaging.instance.requestPermission(
        alert: true,
        badge: true,
        sound: true,
        provisional: false,
      );
      return settings.authorizationStatus == AuthorizationStatus.authorized ||
          settings.authorizationStatus == AuthorizationStatus.provisional;
    } catch (_) {
      return false;
    }
  }

  /// Displays a foreground push as a real system notification on the audible
  /// channel.
  static Future<void> showForeground(RemoteMessage message) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      final notification = message.notification;
      final copy = safeNotificationCopy(
        notification?.title ?? message.data['title']?.toString(),
        notification?.body ?? message.data['body']?.toString(),
        fallbackBody:
            notificationFallbackBodyForType(message.data['type']?.toString()),
      );
      final id = message.messageId?.hashCode ??
          DateTime.now().millisecondsSinceEpoch.remainder(1 << 31);
      await _plugin.show(id, copy.title, copy.body, _foregroundDetails,
          payload: jsonEncode(message.data));
    } catch (_) {
      // A failed render must never crash the foreground message handler.
    }
  }

  /// The platform string the backend stores for this device.
  static String get platform {
    if (kIsWeb) return 'web';
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return 'android';
      case TargetPlatform.iOS:
        return 'ios';
      default:
        return defaultTargetPlatform.name.toLowerCase();
    }
  }
}

/// Registered with [FirebaseMessaging.onBackgroundMessage]. Runs in its own
/// isolate; the system tray displays the notification, so nothing else is
/// required here.
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {}
