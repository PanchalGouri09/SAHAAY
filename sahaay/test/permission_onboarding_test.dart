import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:sahaay/main.dart';
import 'package:sahaay/services/permission_service.dart';

/// Records what was asked and returns scripted answers — no real platform
/// channel is ever touched.
class _FakeGateway implements PermissionGateway {
  int statusCalls = 0;
  int requestCalls = 0;
  final List<AppPermission> requested = [];
  int appSettingsOpens = 0;
  PermissionOutcome statusOutcome = PermissionOutcome.notRequested;
  PermissionOutcome requestOutcome = PermissionOutcome.granted;

  @override
  Future<PermissionOutcome> status(AppPermission permission) async {
    statusCalls++;
    return statusOutcome;
  }

  @override
  Future<PermissionOutcome> request(AppPermission permission) async {
    requestCalls++;
    requested.add(permission);
    return requestOutcome;
  }

  @override
  Future<bool> isLocationServiceEnabled() async => true;

  @override
  Future<bool> openLocationSettings() async => true;

  @override
  Future<bool> openAppSettings() async {
    appSettingsOpens++;
    return true;
  }
}

const _destinationLabel = 'onboarding-finished';

void main() {
  late _FakeGateway gateway;
  late PermissionService service;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    gateway = _FakeGateway();
    service = PermissionService(gateway);
  });

  Widget host(PermissionOnboardingScreen screen) =>
      MaterialApp(home: screen);

  PermissionOnboardingScreen screen({bool reviewMode = false}) =>
      PermissionOnboardingScreen(
        permissions: service,
        reviewMode: reviewMode,
        finishDestination: () => const Text(_destinationLabel),
      );

  group('Explanation before any prompt', () {
    testWidgets('shows every permission with its reason and both buttons',
        (tester) async {
      await tester.pumpWidget(host(screen()));
      await tester.pumpAndSettle();

      // Appears twice by design: the app-bar title and the intro heading.
      expect(find.text('Allow SAHAAY permissions'), findsNWidgets(2));
      expect(find.text('Camera'), findsOneWidget);
      expect(
          find.textContaining('Take food and handover photos'), findsOneWidget);
      expect(find.text('Photos'), findsOneWidget);
      expect(find.textContaining('system photo picker'), findsOneWidget);
      expect(find.text('Location'), findsOneWidget);
      expect(find.text('Notifications'), findsOneWidget);
      expect(find.textContaining('claim, pickup, delivery and status updates'),
          findsOneWidget);
      expect(find.text('Allow Permissions'), findsOneWidget);
      expect(find.text('Not Now'), findsOneWidget);
    });

    testWidgets('opening the screen never triggers an OS prompt',
        (tester) async {
      await tester.pumpWidget(host(screen()));
      await tester.pumpAndSettle();

      // Statuses may be READ (never a prompt), and only for the three real
      // runtime permissions — Photos deliberately has none.
      expect(gateway.requestCalls, 0);
      expect(gateway.statusCalls, 3);
    });
  });

  group('Allow Permissions', () {
    testWidgets('requests exactly camera, location and notifications in order',
        (tester) async {
      await tester.pumpWidget(host(screen()));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Allow Permissions'));
      await tester.pumpAndSettle();

      expect(gateway.requestCalls, 3);
      expect(gateway.requested, const [
        AppPermission.camera,
        AppPermission.location,
        AppPermission.notifications,
      ]);
      // Granted outcomes are surfaced truthfully.
      expect(find.text('Allowed'), findsNWidgets(3));
      // After the request the user can finish (registration already succeeded).
      expect(find.text('Continue'), findsOneWidget);
    });

    testWidgets('a denied permission is shown honestly, not faked as granted',
        (tester) async {
      gateway.requestOutcome = PermissionOutcome.denied;
      await tester.pumpWidget(host(screen()));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Allow Permissions'));
      await tester.pumpAndSettle();

      expect(find.text('Not allowed'), findsNWidgets(3));
      expect(find.text('Allowed'), findsNothing);
      expect(find.text('Continue'), findsOneWidget);
    });

    testWidgets('a blocked permission offers a route to Settings instead of '
        're-asking', (tester) async {
      gateway.requestOutcome = PermissionOutcome.permanentlyDenied;
      await tester.pumpWidget(host(screen()));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Allow Permissions'));
      await tester.pumpAndSettle();

      expect(find.text('Blocked in Settings'), findsNWidgets(3));
      await tester.tap(find.text('Settings').first);
      await tester.pumpAndSettle();
      expect(gateway.appSettingsOpens, 1);
      // The blocked state was never re-requested behind the user's back.
      expect(gateway.requestCalls, 3);
    });
  });

  group('Not Now', () {
    testWidgets('finishes onboarding without requesting anything',
        (tester) async {
      await tester.pumpWidget(host(screen()));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Not Now'));
      await tester.pumpAndSettle();

      expect(gateway.requestCalls, 0);
      // Completion is persisted, so the screen can never appear again.
      final prefs = await SharedPreferences.getInstance();
      expect(
          prefs.getBool(PermissionOnboardingScreen.prefsKey), isTrue);
      // Registration still lands on the dashboard destination.
      expect(find.text(_destinationLabel), findsOneWidget);
    });
  });

  group('Shown exactly once', () {
    testWidgets('an already-completed onboarding finishes immediately',
        (tester) async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(PermissionOnboardingScreen.prefsKey, true);

      await tester.pumpWidget(host(screen()));
      await tester.pumpAndSettle();

      expect(find.text(_destinationLabel), findsOneWidget);
      expect(find.text('Allow SAHAAY permissions'), findsNothing);
      expect(gateway.requestCalls, 0);
    });
  });

  group('Settings review route', () {
    testWidgets('review mode re-requests but has no Not Now and pops back',
        (tester) async {
      await tester.pumpWidget(
          MaterialApp(home: screen(reviewMode: true)));
      await tester.pumpAndSettle();

      expect(find.text('Permissions'), findsOneWidget);
      expect(find.text('Not Now'), findsNothing);
      expect(gateway.requestCalls, 0);

      await tester.tap(find.text('Allow Permissions'));
      await tester.pumpAndSettle();
      expect(gateway.requestCalls, 3);

      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      // Popped back — review mode never routes to the dashboard.
      expect(find.text(_destinationLabel), findsNothing);
    });
  });
}
