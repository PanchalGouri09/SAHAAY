import 'package:flutter_test/flutter_test.dart';
import 'package:sahaay/services/notification_copy.dart';

void main() {
  group('safeNotificationCopy', () {
    test('preserves readable content and trims surrounding whitespace', () {
      expect(
        safeNotificationCopy('  Donation claimed  ', '  Rice is ready.  '),
        (title: 'Donation claimed', body: 'Rice is ready.'),
      );
    });

    test('replaces UUIDs, opaque tokens, JSON, and diagnostics', () {
      expect(
        safeNotificationCopy(
          'Donation 11111111-2222-3333-4444-555555555555',
          'Readable update',
        ).title,
        'SAHAAY Notification',
      );
      expect(
        safeNotificationCopy('Donation update', '{"detail":"SQLSTATE 42P10"}')
            .body,
        'You have a new update.',
      );
      expect(
        safeNotificationCopy(
          'Donation update',
          'FCM token ${List.filled(40, 'a').join()}',
        ).body,
        'You have a new update.',
      );
      expect(
        safeNotificationCopy(
          'Donation update',
          'PostgREST APIError: HTTP 503',
        ).body,
        'You have a new update.',
      );
      expect(
        safeNotificationCopy(
          'Donation update',
          'Next NGO ID: 843719',
        ).body,
        'You have a new update.',
      );
    });

    test('uses readable defaults for missing notification content', () {
      expect(
        safeNotificationCopy(null, ''),
        (title: 'SAHAAY Notification', body: 'You have a new update.'),
      );
    });
  });
}
