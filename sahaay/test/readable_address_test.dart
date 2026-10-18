import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sahaay/services/geo_service.dart';
import 'package:sahaay/widgets/readable_address_text.dart';

void main() {
  tearDown(() => reverseGeocoderOverride = null);

  testWidgets('resolves coordinate-only locations through reverse geocoding',
      (tester) async {
    reverseGeocoderOverride = (latitude, longitude) async {
      expect(latitude, 18.52);
      expect(longitude, 73.85);
      return (address: '12 Main Road, Pune', city: 'Pune');
    };

    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: ReadableAddressText(
          address: '18.52, 73.85',
          latitude: 18.52,
          longitude: 73.85,
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('12 Main Road, Pune'), findsOneWidget);
  });

  testWidgets('shows Address unavailable when reverse geocoding has no result',
      (tester) async {
    reverseGeocoderOverride = (latitude, longitude) async => null;

    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: ReadableAddressText(
          address: null,
          latitude: 18.52,
          longitude: 73.85,
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Address unavailable'), findsOneWidget);
  });

  testWidgets('prefers an existing address without reverse geocoding',
      (tester) async {
    var called = false;
    reverseGeocoderOverride = (latitude, longitude) async {
      called = true;
      return (address: 'Resolved elsewhere', city: null);
    };

    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: ReadableAddressText(
          address: 'Existing address',
          latitude: 18.52,
          longitude: 73.85,
        ),
      ),
    ));

    expect(find.text('Existing address'), findsOneWidget);
    expect(called, isFalse);
  });
}
