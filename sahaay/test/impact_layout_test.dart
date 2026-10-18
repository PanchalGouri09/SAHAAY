import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sahaay/main.dart';

/// Regression tests for the Impact & Rewards layout bugs reported from the
/// device: the two-column stat grid overflowed by a fixed `childAspectRatio`,
/// and the "My Claims" empty state sat off-centre. Both are now content-sized
/// / explicitly centred, so these tests lock that in across small screens and
/// enlarged font scales.
void main() {
  const cards = [
    ImpactCard(emoji: '🌱', value: '120 kg', label: 'Food Saved'),
    ImpactCard(emoji: '🍱', value: '480', label: 'Meals Supported'),
    ImpactCard(emoji: '💙', value: '37', label: 'Donations Completed'),
    ImpactCard(emoji: '⭐', value: '—', label: 'NGO Rating'),
  ];

  Future<void> pumpGrid(
    WidgetTester tester, {
    required double width,
    required double textScale,
  }) async {
    tester.view.physicalSize = Size(width, 720);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => MediaQuery(
            data:
                MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
            child: const Scaffold(
              body: SingleChildScrollView(
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: ImpactCardGrid(cards: cards),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('ImpactCardGrid never overflows on narrow screens',
      (tester) async {
    for (final scenario in const [
      (width: 360.0, scale: 1.0),
      (width: 320.0, scale: 1.3),
      (width: 300.0, scale: 1.5),
    ]) {
      await pumpGrid(tester, width: scenario.width, textScale: scenario.scale);
      expect(
        tester.takeException(),
        isNull,
        reason: 'Overflow at width ${scenario.width} scale ${scenario.scale}',
      );
      // All four cards still render exactly once.
      expect(find.byType(ImpactCard), findsNWidgets(4));
    }
  });

  testWidgets('ImpactCardGrid lays the two columns out side by side',
      (tester) async {
    await pumpGrid(tester, width: 360, textScale: 1.0);
    final first = tester.getTopLeft(find.byType(ImpactCard).first);
    final second = tester.getTopLeft(find.byType(ImpactCard).at(1));
    expect(second.dy, first.dy, reason: 'First row should share a baseline');
    expect(second.dx, greaterThan(first.dx),
        reason: 'Second card should be to the right of the first');
  });

  testWidgets('EmptyState is horizontally centred when wrapped in Center',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: EmptyState(
              icon: Icons.assignment_outlined,
              message: 'No active claims yet.',
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final iconCenter = tester.getCenter(find.byIcon(Icons.assignment_outlined));
    final screenCenter = tester.getCenter(find.byType(Scaffold));
    expect((iconCenter.dx - screenCenter.dx).abs(), lessThan(1.0));
  });
}
