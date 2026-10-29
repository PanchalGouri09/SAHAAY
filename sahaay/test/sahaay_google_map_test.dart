import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' show GoogleMap;

import 'package:sahaay/main.dart';
import 'package:sahaay/services/phone_contact.dart';
import 'package:sahaay/widgets/sahaay_google_map.dart';

/// Focused, network-free tests for the SAHAAY Google Maps integration:
/// model coordinate parsing, point/fallback resolution, and the honest
/// "location unavailable" state. No Google Map is ever pumped, so no live
/// Maps SDK or API connection is needed.
void main() {
  group('Donation.fromBackend coordinates', () {
    Map<String, dynamic> baseRow() => {
          'id': 'd1',
          'food_name': 'Veg Biryani',
          'food_category': 'Meals',
          'quantity': 5,
          'servings': 20,
          'status': 'available',
          'provider': {
            'organization_name': 'Spice Kitchen',
            'address': 'FC Road'
          },
        };

    test('parses real numeric coordinates', () {
      final donation = Donation.fromBackend(
          {...baseRow(), 'latitude': 18.52, 'longitude': 73.85});
      expect(donation.latitude, 18.52);
      expect(donation.longitude, 73.85);
    });

    test('parses string coordinates defensively', () {
      final donation = Donation.fromBackend(
          {...baseRow(), 'latitude': '18.52', 'longitude': '73.85'});
      expect(donation.latitude, 18.52);
      expect(donation.longitude, 73.85);
    });

    test('keeps coordinates null when they are absent', () {
      final donation = Donation.fromBackend(baseRow());
      expect(donation.latitude, isNull);
      expect(donation.longitude, isNull);
    });

    test('keeps coordinates null when they are null or garbage', () {
      final donation = Donation.fromBackend(
          {...baseRow(), 'latitude': null, 'longitude': 'not-a-number'});
      expect(donation.latitude, isNull);
      expect(donation.longitude, isNull);
    });
  });

  group('DeliveryOpportunity.fromBackend coordinates', () {
    test('stays null for today\'s delivery rows (no coordinate columns)', () {
      final opportunity = DeliveryOpportunity.fromBackend({
        'id': 'del1',
        'pickup_address': 'MG Road',
        'delivery_address': 'Pune Camp',
        'pickup_time': '2026-10-06T10:00:00Z',
        'status': 'assigned',
      });
      expect(opportunity.latitude, isNull);
      expect(opportunity.longitude, isNull);
    });

    test('parses coordinates when the backend ever supplies them', () {
      final opportunity = DeliveryOpportunity.fromBackend(
          {'id': 'del1', 'latitude': 18.52, 'longitude': 73.85});
      expect(opportunity.latitude, 18.52);
      expect(opportunity.longitude, 73.85);
    });
  });

  group('SahaayMapPoint', () {
    test('accepts in-range WGS-84 coordinates', () {
      const point = SahaayMapPoint(latitude: 18.52, longitude: 73.85);
      expect(point.isUsable, isTrue);
    });

    test('rejects out-of-range coordinates', () {
      expect(const SahaayMapPoint(latitude: 999, longitude: 73.85).isUsable,
          isFalse);
      expect(const SahaayMapPoint(latitude: 18.52, longitude: 181).isUsable,
          isFalse);
      expect(const SahaayMapPoint(latitude: 0, longitude: 0).isUsable, isFalse);
      expect(
          const SahaayMapPoint(latitude: 0, longitude: 73.85).isUsable, isTrue);
    });
  });

  group('Google Maps and dialer actions', () {
    test('prefers the saved coordinate pair for the map query', () {
      final uri = googleMapsUriForLocation(
        latitude: 18.5204,
        longitude: 73.8567,
        address: 'FC Road, Pune',
      );

      expect(uri, isNotNull);
      expect(uri!.queryParameters['query'], '18.5204,73.8567');
      expect(uri.queryParameters['api'], '1');
    });

    test('falls back to the saved address if coordinates are incomplete', () {
      final uri = googleMapsUriForLocation(
        latitude: 18.5204,
        address: 'FC Road, Pune',
      );

      expect(uri, isNotNull);
      expect(uri!.queryParameters['query'], 'FC Road, Pune');
    });

    test('rejects invalid coordinates and an absent address', () {
      expect(
        googleMapsUriForLocation(latitude: 95, longitude: 73.85),
        isNull,
      );
      expect(googleMapsUriForLocation(), isNull);
    });

    test('formats an Indian contact as a dialer URI without placing a call',
        () {
      final uri = dialerUriForPhone('+91 98765 43210');

      expect(uri, isNotNull);
      expect(uri!.scheme, 'tel');
      expect(uri.path, '+919876543210');
    });
  });

  group('SahaayGoogleMap', () {
    test('constructs with valid coordinates and resolves one marker point', () {
      const map = SahaayGoogleMap(
          latitude: 18.52, longitude: 73.85, markerTitle: 'Pickup');
      expect(map.resolvedPoints, hasLength(1));
      expect(map.resolvedPoints.single.latitude, 18.52);
      expect(map.resolvedPoints.single.longitude, 73.85);
    });

    test('resolves multiple marker points for multi-donation maps', () {
      const map = SahaayGoogleMap(
        points: [
          SahaayMapPoint(latitude: 18.52, longitude: 73.85, title: 'A'),
          SahaayMapPoint(latitude: 19.0, longitude: 72.8, title: 'B'),
        ],
      );
      expect(map.resolvedPoints, hasLength(2));
    });

    test('drops invalid points instead of crashing', () {
      const map = SahaayGoogleMap(
        points: [
          SahaayMapPoint(latitude: 18.52, longitude: 73.85),
          SahaayMapPoint(latitude: 500, longitude: 73.85),
        ],
      );
      expect(map.resolvedPoints, hasLength(1));
    });

    testWidgets('missing coordinates show the honest unavailable state',
        (WidgetTester tester) async {
      await tester.pumpWidget(
          const MaterialApp(home: Scaffold(body: SahaayGoogleMap())));
      expect(find.textContaining('Location unavailable'), findsOneWidget);
      expect(find.byIcon(Icons.location_off_outlined), findsOneWidget);
      expect(find.byType(GoogleMap), findsNothing);
    });

    testWidgets('only-invalid points also fall back to unavailable',
        (WidgetTester tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: SahaayGoogleMap(
            points: [SahaayMapPoint(latitude: 95, longitude: 73.85)],
          ),
        ),
      ));
      expect(find.textContaining('Location unavailable'), findsOneWidget);
    });

    testWidgets('unavailable placeholder fits narrow screens and larger text',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(280, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        const MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(1.5)),
            child: Scaffold(body: SahaayGoogleMap(height: 160)),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('Location unavailable'), findsOneWidget);
      expect(
        tester.getRect(find.byType(SahaayGoogleMap)).right,
        lessThanOrEqualTo(280),
      );
    });

    testWidgets('map remains inside explicit bounded card constraints',
        (WidgetTester tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 320,
              height: 220,
              child: SahaayGoogleMap(
                latitude: 18.52,
                longitude: 73.85,
              ),
            ),
          ),
        ),
      ));
      await tester.pump();

      expect(
          tester.getSize(find.byType(SahaayGoogleMap)), const Size(320, 220));
      expect(tester.getSize(find.byType(GoogleMap)), const Size(318, 218));
      expect(
        find.ancestor(
          of: find.byType(GoogleMap),
          matching: find.byType(ClipRRect),
        ),
        findsOneWidget,
      );
      expect(find.text('Loading map…'), findsOneWidget);
      expect(find.byTooltip('Reload map'), findsOneWidget);
    });

    testWidgets(
        'map waits for the initial camera to settle before removing loader',
        (WidgetTester tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 320,
            height: 220,
            child: SahaayGoogleMap(
              latitude: 18.52,
              longitude: 73.85,
            ),
          ),
        ),
      ));
      await tester.pump();

      expect(find.text('Loading map…'), findsOneWidget);
      final map = tester.widget<GoogleMap>(find.byType(GoogleMap));
      expect(map.onCameraIdle, isNotNull);
      map.onCameraIdle!();
      await tester.pump();

      expect(find.text('Loading map…'), findsNothing);
    });

    testWidgets('map timeout exposes an error and retry action',
        (WidgetTester tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 320,
            height: 220,
            child: SahaayGoogleMap(
              latitude: 18.52,
              longitude: 73.85,
            ),
          ),
        ),
      ));
      await tester.pump();
      await tester.pump(const Duration(seconds: 20));

      expect(find.textContaining('Google Maps unavailable'), findsOneWidget);
      expect(find.text('Retry map'), findsOneWidget);

      final initialMap = tester.widget<GoogleMap>(find.byType(GoogleMap));
      await tester.tap(find.text('Retry map'));
      await tester.pump();
      final retriedMap = tester.widget<GoogleMap>(find.byType(GoogleMap));
      expect(initialMap.key, const ValueKey(0));
      expect(retriedMap.key, const ValueKey(1));
    });

    testWidgets('renders distinct pickup and destination marker coordinates',
        (WidgetTester tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 320,
            height: 220,
            child: SahaayGoogleMap(
              points: [
                SahaayMapPoint(
                    latitude: 18.52, longitude: 73.85, title: 'Pickup'),
                SahaayMapPoint(
                    latitude: 18.53, longitude: 73.86, title: 'Drop-off'),
              ],
            ),
          ),
        ),
      ));

      final markers = tester.widget<GoogleMap>(find.byType(GoogleMap)).markers;
      expect(markers, hasLength(2));
      expect(
        markers
            .map((marker) =>
                (marker.position.latitude, marker.position.longitude))
            .toSet(),
        {
          (18.52, 73.85),
          (18.53, 73.86),
        },
      );
      expect(markers.map((marker) => marker.infoWindow.title).toSet(),
          {'Pickup', 'Drop-off'});
    });
  });

  group('NGO home map points', () {
    Donation withCoords(Map<String, dynamic> extra) => Donation.fromBackend({
          'id': extra['id'] ?? 'd',
          'food_name': 'Veg Biryani',
          'food_category': 'Meals',
          'quantity': 5,
          'servings': 20,
          'status': 'available',
          ...extra,
        });

    test('passes backend pickup coordinates through to the NGO map marker', () {
      final donation = Donation.fromBackend({
        'id': 'saved-donation',
        'food_name': 'Saved donation',
        'food_category': 'Meals',
        'quantity': 5,
        'servings': 20,
        'status': 'available',
        'latitude': 18.5204,
        'longitude': 73.8567,
      });

      final points = ngoHomeMapPoints([donation]);

      expect(points, hasLength(1));
      expect(points.single.latitude, 18.5204);
      expect(points.single.longitude, 73.8567);
    });

    test('includes only donations that actually have coordinates', () {
      final available = [
        withCoords({'id': 'a', 'latitude': 18.52, 'longitude': 73.85}),
        withCoords({'id': 'b'}), // no coordinates — must be skipped
      ];
      final points = ngoHomeMapPoints(available);
      expect(points, hasLength(1));
      expect(points.single.title, 'Veg Biryani');
    });

    test('map pins retain coordinates but hide coordinate pairs as addresses',
        () {
      final donation = withCoords({
        'id': 'legacy',
        'latitude': 18.52,
        'longitude': 73.85,
        'pickup_address': '18.52000, 73.85000',
      });

      final point = ngoHomeMapPoints([donation]).single;

      expect(point.latitude, 18.52);
      expect(point.longitude, 73.85);
      expect(point.snippet, 'Address unavailable');
    });

    test('prepends the NGO destination pin before food markers', () {
      const ngoPoint = SahaayMapPoint(
          latitude: 18.51,
          longitude: 73.84,
          title: 'Helping Hands',
          snippet: 'Your NGO');
      final points = ngoHomeMapPoints(
        [
          withCoords({'id': 'a', 'latitude': 18.52, 'longitude': 73.85})
        ],
        ngoPoint: ngoPoint,
      );
      expect(points, hasLength(2));
      expect(points.first, same(ngoPoint));
    });
  });

  group('ngoMapPointFromProfile', () {
    test('reads coordinates and name from the list-shaped profile join', () {
      final point = ngoMapPointFromProfile({
        'profile': [
          {
            'organization_name': 'Helping Hands',
            'latitude': 18.51,
            'longitude': 73.84
          },
        ],
      });
      expect(point, isNotNull);
      expect(point!.title, 'Helping Hands');
      expect(point.latitude, 18.51);
      expect(point.longitude, 73.84);
    });

    test('returns null when the profile has no coordinates', () {
      expect(
          ngoMapPointFromProfile({
            'profile': [
              {'organization_name': 'X'}
            ]
          }),
          isNull);
      expect(ngoMapPointFromProfile({}), isNull);
    });
  });
}
