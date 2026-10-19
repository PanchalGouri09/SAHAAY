import 'dart:io';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sahaay/services/push_notifications.dart';

void main() {
  test('uses a new audible channel with the SAHAAY double-tone resource', () {
    const channel = PushNotifications.androidChannel;

    expect(channel.id, 'sahaay_notifications_v2');
    expect(channel.playSound, isTrue);
    expect(channel.importance, Importance.max);
    expect(channel.sound, isA<RawResourceAndroidNotificationSound>());
    expect(channel.sound?.sound, 'sahaay_ting_ting');
  });

  test('notification sound resource exists in Android raw resources', () {
    final sound = File('android/app/src/main/res/raw/sahaay_ting_ting.wav');
    expect(sound.existsSync(), isTrue);
    expect(sound.lengthSync(), greaterThan(1024));
  });

  test('registers rotated FCM tokens and ignores empty refresh values',
      () async {
    final registered = <String>[];
    final subscription = PushNotifications.listenForTokenRefresh(
      tokenStream: Stream<String>.fromIterable(['', 'rotated-token']),
      onToken: registered.add,
    );

    await subscription.asFuture<void>();

    expect(registered, ['rotated-token']);
  });

  test('forwards foreground FCM messages to the single renderer', () async {
    final message = RemoteMessage(
      messageId: 'message-1',
      data: const {'type': 'pickup_reminder'},
    );
    final received = <RemoteMessage>[];
    final subscription = PushNotifications.listenForForegroundMessages(
      messageStream: Stream<RemoteMessage>.value(message),
      onMessage: received.add,
    );

    await subscription.asFuture<void>();

    expect(received, [same(message)]);
  });

  test('background handler leaves display to Android FCM system handling',
      () async {
    await firebaseMessagingBackgroundHandler(
      RemoteMessage(
        messageId: 'background-message',
        notification: const RemoteNotification(
          title: 'Delivery update',
          body: 'A volunteer accepted the task.',
        ),
      ),
    );
  });
}
