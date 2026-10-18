class ProfileCompletion {
  final String role;
  final int completedFields;
  final int totalFields;
  final int percentage;
  final List<String> missingFields;

  const ProfileCompletion({
    required this.role,
    required this.completedFields,
    required this.totalFields,
    required this.percentage,
    required this.missingFields,
  });

  bool get isComplete => missingFields.isEmpty;

  factory ProfileCompletion.fromBackend(Map<String, dynamic>? value) {
    final rawMissing = value?['missing_fields'];
    final parsedMissing = rawMissing is List
        ? rawMissing.whereType<String>().toList(growable: false)
        : const <String>[];
    final completed = value?['completed_fields'];
    final total = value?['total_fields'];
    final percentage = value?['percentage'];
    final completedNumber = completed is num ? completed : null;
    final totalNumber = total is num ? total : null;
    final percentageNumber = percentage is num ? percentage : null;
    final structurallyValid = value != null &&
        value['role'] is String &&
        value['role'].toString().isNotEmpty &&
        value['complete'] is bool &&
        rawMissing is List &&
        rawMissing.every((item) => item is String) &&
        completedNumber != null &&
        totalNumber != null &&
        totalNumber > 0 &&
        completedNumber >= 0 &&
        completedNumber <= totalNumber &&
        percentageNumber != null &&
        percentageNumber >= 0 &&
        percentageNumber <= 100 &&
        (value['complete'] == parsedMissing.isEmpty);
    final missing = structurallyValid
        ? parsedMissing
        : const <String>['Profile details could not be verified'];
    return ProfileCompletion(
      role: structurallyValid ? value['role'].toString() : '',
      completedFields: structurallyValid ? completedNumber.toInt() : 0,
      totalFields: structurallyValid ? totalNumber.toInt() : 0,
      percentage: structurallyValid ? percentageNumber.toInt() : 0,
      missingFields: missing,
    );
  }

  /// Local fallback for older backend responses. The dashboard prefers the
  /// privacy-safe server report when present.
  factory ProfileCompletion.calculate({
    required String role,
    required Map<String, dynamic> account,
    required Map<String, dynamic> roleProfile,
  }) {
    bool hasText(Object? value) => value is String && value.trim().isNotEmpty;
    bool validCoordinates() {
      final lat = _number(roleProfile['latitude']);
      final lon = _number(roleProfile['longitude']);
      return lat != null &&
          lon != null &&
          lat.isFinite &&
          lon.isFinite &&
          lat >= -90 &&
          lat <= 90 &&
          lon >= -180 &&
          lon <= 180;
    }

    bool validPhone(Object? value) {
      if (!hasText(value)) return false;
      final digits = (value as String).replaceAll(RegExp(r'\D'), '');
      return digits.length >= 7 && digits.length <= 15;
    }

    bool validList(Object? value) =>
        value is List &&
        value.isNotEmpty &&
        value.every((item) => item is String && item.trim().isNotEmpty);

    final checks = <(String, bool)>[
      ('Contact name', hasText(account['full_name'])),
      ('Account email', _validEmail(account['email'])),
      (
        'Contact phone',
        validPhone(account['phone'] ?? roleProfile['phone']),
      ),
    ];
    if (role == 'provider') {
      checks.addAll([
        ('Organization name', hasText(roleProfile['organization_name'])),
        ('Pickup address', hasText(roleProfile['address'])),
        ('City', hasText(roleProfile['city'])),
        ('Pickup location coordinates', validCoordinates()),
      ]);
    } else if (role == 'ngo') {
      final start = roleProfile['available_from'];
      final end = roleProfile['available_to'];
      final validHours = start is String &&
          end is String &&
          RegExp(r'^(?:[01]\d|2[0-3]):[0-5]\d$').hasMatch(start) &&
          RegExp(r'^(?:[01]\d|2[0-3]):[0-5]\d$').hasMatch(end) &&
          start != end;
      checks.addAll([
        ('Organization name', hasText(roleProfile['organization_name'])),
        ('Address', hasText(roleProfile['address'])),
        ('City', hasText(roleProfile['city'])),
        ('Location coordinates', validCoordinates()),
        ('Operating hours', validHours),
        (
          'Maximum donation capacity (kg)',
          (_number(roleProfile['max_capacity_kg']) ?? 0) > 0,
        ),
        (
          'Preferred food types',
          validList(roleProfile['preferred_food_types'])
        ),
        ('Dietary preferences', validList(roleProfile['dietary_preferences'])),
      ]);
    }
    final missing = [
      for (final (label, complete) in checks)
        if (!complete) label,
    ];
    final completed = checks.length - missing.length;
    return ProfileCompletion(
      role: role,
      completedFields: completed,
      totalFields: checks.length,
      percentage:
          checks.isEmpty ? 100 : (completed * 100 / checks.length).round(),
      missingFields: missing,
    );
  }
}

double? _number(Object? value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value.trim());
  return null;
}

bool _validEmail(Object? value) {
  if (value is! String) return false;
  final parts = value.trim().split('@');
  return parts.length == 2 &&
      parts.first.isNotEmpty &&
      parts.last.contains('.') &&
      !parts.last.startsWith('.') &&
      !parts.last.endsWith('.');
}
