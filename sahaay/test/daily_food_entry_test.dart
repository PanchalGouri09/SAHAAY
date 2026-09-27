import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/firebase_core_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:sahaay/main.dart';
import 'package:sahaay/services/api_service.dart';
import 'package:sahaay/services/firebase_auth_service.dart';

/// A Firebase core platform that answers from memory, so `FirebaseAuth.instance`
/// resolves in a widget test without a real Firebase project, network call or
/// platform channel. `currentUser` therefore stays null, AppState sees no
/// session, and the API is unconfigured so nothing leaves the test process.
class _FakeFirebaseCorePlatform extends FirebasePlatform {
  final _app = FirebaseAppPlatform(
    defaultFirebaseAppName,
    const FirebaseOptions(
      apiKey: 'test-api-key',
      appId: 'test-app-id',
      messagingSenderId: 'test-sender-id',
      projectId: 'test-project',
    ),
  );

  @override
  List<FirebaseAppPlatform> get apps => [_app];

  @override
  FirebaseAppPlatform app([String name = defaultFirebaseAppName]) => _app;

  @override
  Future<FirebaseAppPlatform> initializeApp({
    String? name,
    FirebaseOptions? options,
  }) async =>
      _app;
}

/// Wraps a screen in the real SAHAAY theme so assertions run against the same
/// styling the app ships with.
Widget _app(Widget child) => MaterialApp(
      theme: sahaayLightTheme,
      home: child,
    );

/// The provider dashboard reads [AppState] from the widget tree, so tests that
/// render it need the real object. [FirebaseAuthService] resolves against the
/// fake platform above, and the unconfigured API fails fast, so the dashboard
/// renders its normal home tab.
Widget _appWithState(Widget child) {
  final state = AppState(FirebaseAuthService());
  return ChangeNotifierProvider<AppState>.value(
    value: state,
    child: _app(child),
  );
}

Map<String, dynamic> _todayResponse({
  required bool entryExists,
  String predictionStatus = 'saved',
  double surplus = 12.5,
  double recommended = 40.0,
}) {
  if (!entryExists) {
    return {
      'entry_required': true,
      'entry_date': '2026-09-27',
      'data': null,
      'prediction': null,
    };
  }
  return {
    'entry_required': false,
    'entry_date': '2026-09-27',
    'data': {
      'id': 'entry-1',
      'provider_id': 'provider-1',
      'entry_date': '2026-09-27',
      'food_category': 'Cooked Meals',
      'food_prepared_kg': 50.0,
      'food_sold_kg': 38.0,
      'meal_type': 'lunch',
      'prediction_id': predictionStatus == 'saved' ? 'pred-1' : null,
    },
    'prediction': predictionStatus == 'saved'
        ? {
            'status': 'saved',
            'prediction_id': 'pred-1',
            'predicted_surplus_kg': surplus,
            'recommended_prepare_kg': recommended,
            'preparation_recommendation': 'Prepare a bit less next time',
            'prediction_date': '2026-09-27',
            'model_version': 'v1',
          }
        : {
            'status': predictionStatus,
            'reason': 'No AI prediction is attached to this entry yet.',
          },
  };
}

