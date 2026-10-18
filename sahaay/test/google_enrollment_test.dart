import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sahaay/main.dart';

void main() {
  MaterialApp host(Widget home) =>
      MaterialApp(theme: ThemeData.light(), home: home);

  group('Google enrollment — email/password only in the default path', () {
    testWidgets(
        'provider form hides Email/password/confirm and shows the Google note '
        'when enrolling via Google', (WidgetTester tester) async {
      await tester.pumpWidget(
          host(const RegisterProviderScreen(googleEnrollment: true)));

      expect(find.text('Email'), findsNothing);
      expect(find.text('Password'), findsNothing);
      expect(find.text('Confirm Password'), findsNothing);
      expect(find.textContaining('Signed in with Google'), findsOneWidget);
      expect(find.text('CREATE PROVIDER ACCOUNT'), findsOneWidget);
    });

    group('Registration phone format validation', () {
      for (final scenario in [
        (
          role: 'provider',
          screen: const RegisterProviderScreen(),
          button: 'CREATE PROVIDER ACCOUNT',
        ),
        (
          role: 'ngo',
          screen: const RegisterNgoScreen(),
          button: 'CREATE NGO ACCOUNT',
        ),
        (
          role: 'volunteer',
          screen: const RegisterVolunteerScreen(),
          button: 'CREATE VOLUNTEER ACCOUNT',
        ),
      ]) {
        testWidgets(
            '${scenario.role} rejects an invalid number at registration',
            (WidgetTester tester) async {
          await tester.pumpWidget(host(scenario.screen));
          final phoneField = find.widgetWithText(TextFormField, 'Phone');
          await tester.ensureVisible(phoneField);
          await tester.enterText(phoneField, '5123456789');
          await tester.ensureVisible(find.text(scenario.button));
          await tester.tap(find.text(scenario.button));
          await tester.pumpAndSettle();

          expect(
            find.text('Enter a valid 10-digit Indian mobile number'),
            findsOneWidget,
          );
        });
      }
    });

    testWidgets(
        'provider form still shows Email/password/confirm for normal '
        'email/password registration', (WidgetTester tester) async {
      await tester.pumpWidget(host(const RegisterProviderScreen()));

      expect(find.text('Email'), findsOneWidget);
      expect(find.text('Password'), findsOneWidget);
      expect(find.text('Confirm Password'), findsOneWidget);
      expect(find.textContaining('Signed in with Google'), findsNothing);
    });

    testWidgets(
        'ngo form hides Email/password/confirm and shows the Google note '
        'when enrolling via Google', (WidgetTester tester) async {
      await tester
          .pumpWidget(host(const RegisterNgoScreen(googleEnrollment: true)));

      expect(find.text('Email'), findsNothing);
      expect(find.text('Password'), findsNothing);
      expect(find.text('Confirm Password'), findsNothing);
      expect(find.textContaining('Signed in with Google'), findsOneWidget);
    });

    testWidgets(
        'volunteer form hides Email/password/confirm and shows the Google note '
        'when enrolling via Google', (WidgetTester tester) async {
      await tester.pumpWidget(
          host(const RegisterVolunteerScreen(googleEnrollment: true)));

      expect(find.text('Email'), findsNothing);
      expect(find.text('Password'), findsNothing);
      expect(find.text('Confirm Password'), findsNothing);
      expect(find.textContaining('Signed in with Google'), findsOneWidget);
    });
  });

  group('Admin is never an enrollment role', () {
    test('no admin registration screen exists anywhere in the app', () {
      final source = File('lib/main.dart').readAsStringSync();
      expect(source, isNot(contains('RegisterAdminScreen')));
      expect(source, isNot(contains('RoleSelectionAdminCard')));
    });

    test('role selection builds only the three non-admin registration screens',
        () {
      final source = File('lib/main.dart').readAsStringSync();
      for (final screen in [
        'RegisterProviderScreen(',
        'RegisterNgoScreen(',
        'RegisterVolunteerScreen(',
      ]) {
        expect(source, contains(screen),
            reason: 'expected role selection to link the $screen form');
      }
    });
  });
}
