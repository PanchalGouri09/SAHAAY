import 'package:flutter_test/flutter_test.dart';
import 'package:sahaay/services/profile_completion.dart';

void main() {
  const account = {
    'full_name': 'Test Contact',
    'email': 'contact@example.org',
    'phone': '+91 9876543210',
  };

  test('complete provider profile reaches 100 percent', () {
    final completion = ProfileCompletion.calculate(
      role: 'provider',
      account: account,
      roleProfile: {
        'organization_name': 'Test Kitchen',
        'address': '1 Market Road',
        'city': 'Pune',
        'latitude': 18.52,
        'longitude': 73.85,
      },
    );

    expect(completion.isComplete, isTrue);
    expect(completion.percentage, 100);
    expect(completion.completedFields, completion.totalFields);
    expect(completion.missingFields, isEmpty);
  });

  test('null and malformed NGO values remain incomplete', () {
    final completion = ProfileCompletion.calculate(
      role: 'ngo',
      account: account,
      roleProfile: {
        'organization_name': 'Test Pantry',
        'address': '2 Market Road',
        'city': 'Pune',
        'latitude': 'not-a-coordinate',
        'longitude': 73.86,
        'available_from': '07:00',
        'available_to': null,
        'max_capacity_kg': 0,
        'preferred_food_types': <String>[],
        'dietary_preferences': null,
        'verified': false,
      },
    );

    expect(completion.isComplete, isFalse);
    expect(completion.percentage, lessThan(100));
    expect(completion.missingFields, contains('Location coordinates'));
    expect(completion.missingFields, contains('Operating hours'));
    expect(
      completion.missingFields,
      contains('Maximum donation capacity (kg)'),
    );
    expect(completion.missingFields, contains('Preferred food types'));
    expect(completion.missingFields, contains('Dietary preferences'));
  });

  test('legacy NGO verification does not affect profile completion', () {
    final completion = ProfileCompletion.calculate(
      role: 'ngo',
      account: account,
      roleProfile: {
        'organization_name': 'Test Pantry',
        'address': '2 Market Road',
        'city': 'Pune',
        'latitude': 18.53,
        'longitude': 73.86,
        'available_from': '07:00',
        'available_to': '22:00',
        'max_capacity_kg': 25,
        'preferred_food_types': ['Cooked Meals'],
        'dietary_preferences': ['vegetarian'],
        'verified': false,
      },
    );

    expect(completion.isComplete, isTrue);
    expect(completion.percentage, 100);
  });

  test('backend report preserves profile completion fields only', () {
    final completion = ProfileCompletion.fromBackend({
      'role': 'ngo',
      'complete': true,
      'completed_fields': 11,
      'total_fields': 11,
      'percentage': 100,
      'missing_fields': <String>[],
      'verified': false,
    });

    expect(completion.completedFields, 11);
    expect(completion.totalFields, 11);
    expect(completion.isComplete, isTrue);
  });

  test('malformed backend report fails closed instead of implying complete',
      () {
    final completion = ProfileCompletion.fromBackend({
      'role': 'provider',
      'percentage': 100,
    });

    expect(completion.isComplete, isFalse);
    expect(
      completion.missingFields,
      ['Profile details could not be verified'],
    );
  });
}
