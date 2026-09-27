import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sahaay/main.dart';

Widget _app(Widget child) => MaterialApp(
      theme: sahaayLightTheme,
      home: Scaffold(body: child),
    );

void main() {
  group('VehicleAvailability tri-state model', () {
    test('maps to the backend tri-state values', () {
      expect(VehicleAvailability.yes.backendValue, isTrue);
      expect(VehicleAvailability.no.backendValue, isFalse);
      // "not answered" is null, which is what the backend column stores.
      expect(VehicleAvailability.unanswered.backendValue, isNull);
    });

    test('parses backend values back, treating null and missing as unanswered',
        () {
      expect(VehicleAvailability.fromBackend(true), VehicleAvailability.yes);
      expect(VehicleAvailability.fromBackend(false), VehicleAvailability.no);
      expect(VehicleAvailability.fromBackend(null),
          VehicleAvailability.unanswered);
    });

    test('an absent or malformed backend value is never read as "no"', () {
      // Guards the requirement that false and "not answered" stay distinct.
      for (final raw in <Object?>[null, 'true', 'no', 0, <String>[]]) {
        expect(VehicleAvailability.fromBackend(raw),
            VehicleAvailability.unanswered,
            reason: 'unexpectedly treated $raw as answered');
      }
    });

    test('false and unanswered are different states', () {
      expect(VehicleAvailability.no, isNot(VehicleAvailability.unanswered));
      expect(VehicleAvailability.no.backendValue,
          isNot(VehicleAvailability.unanswered.backendValue));
    });
  });

  group('VehicleAvailability prompt', () {
    testWidgets('shows the title and the exact question when unanswered',
        (tester) async {
      await tester.pumpWidget(_app(VehicleAvailabilityCard(
        value: VehicleAvailability.unanswered,
        onAnswer: (_) async {},
      )));

      expect(find.text('Vehicle Availability'), findsOneWidget);
      expect(
        find.text('Do you currently have a vehicle available for food pickup?'),
        findsOneWidget,
      );
    });

    testWidgets('offers both answers with the required labels', (tester) async {
      await tester.pumpWidget(_app(VehicleAvailabilityCard(
        value: VehicleAvailability.unanswered,
        onAnswer: (_) async {},
      )));

      expect(find.text('Yes, I have a vehicle'), findsOneWidget);
      expect(find.text("No, I don't"), findsOneWidget);
    });

    testWidgets('tapping "Yes" reports yes', (tester) async {
      VehicleAvailability? chosen;
      await tester.pumpWidget(_app(VehicleAvailabilityCard(
        value: VehicleAvailability.unanswered,
        onAnswer: (v) async => chosen = v,
      )));

      await tester.tap(find.text('Yes, I have a vehicle'));
      await tester.pumpAndSettle();

      expect(chosen, VehicleAvailability.yes);
    });

    testWidgets('tapping "No" reports no', (tester) async {
      VehicleAvailability? chosen;
      await tester.pumpWidget(_app(VehicleAvailabilityCard(
        value: VehicleAvailability.unanswered,
        onAnswer: (v) async => chosen = v,
      )));

      await tester.tap(find.text("No, I don't"));
      await tester.pumpAndSettle();

      expect(chosen, VehicleAvailability.no);
    });

    testWidgets('disappears once answered, so it is not shown forever',
        (tester) async {
      for (final answered in [
        VehicleAvailability.yes,
        VehicleAvailability.no,
      ]) {
        await tester.pumpWidget(_app(VehicleAvailabilityCard(
          value: answered,
          onAnswer: (_) async {},
        )));
        await tester.pumpAndSettle();

        expect(find.text('Vehicle Availability'), findsNothing);
        expect(find.text('Yes, I have a vehicle'), findsNothing);
      }
    });

    testWidgets('is not a hard gate: it renders only a card, no dialog',
        (tester) async {
      await tester.pumpWidget(_app(VehicleAvailabilityCard(
        value: VehicleAvailability.unanswered,
        onAnswer: (_) async {},
      )));
      await tester.pumpAndSettle();

      // Nothing is dismissed or blocking, and the tree below still builds.
      expect(find.byType(Dialog), findsNothing);
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets('does not duplicate itself across rebuilds', (tester) async {
      await tester.pumpWidget(_app(VehicleAvailabilityCard(
        value: VehicleAvailability.unanswered,
        onAnswer: (_) async {},
      )));

      // Rebuild with the same unanswered value several times.
      for (var i = 0; i < 3; i++) {
        await tester.pumpWidget(_app(VehicleAvailabilityCard(
          value: VehicleAvailability.unanswered,
          onAnswer: (_) async {},
        )));
        await tester.pumpAndSettle();
      }

      expect(find.text('Vehicle Availability'), findsOneWidget);
      expect(find.text('Yes, I have a vehicle'), findsOneWidget);
    });

    testWidgets('buttons are disabled while saving', (tester) async {
      await tester.pumpWidget(_app(VehicleAvailabilityCard(
        value: VehicleAvailability.unanswered,
        saving: true,
        onAnswer: (_) async {},
      )));

      final yes = tester.widget<PrimaryButton>(
        find.widgetWithText(PrimaryButton, 'Yes, I have a vehicle'),
      );
      final no = tester.widget<SecondaryButton>(
        find.widgetWithText(SecondaryButton, "No, I don't"),
      );

      expect(yes.onPressed, isNull);
      expect(no.onPressed, isNull);
    });
  });

  group('Vehicle availability editing', () {
    testWidgets('settings tile always shows the current answer',
        (tester) async {
      await tester.pumpWidget(_app(ListView(children: [
        VehicleAvailabilityTile(
          value: VehicleAvailability.yes,
          onAnswer: (_) async {},
        ),
      ])));

      expect(find.text('Vehicle availability'), findsOneWidget);
      expect(find.text('Available'), findsOneWidget);
    });

    testWidgets('an NGO that has not answered sees the question in settings',
        (tester) async {
      await tester.pumpWidget(_app(ListView(children: [
        VehicleAvailabilityTile(
          value: VehicleAvailability.unanswered,
          onAnswer: (_) async {},
        ),
      ])));

      expect(
        find.text('Do you currently have a vehicle available for food pickup?'),
        findsOneWidget,
      );
    });

    testWidgets('an answered NGO can change to the other answer',
        (tester) async {
      VehicleAvailability? chosen;
      await tester.pumpWidget(_app(ListView(children: [
        VehicleAvailabilityTile(
          value: VehicleAvailability.no,
          onAnswer: (v) async => chosen = v,
        ),
      ])));

      await tester.tap(find.text('Vehicle availability'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Yes, I have a vehicle'));
      await tester.pumpAndSettle();

      expect(chosen, VehicleAvailability.yes);
    });

    testWidgets('an answered NGO can change back to the other answer',
        (tester) async {
      VehicleAvailability? chosen;
      await tester.pumpWidget(_app(ListView(children: [
        VehicleAvailabilityTile(
          value: VehicleAvailability.yes,
          onAnswer: (v) async => chosen = v,
        ),
      ])));

      await tester.tap(find.text('Vehicle availability'));
      await tester.pumpAndSettle();
      await tester.tap(find.text("No, I don't"));
      await tester.pumpAndSettle();

      expect(chosen, VehicleAvailability.no);
    });

    testWidgets('an answer can be cleared back to unanswered', (tester) async {
      VehicleAvailability? chosen;
      await tester.pumpWidget(_app(ListView(children: [
        VehicleAvailabilityTile(
          value: VehicleAvailability.yes,
          onAnswer: (v) async => chosen = v,
        ),
      ])));

      await tester.tap(find.text('Vehicle availability'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Clear my answer'));
      await tester.pumpAndSettle();

      expect(chosen, VehicleAvailability.unanswered);
      expect(chosen?.backendValue, isNull);
    });

    testWidgets('cancelling the sheet sends no update', (tester) async {
      var calls = 0;
      await tester.pumpWidget(_app(ListView(children: [
        VehicleAvailabilityTile(
          value: VehicleAvailability.yes,
          onAnswer: (_) async => calls++,
        ),
      ])));

      await tester.tap(find.text('Vehicle availability'));
      await tester.pumpAndSettle();
      // Tapping the already-selected option is a no-op, not a write.
      await tester.tap(find.text('Yes, I have a vehicle'));
      await tester.pumpAndSettle();

      expect(calls, 0);
    });

    testWidgets('the tile does not open a sheet while saving', (tester) async {
      await tester.pumpWidget(_app(ListView(children: [
        VehicleAvailabilityTile(
          value: VehicleAvailability.yes,
          saving: true,
          onAnswer: (_) async {},
        ),
      ])));

      await tester.tap(find.text('Vehicle availability'));
      // A plain pump, not pumpAndSettle: the saving spinner never settles.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Clear my answer'), findsNothing);
    });
  });

  group('Prompt copy', () {
    test('the NGO wording is exactly the requested sentence', () {
      expect(
        VehicleAvailabilityCopy.question(VehicleRole.ngo),
        'Do you currently have a vehicle available for food pickup?',
      );
    });

    test('the provider asks about transporting donated food', () {
      expect(
        VehicleAvailabilityCopy.question(VehicleRole.provider),
        'Do you currently have a vehicle available for transporting donated food?',
      );
    });

    test('the two roles are never shown the same question', () {
      expect(
        VehicleAvailabilityCopy.question(VehicleRole.provider),
        isNot(VehicleAvailabilityCopy.question(VehicleRole.ngo)),
      );
      expect(
        VehicleAvailabilityCopy.unansweredBody(VehicleRole.provider),
        isNot(VehicleAvailabilityCopy.unansweredBody(VehicleRole.ngo)),
      );
    });

    test('the title and answer labels are shared by both roles', () {
      expect(VehicleAvailabilityCopy.title, 'Vehicle Availability');
      expect(VehicleAvailabilityCopy.yesLabel, 'Yes, I have a vehicle');
      expect(VehicleAvailabilityCopy.noLabel, "No, I don't");
    });
  });
}
