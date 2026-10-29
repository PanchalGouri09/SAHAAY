import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sahaay/main.dart';

void main() {
  test('web APK download page links directly to the release asset', () {
    const downloadUrl =
        'https://github.com/PanchalGouri09/SAHAAY/releases/latest/download/SAHAAY.apk';
    final page = File('web/download.html').readAsStringSync();

    expect(page, contains('href="$downloadUrl"'));
    expect(page, contains('src="assets/sahaay-download-qr.png"'));
    expect(page, contains('Android APK · Version 0.1.0'));
    expect(page, contains('Scan to download SAHAAY for Android'));
  });

  for (final (name, theme) in [
    ('light', sahaayLightTheme),
    ('dark', sahaayDarkTheme),
  ]) {
    testWidgets('$name theme keeps premium surfaces and actions responsive',
        (tester) async {
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: Scaffold(
            appBar: AppBar(title: const Text('SAHAAY')),
            body: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  const Card(
                    key: ValueKey('premium-card'),
                    child: ListTile(
                      title: Text('Donation details'),
                      subtitle: Text('Saved information'),
                    ),
                  ),
                  const SizedBox(height: 12),
                  FilledButton(
                    key: const ValueKey('premium-primary-action'),
                    onPressed: () {},
                    child: const Text('Continue to review your donation'),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton(
                    onPressed: () {},
                    child: const Text('View Matched NGOs'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(theme.cardTheme.elevation, greaterThan(1));
      final colors = theme.brightness == Brightness.dark
          ? AppColors.dark
          : AppColors.light;
      expect(theme.cardTheme.color, colors.surface);
      expect(
        colors.surface,
        theme.brightness == Brightness.light
            ? Colors.white
            : const Color(0xFF1E222A),
      );
      expect(colors.surfaceAlt, isNot(colors.bluePrimary));
      expect(
        (colors.surface.blue - colors.surface.red).abs(),
        lessThan(50),
      );
      expect(theme.cardTheme.shadowColor, isNotNull);
      expect(theme.cardTheme.surfaceTintColor, Colors.transparent);
      expect(theme.inputDecorationTheme.fillColor, colors.surfaceAlt);
      expect(theme.navigationBarTheme.backgroundColor, colors.surface);
      expect(theme.textTheme.titleLarge?.fontWeight, FontWeight.w700);
      expect(theme.textTheme.titleMedium?.fontWeight, FontWeight.w700);
      expect(theme.textTheme.bodyMedium?.fontWeight, FontWeight.w400);
      expect(theme.navigationBarTheme.indicatorColor, isNotNull);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('premium-primary-action')),
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is AnimatedContainer &&
                widget.decoration is BoxDecoration &&
                (widget.decoration as BoxDecoration).gradient != null,
          ),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('disabled primary action keeps its readable tonal surface',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: sahaayLightTheme,
        home: const Scaffold(
          body: Center(
            child: FilledButton(
              onPressed: null,
              child: Text('Unavailable'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final disabledBackground = tester.widgetList<AnimatedContainer>(
      find.descendant(
        of: find.byType(FilledButton),
        matching: find.byType(AnimatedContainer),
      ),
    );
    expect(
      disabledBackground.any(
        (widget) =>
            widget.decoration is BoxDecoration &&
            (widget.decoration as BoxDecoration).color ==
                AppColors.light.surfaceAlt,
      ),
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });
}
