/// Normalizes a formatted Indian mobile number to its 10 local digits.
///
/// Formatting separators and an optional India country prefix are accepted;
/// other characters, incorrect lengths, and non-mobile leading digits fail.
String? normalizeIndianMobileNumber(String? phone) {
  final value = phone?.trim() ?? '';
  if (value.isEmpty || !RegExp(r'^(?:\+|00)?[0-9\s().-]+$').hasMatch(value)) {
    return null;
  }

  var compact = value.replaceAll(RegExp(r'[\s().-]'), '');
  if (compact.startsWith('+91')) {
    compact = compact.substring(3);
  } else if (compact.startsWith('0091')) {
    compact = compact.substring(4);
  } else if (compact.startsWith('91') && compact.length == 12) {
    compact = compact.substring(2);
  }

  return RegExp(r'^[6-9][0-9]{9}$').hasMatch(compact) ? compact : null;
}

/// Returns a `tel:` URI for a plausibly valid phone number, or null when the
/// input contains unsupported characters or an unusable number of digits.
Uri? dialerUriForPhone(String? phone) {
  final value = phone?.trim() ?? '';
  if (value.isEmpty) return null;

  final normalized = value.replaceAll(RegExp(r'[\s().-]'), '');
  if (!RegExp(r'^\+?\d{7,15}$').hasMatch(normalized)) return null;
  return Uri(scheme: 'tel', path: normalized);
}