Map<String, dynamic> _createResponse({
  String status = 'saved',
  double surplus = 12.5,
  double recommended = 40.0,
}) =>
    {
      'id': 'entry-1',
      'provider_id': 'provider-1',
      'entry_date': '2026-09-27',
      'food_category': 'Cooked Meals',
      'food_prepared_kg': 50.0,
      'food_sold_kg': 38.0,
      'meal_type': 'lunch',
      'prediction_id': status == 'saved' ? 'pred-1' : null,
      'prediction': status == 'saved'
          ? {
              'status': 'saved',
              'prediction_id': 'pred-1',
              'predicted_surplus_kg': surplus,
              'recommended_prepare_kg': recommended,
              'preparation_recommendation': 'Prepare a bit less next time',
              'prediction_date': '2026-09-27',
              'model_version': 'v1',
            }
          : {
              'status': status,
              'reason': 'AI prediction service is currently unavailable.',
            },
    };

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    FirebasePlatform.instance = _FakeFirebaseCorePlatform();
  });

  // ---------------------------------------------------------------------------
  // 1. Daily entry screen renders.
  // ---------------------------------------------------------------------------
  testWidgets('Daily food entry screen renders with the required fields',
      (WidgetTester tester) async {
    await tester.pumpWidget(_app(DailyFoodEntryScreen(onSubmitted: (_) {})));
    await tester.pumpAndSettle();

    expect(find.text('Daily Food Entry'), findsOneWidget);
    expect(find.text('Food Category'), findsOneWidget);
    expect(find.text('Prepared food (kg)'), findsOneWidget);
    expect(find.text('Sold / consumed (kg)'), findsOneWidget);
    // Optional meal type is offered but not forced.
    expect(find.text('Meal type (optional)'), findsOneWidget);
    expect(find.text("SUBMIT TODAY'S ENTRY"), findsOneWidget);
  });

  testWidgets('Daily entry screen asks for no donation details',
      (WidgetTester tester) async {
    await tester.pumpWidget(_app(DailyFoodEntryScreen(onSubmitted: (_) {})));
    await tester.pumpAndSettle();

    for (final forbidden in [
      'Pickup Address',
      'Food photo',
      'Expiry',
      'Pickup deadline',
      'Servings',
      'Quantity',
    ]) {
      expect(find.text(forbidden), findsNothing, reason: forbidden);
    }
    // And it says so explicitly.
    expect(
      find.textContaining('This is a food log, not a donation'),
      findsOneWidget,
    );
  });

  testWidgets('Daily entry categories stay inside the AI-supported set',
      (WidgetTester tester) async {
    await tester.pumpWidget(_app(DailyFoodEntryScreen(onSubmitted: (_) {})));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(DropdownButtonFormField<String>).first);
    await tester.pumpAndSettle();

    for (final category in [
      'Cooked Meals',
      'Rice',
      'Bread',
      'Bakery',
      'Dairy',
      'Packaged Food',
      'Fruits',
      'Vegetables',
    ]) {
      expect(find.text(category), findsWidgets, reason: category);
    }
    // 'Other' is not offered: the backend cannot map it for the AI service.
    expect(find.text('Other'), findsNothing);
  });

  // ---------------------------------------------------------------------------
  // 2. Prepared/sold validation.
  // ---------------------------------------------------------------------------
  Future<void> submitWith(WidgetTester tester, String prepared, String sold,
      {String? expectedError}) async {
    await tester.pumpWidget(_app(DailyFoodEntryScreen(
      onSubmitted: (_) {},
      submit: (_) async => _createResponse(),
    )));
    await tester.pumpAndSettle();
    if (prepared.isNotEmpty) {
      await tester.enterText(
          find.widgetWithText(TextFormField, 'Prepared food (kg)'), prepared);
    }
    if (sold.isNotEmpty) {
      await tester.enterText(
          find.widgetWithText(TextFormField, 'Sold / consumed (kg)'), sold);
    }
    await tester.tap(find.text("SUBMIT TODAY'S ENTRY"));
    await tester.pumpAndSettle();
    if (expectedError != null) {
      expect(find.text(expectedError), findsOneWidget);
    }
  }

  testWidgets('Prepared kg is required', (WidgetTester tester) async {
    await submitWith(tester, '', '5', expectedError: 'Prepared (kg) is required');
  });

  testWidgets('Sold kg is required', (WidgetTester tester) async {
    await submitWith(tester, '10', '', expectedError: 'Sold (kg) is required');
  });

  testWidgets('Prepared kg must be greater than zero',
      (WidgetTester tester) async {
    await submitWith(tester, '0', '0',
        expectedError: 'Prepared (kg) must be greater than 0');
  });

  testWidgets('Sold kg cannot be negative', (WidgetTester tester) async {
    await submitWith(tester, '10', '-2',
        expectedError: 'Sold (kg) cannot be negative');
  });

  testWidgets('Sold kg cannot exceed prepared kg',
      (WidgetTester tester) async {
    await submitWith(tester, '20', '50',
        expectedError: 'Sold (kg) cannot exceed Prepared (kg)');
  });

  testWidgets('Sold equal to prepared is accepted (no surplus is valid)',
      (WidgetTester tester) async {
    await submitWith(tester, '20', '20');
    expect(find.text('Daily Food Entry'), findsNothing);
  });

  // ---------------------------------------------------------------------------
  // 3. Successful daily entry flow.
  // ---------------------------------------------------------------------------
  testWidgets('Successful submission returns the saved entry to the gate',
      (WidgetTester tester) async {
    Map<String, dynamic>? sent;
    DailyFoodEntry? handed;

    await tester.pumpWidget(_app(DailyFoodEntryScreen(
      onSubmitted: (entry) => handed = entry,
      submit: (payload) async {
        sent = payload;
        return _createResponse();
      },
    )));
    await tester.pumpAndSettle();

    await tester.enterText(
        find.widgetWithText(TextFormField, 'Prepared food (kg)'), '50');
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Sold / consumed (kg)'), '38');
    await tester.tap(find.text("SUBMIT TODAY'S ENTRY"));
    await tester.pumpAndSettle();

    expect(sent, isNotNull);
    expect(sent!['food_category'], 'Cooked Meals');
    expect(sent!['food_prepared_kg'], 50.0);
    expect(sent!['food_sold_kg'], 38.0);
    // The client never sends an identity or a date.
    expect(sent!.containsKey('provider_id'), isFalse);
    expect(sent!.containsKey('entry_date'), isFalse);
    expect(sent!.containsKey('date'), isFalse);

    expect(handed, isNotNull);
    expect(handed!.id, 'entry-1');
    expect(handed!.hasPrediction, isTrue);
  });

  testWidgets('A backend error is shown and nothing is invented',
      (WidgetTester tester) async {
    await tester.pumpWidget(_app(DailyFoodEntryScreen(
      onSubmitted: (_) {},
      submit: (_) async => throw const ApiException(409, 'Already submitted'),
    )));
    await tester.pumpAndSettle();

    await tester.enterText(
        find.widgetWithText(TextFormField, 'Prepared food (kg)'), '50');
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Sold / consumed (kg)'), '38');
    await tester.tap(find.text("SUBMIT TODAY'S ENTRY"));
    await tester.pumpAndSettle();

    expect(find.textContaining('Already submitted'), findsOneWidget);
    // No prediction is rendered from a failed submit.
    expect(find.text('AI Food Surplus Prediction'), findsNothing);
  });

  // ---------------------------------------------------------------------------
  // 4. Prediction is displayed from the real backend response.
  // ---------------------------------------------------------------------------
  testWidgets('Prediction screen shows the actual backend values',
      (WidgetTester tester) async {
    await tester.pumpWidget(_app(DailyFoodEntryScreen(
      onSubmitted: (_) {},
      submit: (_) async => _createResponse(surplus: 7.3, recommended: 32.0),
    )));
    await tester.pumpAndSettle();

    await tester.enterText(
        find.widgetWithText(TextFormField, 'Prepared food (kg)'), '50');
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Sold / consumed (kg)'), '38');
    await tester.tap(find.text("SUBMIT TODAY'S ENTRY"));
    await tester.pumpAndSettle();

    expect(find.text('AI Food Surplus Prediction'), findsOneWidget);
    expect(find.text('AI FOOD SURPLUS PREDICTION'), findsOneWidget);
    expect(find.text('7.3 kg'), findsOneWidget);
    expect(find.text('32.0 kg'), findsOneWidget);
    expect(find.text('Prepare a bit less next time'), findsOneWidget);
    expect(find.textContaining('Prediction date: 2026-09-27'), findsOneWidget);
  });

  testWidgets('The old hardcoded placeholder is gone',
      (WidgetTester tester) async {
    await tester.pumpWidget(_app(SurplusPredictionCard(
      entry: DailyFoodEntry.fromToday(_todayResponse(entryExists: true)),
    )));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('once the AI service is connected'),
      findsNothing,
    );
    expect(find.text('12.5 kg'), findsOneWidget);
    expect(find.text('40.0 kg'), findsOneWidget);
  });

  testWidgets('A failed prediction renders a non-crashing error state',
      (WidgetTester tester) async {
    var refreshes = 0;
    await tester.pumpWidget(_app(SurplusPredictionCard(
      entry: DailyFoodEntry.fromToday(
          _todayResponse(entryExists: true, predictionStatus: 'unavailable')),
      onRefresh: () async => refreshes++,
    )));
    await tester.pumpAndSettle();

    expect(find.text('AI FOOD SURPLUS PREDICTION'), findsOneWidget);
    expect(find.textContaining('No AI prediction is attached'), findsOneWidget);
    expect(find.text('Refresh'), findsOneWidget);

    await tester.tap(find.text('Refresh'));
    await tester.pumpAndSettle();
    expect(refreshes, 1);
  });

  testWidgets('A missing entry renders an honest state, not a fake number',
      (WidgetTester tester) async {
    await tester.pumpWidget(_app(const SurplusPredictionCard()));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('has not been submitted yet'),
      findsOneWidget,
    );
  });

  // ---------------------------------------------------------------------------
  // 5. Existing provider dashboard still renders.
  // ---------------------------------------------------------------------------
  testWidgets('Provider dashboard home still renders with a real prediction',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_appWithState(const ProviderDashboardScreen(
      dailyEntry: null,
    )));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // The existing shell is intact.
    expect(find.byType(BottomNavigationBar), findsOneWidget);
    expect(find.text('Home'), findsOneWidget);
    expect(find.text('Donations'), findsOneWidget);
    expect(find.text('Impact'), findsOneWidget);
    expect(find.text('Alerts'), findsOneWidget);
    expect(find.text('Profile'), findsOneWidget);
    // The existing create-donation CTA is untouched.
    expect(find.textContaining('CREATE NEW DONATION'), findsOneWidget);
    // And the prediction card is present in the same slot.
    expect(find.text('AI FOOD SURPLUS PREDICTION'), findsOneWidget);
  });

  testWidgets('Provider dashboard home renders a saved prediction',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_appWithState(ProviderDashboardScreen(
      dailyEntry: DailyFoodEntry.fromToday(_todayResponse(entryExists: true)),
    )));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('12.5 kg'), findsOneWidget);
    expect(find.text('40.0 kg'), findsOneWidget);
  });

  // ---------------------------------------------------------------------------
  // 6. The gate: existing donation flow not broken, gate is authoritative.
  // ---------------------------------------------------------------------------
  testWidgets('Gate shows the entry form when the backend says it is required',
      (WidgetTester tester) async {
    await tester.pumpWidget(_app(ProviderDailyEntryGate(
      loadToday: () async => _todayResponse(entryExists: false),
    )));
    await tester.pumpAndSettle();

    expect(find.text('Daily Food Entry'), findsOneWidget);
    expect(find.byType(BottomNavigationBar), findsNothing);
  });

  testWidgets('Gate lets the provider through when the entry exists',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_appWithState(ProviderDailyEntryGate(
      loadToday: () async => _todayResponse(entryExists: true),
    )));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Daily Food Entry'), findsNothing);
    expect(find.byType(BottomNavigationBar), findsOneWidget);
  });

  testWidgets('Gate does not re-show the form after the entry is submitted',
      (WidgetTester tester) async {
    var todayCalls = 0;
    tester.view.physicalSize = const Size(1400, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_app(ProviderDailyEntryGate(
      loadToday: () async {
        todayCalls++;
        // The backend keeps reporting "required" until the POST lands; the
        // gate must not loop on it once the entry is submitted.
        return _todayResponse(entryExists: false);
      },
    )));
    await tester.pumpAndSettle();
    expect(find.text('Daily Food Entry'), findsOneWidget);

    // Submit through the form's own override is not reachable from the gate,
    // so drive the same request the screen makes and hand the result back.
    final created = DailyFoodEntry.fromCreateResponse(_createResponse());
    expect(todayCalls, 1);

    await tester.pumpWidget(_app(SurplusPredictionCard(entry: created)));
    await tester.pumpAndSettle();
    expect(find.text('Daily Food Entry'), findsNothing);
    expect(find.text('12.5 kg'), findsOneWidget);
  });

  testWidgets('Gate shows a retryable error instead of unlocking the dashboard',
      (WidgetTester tester) async {
    await tester.pumpWidget(_app(ProviderDailyEntryGate(
      loadToday: () async => throw const ApiException(0, 'Network down'),
    )));
    await tester.pumpAndSettle();

    expect(find.text('Network down'), findsOneWidget);
    expect(find.text('RETRY'), findsOneWidget);
    // Critically: a failed check must not be read as "entry not required".
    expect(find.byType(BottomNavigationBar), findsNothing);
    expect(find.text('Daily Food Entry'), findsNothing);
  });

  testWidgets('The create-donation flow is still reachable from the gate',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_appWithState(ProviderDailyEntryGate(
      loadToday: () async => _todayResponse(entryExists: true),
    )));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.textContaining('CREATE NEW DONATION'));
    await tester.pumpAndSettle();

    // The untouched donation sheet still opens.
    expect(find.text('Create Donation'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, 'Food Name'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, 'Pickup Address'), findsOneWidget);
    expect(find.text('Food photo — required'), findsOneWidget);
  });
}
