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
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(textScale)),
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

  testWidgets('EmptyState supports a clear detail and actionable retry',
      (tester) async {
    var retries = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: sahaayLightTheme,
        home: Scaffold(
          body: Center(
            child: EmptyState(
              icon: Icons.cloud_off_outlined,
              message: 'Could not load notifications.',
              description: 'Check your connection and try again.',
              actionLabel: 'Retry',
              onAction: () => retries++,
            ),
          ),
        ),
      ),
    );

    expect(find.text('Could not load notifications.'), findsOneWidget);
    expect(find.text('Check your connection and try again.'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    expect(retries, 1);
  });

  testWidgets(
      'NotificationTile remains readable at narrow width and larger text',
      (tester) async {
    final semantics = tester.ensureSemantics();
    tester.view.physicalSize = const Size(320, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const title = 'A volunteer has accepted your food delivery request';
    const body =
        'Your donation is moving to the receiving organization. Check the delivery details for the latest status and pickup information.';
    final item = AppNotificationItem(
      title: title,
      body: body,
      time: 'Today, 10:45 AM',
      category: NotificationCategory.volunteer,
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: sahaayLightTheme,
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.4)),
          child: Scaffold(
            body: ListView(
              padding: const EdgeInsets.all(16),
              children: [NotificationTile(item: item)],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text(title), findsOneWidget);
    expect(find.text(body), findsOneWidget);
    expect(find.bySemanticsLabel('Unread'), findsOneWidget);
    expect(tester.getRect(find.byType(NotificationTile)).right,
        lessThanOrEqualTo(320));
    semantics.dispose();
  });

  testWidgets('role selection scrolls instead of overflowing on small screens',
      (tester) async {
    tester.view.physicalSize = const Size(320, 560);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: sahaayLightTheme,
        home: const MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(1.4)),
          child: RoleSelectionScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(RoleCard), findsNWidgets(3));
  });

  testWidgets('DonationCard keeps long food names readable on narrow screens',
      (tester) async {
    tester.view.physicalSize = const Size(320, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const foodName =
        'Freshly prepared seasonal vegetable and lentil lunch boxes';
    final donation = Donation(
      id: 'donation-ui-test',
      foodName: foodName,
      category: 'Cooked Meals',
      quantityKg: 12,
      quantity: 12,
      quantityUnit: 'kg',
      servings: 24,
      providerName: 'Community Kitchen',
      distanceKm: null,
      expiryLabel: 'Pickup by 6:30 PM today',
      freshness: 'Freshly prepared',
      status: DonationStatus.available,
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: sahaayLightTheme,
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.4)),
          child: Scaffold(
            body: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: DonationCard(donation: donation),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text(foodName), findsOneWidget);
    expect(find.text('Cooked Meals'), findsOneWidget);
    expect(find.byIcon(Icons.fastfood_outlined), findsOneWidget);
    final card = tester.getRect(find.byType(DonationCard));
    expect(card.left, greaterThanOrEqualTo(0));
    expect(card.right, lessThanOrEqualTo(320));
  });
}
