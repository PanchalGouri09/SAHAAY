typedef NotificationCopy = ({String title, String body});

const String genericNotificationFallbackBody = 'You have a new update.';

String notificationFallbackBodyForType(String? type) => switch (type) {
      'donation' ||
      'donation_created' ||
      'new_nearby_donation' =>
        'You have a new donation update.',
      _ => genericNotificationFallbackBody,
    };

final _notificationUnsafePatterns = [
  RegExp(r'\b[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\b',
      caseSensitive: false),
  RegExp(
      r'\b(?:don|ngo|claim|offer|user|prov|delivery|vol|notif)-[a-z0-9_-]+\b',
      caseSensitive: false),
  RegExp(
      r'\b(?:donation|ngo|claim|offer|user|provider|delivery|notification)\s+'
      r'(?:id|uuid)\s*[:=#]?\s*[a-z0-9_-]+\b',
      caseSensitive: false),
  RegExp(r'\b(?:id|identifier|uuid|token)\s*[:=#]\s*[a-z0-9_-]+\b',
      caseSensitive: false),
  RegExp(r'\b\d{12,}\b'),
  RegExp(r'\beyJ[a-zA-Z0-9_-]{10,}\.[a-zA-Z0-9_-]{10,}(?:\.[a-zA-Z0-9_-]+)?\b'),
  RegExp(r'\b[a-zA-Z0-9_-]{32,}\b'),
  RegExp(r'[\[\]{}]'),
  RegExp(r'\b[a-zA-Z_]*(?:Error|Exception)\b'),
  RegExp(r'\b(?:request|correlation|trace|log)\s*(?:id|identifier)\b',
      caseSensitive: false),
  RegExp(
    r'\b(traceback|exception|apierror|postgrest|sqlstate|stack trace|'
    r'internal server error|debug|supabase|firebase|http\s*[45]\d\d)\b',
    caseSensitive: false,
  ),
];

NotificationCopy safeNotificationCopy(
  String? title,
  String? body, {
  String fallbackBody = genericNotificationFallbackBody,
}) {
  return (
    title: _safeText(title, 'SAHAAY Notification', 120),
    body: _safeText(body, fallbackBody, 500),
  );
}

String _safeText(String? value, String fallback, int maxLength) {
  final text = value?.trim().replaceAll(RegExp(r'\s+'), ' ') ?? '';
  if (text.isEmpty ||
      text.length > maxLength ||
      _notificationUnsafePatterns.any((pattern) => pattern.hasMatch(text))) {
    return fallback;
  }
  return text;
}
