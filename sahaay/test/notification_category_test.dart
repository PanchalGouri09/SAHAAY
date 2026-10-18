import 'package:flutter_test/flutter_test.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

import 'package:sahaay/main.dart';

/// Phase D regression tests: every backend business `type` must map onto the
/// right icon category, and the two event types that were previously unwired
/// (`donation_created`, `handover_completed`) must now be recognised rather
/// than silently falling through to `system`. Unknown types stay `system`.
void main() {
  group('notificationCategoryForType', () {
    test('donation lifecycle events are donation/matching', () {
      expect(notificationCategoryForType('donation_created'),
          NotificationCategory.donation);
      expect(notificationCategoryForType('new_nearby_donation'),
          NotificationCategory.donation);
      expect(notificationCategoryForType('donation_claimed'),
          NotificationCategory.matching);
      expect(notificationCategoryForType('donation_offer'),
          NotificationCategory.matching);
      expect(notificationCategoryForType('donation_no_match'),
          NotificationCategory.matching);
      expect(notificationCategoryForType('claim_created'),
          NotificationCategory.matching);
      expect(notificationCategoryForType('claim_escalation'),
          NotificationCategory.matching);
    });

    test('delivery and handover events are volunteer', () {
      expect(notificationCategoryForType('volunteer_assigned'),
          NotificationCategory.volunteer);
      expect(notificationCategoryForType('pickup_updated'),
          NotificationCategory.volunteer);
      expect(notificationCategoryForType('delivery_completed'),
          NotificationCategory.volunteer);
      expect(notificationCategoryForType('delivery_failed'),
          NotificationCategory.volunteer);
      expect(notificationCategoryForType('handover_verified'),
          NotificationCategory.volunteer);
      expect(notificationCategoryForType('handover_completed'),
          NotificationCategory.volunteer);
      expect(notificationCategoryForType('acknowledgment_ready'),
          NotificationCategory.volunteer);
    });

    test('reward and unknown types fall through honestly', () {
      expect(
          notificationCategoryForType('reward'), NotificationCategory.reward);
      expect(notificationCategoryForType('something_new'),
          NotificationCategory.system);
      expect(notificationCategoryForType(null), NotificationCategory.system);
      expect(notificationCategoryForType(''), NotificationCategory.system);
    });
  });

  group('notificationTapContent', () {
    test('uses the payload type and title/body', () {
      final content = notificationTapContent(const RemoteMessage(
        data: {
          'type': 'handover_completed',
          'title': 'Donation completed',
          'body': 'The receipt is still being prepared.',
        },
      ));
      expect(content.category, NotificationCategory.volunteer);
      expect(content.title, 'Donation completed');
      expect(content.body, 'The receipt is still being prepared.');
    });

    test('falls back to a system update with a safe default text', () {
      final content = notificationTapContent(const RemoteMessage(data: {}));
      expect(content.category, NotificationCategory.system);
      expect(content.title, 'SAHAAY Notification');
      expect(content.body, 'You have a new update.');
    });

    test('does not display opaque identifiers from push copy', () {
      final content = notificationTapContent(const RemoteMessage(
        data: {
          'type': 'donation_no_match',
          'title': 'Offer 11111111-2222-3333-4444-555555555555',
          'body': 'There is an update.',
        },
      ));
      expect(content.category, NotificationCategory.matching);
      expect(content.title, 'SAHAAY Notification');
      expect(content.body, 'There is an update.');
    });
  });
}
