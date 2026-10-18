import 'package:flutter_test/flutter_test.dart';
import 'package:sahaay/services/phone_contact.dart';

void main() {
  group('normalizeIndianMobileNumber', () {
    test('accepts local digits and common formatting', () {
      expect(normalizeIndianMobileNumber('9876543210'), '9876543210');
      expect(normalizeIndianMobileNumber('+91 (98765) 43210'), '9876543210');
      expect(normalizeIndianMobileNumber('0091-98765-43210'), '9876543210');
      expect(normalizeIndianMobileNumber('91 98765 43210'), '9876543210');
    });

    test('rejects invalid length, characters and leading digits', () {
      for (final invalid in [
        '',
        '987654321',
        '98765432101',
        '5123456789',
        '98765abc10',
        '98765/43210',
        '+44 9876543210',
      ]) {
        expect(
          normalizeIndianMobileNumber(invalid),
          isNull,
          reason: '$invalid must not be accepted',
        );
      }
    });
  });

  group('dialerUriForPhone', () {
    test('normalizes a valid formatted international number', () {
      expect(dialerUriForPhone('+91 (883) 039-2843'),
          Uri.parse('tel:+918830392843'));
    });

    test('returns null for missing or malformed numbers', () {
      expect(dialerUriForPhone(null), isNull);
      expect(dialerUriForPhone(''), isNull);
      expect(dialerUriForPhone('call me at 8830392843'), isNull);
      expect(dialerUriForPhone('1234'), isNull);
      expect(dialerUriForPhone('+1234567890123456'), isNull);
    });
  });
}
