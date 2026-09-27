import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sahaay/main.dart';

Widget _app(Widget child) => MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

void main() {
  group('VehicleCompatibility model', () {
    test('parses every backend state', () {
      expect(VehicleCompatibility.fromBackend('both_transport'),
          VehicleCompatibility.bothTransport);
      expect(VehicleCompatibility.fromBackend('provider_transport'),
          VehicleCompatibility.providerTransport);
      expect(VehicleCompatibility.fromBackend('ngo_transport'),
          VehicleCompatibility.ngoTransport);
      expect(VehicleCompatibility.fromBackend('unknown'),
          VehicleCompatibility.unknown);
      expect(VehicleCompatibility.fromBackend('volunteer_required'),
          VehicleCompatibility.volunteerRequired);
    });

    test('an unrecognised or missing state is never read as usable transport',
        () {
      for (final raw in <dynamic>[null, '', 'both', 'YES', 7]) {
        final parsed = VehicleCompatibility.fromBackend(raw?.toString());
        expect(parsed, VehicleCompatibility.unknown);
        expect(parsed.needsVolunteer, isFalse);
      }
    });

    test('only volunteer_required needs a volunteer', () {
      expect(VehicleCompatibility.volunteerRequired.needsVolunteer, isTrue);
      for (final state in [
        VehicleCompatibility.bothTransport,
        VehicleCompatibility.providerTransport,
        VehicleCompatibility.ngoTransport,
        VehicleCompatibility.unknown,
      ]) {
        expect(state.needsVolunteer, isFalse, reason: '$state');
      }
    });

    test('a usable vehicle is only reported when the state is concrete', () {
      expect(VehicleCompatibility.bothTransport.hasUsableVehicle, isTrue);
      expect(VehicleCompatibility.providerTransport.hasUsableVehicle, isTrue);
      expect(VehicleCompatibility.ngoTransport.hasUsableVehicle, isTrue);
      // Unknown means we do not know, which is not the same as yes.
      expect(VehicleCompatibility.unknown.hasUsableVehicle, isFalse);
      expect(VehicleCompatibility.volunteerRequired.hasUsableVehicle, isFalse);
    });
  });

  group('LogisticsStatusBadge', () {
    testWidgets('shows the state the backend reported', (tester) async {
      await tester.pumpWidget(_app(const Column(children: [
        LogisticsStatusBadge(compatibility: VehicleCompatibility.bothTransport),
        LogisticsStatusBadge(
            compatibility: VehicleCompatibility.providerTransport),
        LogisticsStatusBadge(compatibility: VehicleCompatibility.ngoTransport),
        LogisticsStatusBadge(compatibility: VehicleCompatibility.unknown),
        LogisticsStatusBadge(
            compatibility: VehicleCompatibility.volunteerRequired),
      ])));
      await tester.pumpAndSettle();

      expect(find.text('Both have transport'), findsOneWidget);
      expect(find.text('Provider can transport'), findsOneWidget);
      expect(find.text('NGO can transport'), findsOneWidget);
      expect(find.text('Transport availability unknown'), findsOneWidget);
      expect(find.text('Volunteer transport required'), findsOneWidget);
    });

    testWidgets('the volunteer state is visually distinct from a usable one',
        (tester) async {
      // The label alone must tell the user a volunteer is needed, so the badge
      // has to carry the meaning without any surrounding explanation.
      await tester.pumpWidget(_app(const Column(children: [
        LogisticsStatusBadge(
          compatibility: VehicleCompatibility.volunteerRequired,
        ),
        LogisticsStatusBadge(
          compatibility: VehicleCompatibility.bothTransport,
        ),
      ])));
      await tester.pumpAndSettle();

      expect(find.text('Volunteer transport required'), findsOneWidget);
      expect(find.text('Both have transport'), findsOneWidget);
    });

    testWidgets('the unknown state is never phrased as having a vehicle',
        (tester) async {
      await tester.pumpWidget(_app(const Column(children: [
        LogisticsStatusBadge(compatibility: VehicleCompatibility.unknown),
      ])));
      await tester.pumpAndSettle();

      expect(find.text('Transport availability unknown'), findsOneWidget);
      // A badge must never claim transport exists when nobody has answered.
      expect(find.textContaining('have transport'), findsNothing);
    });

    testWidgets('compact mode still shows the state', (tester) async {
      await tester.pumpWidget(_app(const Column(children: [
        LogisticsStatusBadge(
          compatibility: VehicleCompatibility.volunteerRequired,
          compact: true,
        ),
      ])));
      await tester.pumpAndSettle();

      expect(find.text('Volunteer transport required'), findsOneWidget);
    });
  });

  group('VehicleCompatibility detail copy', () {
    test('the volunteer detail names both sides and the volunteer', () {
      final detail = VehicleCompatibility.volunteerRequired.detail;
      expect(detail, contains('Neither you nor this NGO has a vehicle'));
      expect(detail, contains('A volunteer is needed'));
    });

    test('the unknown detail says the data is missing, not that it is absent',
        () {
      final detail = VehicleCompatibility.unknown.detail;
      expect(detail, contains('missing on one side'));
      expect(detail, contains('cannot be confirmed'));
    });

    test('usable states explain who moves the food', () {
      expect(VehicleCompatibility.bothTransport.detail, contains('both'));
      expect(VehicleCompatibility.providerTransport.detail,
          contains('You have a vehicle'));
      expect(
          VehicleCompatibility.ngoTransport.detail, contains('This NGO has'));
    });
  });

  group('VolunteerTransportTask', () {
    Map<String, dynamic> realRow() => {
          'id': 'delivery-1',
          'status': 'unassigned',
          'volunteer_id': null,
          'pickup_address': 'Survey 44/2, Bandra West',
          'delivery_address': 'Andheri East Community Kitchen',
          'pickup_time': '2026-09-30T14:30:00Z',
          'notes': 'Ring the bell twice',
          'donation': {
            'food_name': 'Vegetable curry and rice',
            'quantity': 12.0,
            'unit': 'kg',
            'servings': 40,
            'veg_type': 'vegetarian',
          },
          'provider': {'organization_name': 'Sunrise Bakery'},
          'ngo': {'organization_name': 'Feed The City'},
        };

    test('reads the real joined facts, inventing nothing', () {
      final task = VolunteerTransportTask.fromBackend(realRow());

      expect(task.id, 'delivery-1');
      expect(task.pickupAddress, 'Survey 44/2, Bandra West');
      expect(task.deliveryAddress, 'Andheri East Community Kitchen');
      expect(task.foodName, 'Vegetable curry and rice');
      expect(task.providerName, 'Sunrise Bakery');
      expect(task.ngoName, 'Feed The City');
      expect(task.quantityKg, 12.0);
      expect(task.notes, 'Ring the bell twice');
      expect(task.pickupDeadline, isNotNull);
    });

    test('a row with no joins is shown as unknown, not filled in', () {
      final task = VolunteerTransportTask.fromBackend({
        'id': 'delivery-2',
        'pickup_address': 'Somewhere',
        'delivery_address': 'Elsewhere',
      });

      expect(task.foodName, isNull);
      expect(task.providerName, isNull);
      expect(task.ngoName, isNull);
      expect(task.quantityKg, isNull);
      expect(task.pickupDeadline, isNull);
      expect(task.quantityLabel, isNull);
    });

    test('quantity uses kg, servings, or nothing depending on the row', () {
      expect(
        VolunteerTransportTask.fromBackend({
          'id': 'd',
          'pickup_address': 'a',
          'delivery_address': 'b',
          'donation': {'quantity': 12.0, 'unit': 'kg'},
        }).quantityLabel,
        '12 kg',
      );
      expect(
        VolunteerTransportTask.fromBackend({
          'id': 'd',
          'pickup_address': 'a',
          'delivery_address': 'b',
          'donation': {'servings': 40},
        }).quantityLabel,
        '40 servings',
      );
      expect(
        VolunteerTransportTask.fromBackend({
          'id': 'd',
          'pickup_address': 'a',
          'delivery_address': 'b',
        }).quantityLabel,
        isNull,
      );
    });
  });
}
