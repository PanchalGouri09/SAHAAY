import 'dart:async';
import 'dart:io';

import 'package:firebase_core_platform_interface/firebase_core_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:sahaay/main.dart';
import 'package:sahaay/services/api_service.dart';
import 'package:sahaay/services/firebase_auth_service.dart';
import 'package:sahaay/services/profile_completion.dart';

/// In-memory Firebase core so `FirebaseAuth.instance` resolves in widget
/// tests without a real project (same seam as daily_food_entry_test).
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

/// Scripted backend for the dashboards: empty donations/claims, a real
/// profile payload, and a vehicle-answer endpoint whose failure mode the
/// test scripts (ApiException vs a raw transport-level error).
class _FakeApi extends ApiService {
  _FakeApi({required this.profile});

  Map<String, dynamic> profile;
  List<dynamic> donations = <dynamic>[];
  List<dynamic> claims = <dynamic>[];
  List<dynamic> providerClaims = <dynamic>[];
  List<dynamic> ngoOffers = <dynamic>[];
  final List<Map<String, dynamic>> claimRequests = [];
  int ngoOfferReads = 0;
  final List<(String, String)> offerResponses = [];
  Map<String, dynamic> persistedDonationOffers = <String, dynamic>{};
  ApiException? persistedDonationOfferError;
  int persistedDonationOfferReads = 0;
  int manualMatchCalls = 0;
  int rankedEscalationCalls = 0;
  final List<Map<String, dynamic>> donationRequests = [];
  final List<String> donationFoodTypeUpdates = [];
  int donationPhotoUploads = 0;
  int handoverStateReads = 0;
  Map<String, dynamic> handoverState = {
    'handover_verified': false,
    'handover_verified_at': null,
    'handover_photo_url': null,
    'has_active_code': false,
    'handover_code_expires_at': null,
    'receipt_ready': false,
  };
  Map<String, dynamic> transportCoordination = <String, dynamic>{};
  int transportCoordinationReads = 0;
  ApiException? transportCoordinationReadError;
  final List<Map<String, dynamic>> transportResponses = [];
  Completer<Map<String, dynamic>>? pendingDonationResponse;
  Completer<({double latitude, double longitude})?>? pendingGeocode;
  Object? donationError;
  Object? donationPhotoUploadError;

  /// Every `vehicle_available` value the backend was asked to store.
  final List<bool?> vehicleAnswers = [];

  /// When true, the NEXT vehicle answer throws a NON-ApiException (a socket
  /// drop / timeout), exactly like a real transport failure.
  bool throwTransportErrorOnce = false;

  @override
  Future<Map<String, dynamic>> getProfile() async => profile;

  @override
  Future<List<dynamic>> getDonations() async => donations;

  @override
  Future<String> uploadDonationImage(File file) async {
    donationPhotoUploads++;
    final error = donationPhotoUploadError;
    if (error != null) {
      donationPhotoUploadError = null;
      throw error;
    }
    return 'https://cdn.test/food-photo.png';
  }

  @override
  Future<({double latitude, double longitude})?> geocodeAddress(
      String address) async {
    final pending = pendingGeocode;
    if (pending == null) return (latitude: 18.52, longitude: 73.85);
    return await pending.future;
  }

  @override
  Future<Map<String, dynamic>> createDonation(
      Map<String, dynamic> payload) async {
    donationRequests.add(Map<String, dynamic>.from(payload));
    final error = donationError;
    if (error != null) {
      donationError = null;
      throw error;
    }
    final response = pendingDonationResponse == null
        ? _createdDonation(payload)
        : await pendingDonationResponse!.future;
    donations.insert(0, response);
    return response;
  }

  @override
  Future<List<dynamic>> getClaims() async => claims;

  @override
  Future<Map<String, dynamic>> createClaim(Map<String, dynamic> payload) async {
    claimRequests.add(Map<String, dynamic>.from(payload));
    final donation = donations.firstWhere(
      (row) => row is Map && row['id'] == payload['donation_id'],
    );
    final claim = {
      'id': 'claim-created',
      'donation_id': payload['donation_id'],
      'status': 'pending',
      'donation': Map<String, dynamic>.from(donation as Map),
    };
    claims = [...claims, claim];
    return claim;
  }

  @override
  Future<List<dynamic>> getDeliveries() async => <dynamic>[];

  @override
  Future<List<dynamic>> getVolunteerTransportTasks() async => <dynamic>[];

  @override
  Future<List<dynamic>> getProviderClaims() async => providerClaims;

  @override
  Future<List<dynamic>> getNgoDonationOffers() async {
    ngoOfferReads++;
    return ngoOffers;
  }

  @override
  Future<Map<String, dynamic>> respondToDonationOffer(
      String offerId, String decision) async {
    offerResponses.add((offerId, decision));
    for (final row in ngoOffers) {
      if (row is Map && row['id'] == offerId) {
        row['status'] = decision;
      }
    }
    return {'status': decision, 'changed': true};
  }

  @override
  Future<Map<String, dynamic>> getDonationOffers(String donationId) async {
    persistedDonationOfferReads++;
    if (persistedDonationOfferError != null) {
      throw persistedDonationOfferError!;
    }
    return persistedDonationOffers;
  }

  @override
  Future<Map<String, dynamic>> updateDonationFoodType(
    String donationId,
    String vegType,
  ) async {
    donationFoodTypeUpdates.add(vegType);
    persistedDonationOffers = {
      'matching_state': 'active',
      'matching_reason': null,
      'current_offer': {'status': 'pending'},
      'ranked_candidates': [
        {
          'match_rank': 1,
          'ai_rank': 1,
          'final_score': 90,
          'score_details': const <String, dynamic>{},
          'ngo': {'organization_name': 'Eligible Pantry'},
        },
      ],
    };
    return {
      'veg_type': vegType,
      'matching': {'status': 'offered'}
    };
  }

  @override
  Future<Map<String, dynamic>> matchDonation(String donationId) async {
    manualMatchCalls++;
    throw StateError(
        'Provider screen must not independently recalculate matches');
  }

  @override
  Future<Map<String, dynamic>> checkRankedOfferEscalation(
      String donationId) async {
    rankedEscalationCalls++;
    return {'status': 'not_due', 'changed': false};
  }

  @override
  Future<Map<String, dynamic>> getHandoverState(String donationId) async {
    handoverStateReads++;
    return handoverState;
  }

  @override
  Future<Map<String, dynamic>> getTransportCoordination(String claimId) async {
    transportCoordinationReads++;
    final error = transportCoordinationReadError;
    if (error != null) {
      transportCoordinationReadError = null;
      throw error;
    }
    return Map<String, dynamic>.from(transportCoordination);
  }

  @override
  Future<Map<String, dynamic>> respondToTransportCoordination(
    String claimId, {
    required String response,
    String? captainName,
    String? captainPhone,
  }) async {
    transportResponses.add({
      'claim_id': claimId,
      'response': response,
      if (captainName != null) 'captain_name': captainName,
      if (captainPhone != null) 'captain_phone': captainPhone,
    });
    transportCoordination = {
      ...transportCoordination,
      'ngo_response': response,
      'status': response == 'no' ? 'searching_for_volunteers' : 'ngo_transport',
      if (response == 'yes') 'responsible_role': 'ngo',
      if (captainName != null) 'ngo_captain_name': captainName,
      if (captainPhone != null) 'ngo_captain_phone': captainPhone,
    };
    return Map<String, dynamic>.from(transportCoordination);
  }

  Future<Map<String, dynamic>> _answer(bool? available) async {
    vehicleAnswers.add(available);
    if (throwTransportErrorOnce) {
      throwTransportErrorOnce = false;
      throw StateError('Connection reset by peer');
    }
    return {'status': 'ok', 'vehicle_available': available};
  }

  @override
  Future<Map<String, dynamic>> setNgoVehicleAvailability(bool? available) =>
      _answer(available);

  @override
  Future<Map<String, dynamic>> setProviderVehicleAvailability(
          bool? available) =>
      _answer(available);
}

class _FakeAppState extends AppState {
  _FakeAppState(this._api, {FirebaseAuthService? authService})
      : super(authService ?? FirebaseAuthService());
  final ApiService _api;

  @override
  ApiService get api => _api;
}

class _MutableProfileAuthService extends FirebaseAuthService {
  _MutableProfileAuthService(this.profile);

  AuthProfile? profile;

  @override
  Stream<AuthProfile?> get authStateChanges => const Stream.empty();

  @override
  Future<AuthProfile?> get currentProfile async => profile;
}

Widget _app(Widget child) => MaterialApp(
      theme: sahaayLightTheme,
      home: child,
    );

Widget _appWithState(
  Widget child,
  _FakeApi api, {
  void Function(_FakeAppState state)? onState,
  FirebaseAuthService? authService,
}) {
  final state = _FakeAppState(api, authService: authService);
  onState?.call(state);
  return ChangeNotifierProvider<AppState>.value(
    value: state,
    child: _app(child),
  );
}

/// GET /profile shape for an NGO that has NOT answered the vehicle question
/// (vehicle_available null — "not answered", never false).
Map<String, dynamic> _ngoProfile() => {
      'id': 'user-1',
      'firebase_uid': 'uid-1',
      'full_name': 'Gouri',
      'email': 'ngo@example.com',
      'phone': '8830392843',
      'role': 'ngo',
      'profile_image_url': null,
      'profile': {
        'id': 'ngo-1',
        'user_id': 'user-1',
        'organization_name': 'Old age home',
        'address': 'VadgaonSheri',
        'city': 'Pune',
        'description': null,
        'vehicle_available': null,
      },
    };

/// GET /profile shape for a provider that has NOT answered yet.
Map<String, dynamic> _providerProfile() => {
      'id': 'user-2',
      'firebase_uid': 'uid-2',
      'full_name': 'Gouri Panchal',
      'email': 'provider@example.com',
      'phone': '8830392843',
      'role': 'provider',
      'profile_image_url': null,
      'profile': {
        'id': 'provider-1',
        'user_id': 'user-2',
        'organization_name': 'Shree krishna veg',
        'organization_type': 'restaurant',
        'address': 'VadgaonSheri',
        'city': 'Pune',
        'description': null,
        'vehicle_available': null,
      },
    };

Map<String, dynamic> _volunteerProfile({required int percentage}) => {
      'id': 'user-volunteer',
      'firebase_uid': 'uid-volunteer',
      'full_name': 'Test volunteer',
      'email': 'volunteer@example.com',
      'phone': '9876543210',
      'role': 'volunteer',
      'profile': <String, dynamic>{},
      'profile_completion': {
        'role': 'volunteer',
        'complete': percentage == 100,
        'completed_fields': percentage == 100 ? 2 : 1,
        'total_fields': 2,
        'percentage': percentage,
        'missing_fields': percentage == 100 ? <String>[] : ['City'],
      },
    };

Map<String, dynamic> _profileCompletionResponse(UserRole role, int percentage) {
  final complete = percentage == 100;
  return {
    'role': role.name,
    'profile_completion': {
      'role': role.name,
      'complete': complete,
      'completed_fields': complete ? 2 : 1,
      'total_fields': 2,
      'percentage': percentage,
      'missing_fields': complete ? <String>[] : ['Required field'],
      if (role == UserRole.ngo) 'verified': false,
    },
  };
}

Map<String, dynamic> _completeProviderProfile() {
  final profile = _providerProfile();
  profile['profile'] = {
    ...Map<String, dynamic>.from(profile['profile'] as Map),
    'latitude': 18.52,
    'longitude': 73.85,
  };
  profile['profile_completion'] = {
    'role': 'provider',
    'complete': true,
    'completed_fields': 7,
    'total_fields': 7,
    'percentage': 100,
    'missing_fields': <String>[],
  };
  return profile;
}

Map<String, dynamic> _completeNgoProfile({bool? verified}) {
  final profile = _ngoProfile()
    ..['profile'] = {
      ...Map<String, dynamic>.from(_ngoProfile()['profile'] as Map),
      'latitude': 18.52,
      'longitude': 73.85,
      'available_from': '07:00',
      'available_to': '22:00',
      'max_capacity_kg': 25,
      'preferred_food_types': ['Cooked Meals'],
      'dietary_preferences': ['vegetarian'],
      'vehicle_available': true,
      'verified': verified,
    }
    ..['profile_completion'] = {
      'role': 'ngo',
      'complete': true,
      'completed_fields': 11,
      'total_fields': 11,
      'percentage': 100,
      'missing_fields': <String>[],
      'verified': verified,
    };
  return profile;
}

Map<String, dynamic> _createdDonation(Map<String, dynamic> payload) => {
      'id': 'donation-created',
      'food_name': payload['food_name'],
      'food_category': payload['food_category'],
      'quantity': payload['quantity'],
      'unit': payload['unit'],
      'servings': payload['servings'],
      'pickup_address': payload['pickup_address'],
      'latitude': payload['latitude'],
      'longitude': payload['longitude'],
      'food_image_url': payload['food_image_url'],
      'status': 'available',
      'prepared_at': DateTime.now().toIso8601String(),
      'expiry_time':
          DateTime.now().add(const Duration(hours: 4)).toIso8601String(),
      'pickup_deadline':
          DateTime.now().add(const Duration(hours: 4)).toIso8601String(),
      'matching': {'status': 'no_candidates', 'ranked_ngos': []},
    };

const _transportErrorText =
    'Could not save your answer. Check your connection and try again.';

/// Lets any snackbar auto-dismiss so no timer leaks into the next test.
Future<void> _settleSnackbar(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 5));
  await tester.pumpAndSettle();
}

Future<void> _prepareDonationForm(
  WidgetTester tester,
  _FakeApi api, {
  bool selectFoodType = true,
}) async {
  await tester.pumpWidget(
    ChangeNotifierProvider<AppState>.value(
      value: _FakeAppState(api),
      child: _app(ProviderDashboardScreen(
        testDonationPhoto: File('assets/images/sahaay_logo_transparent.png'),
      )),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.textContaining('CREATE NEW DONATION'));
  await tester.pump(const Duration(milliseconds: 500));

  final foodName = find.widgetWithText(TextFormField, 'Food Name');
  await tester.ensureVisible(foodName);
  await tester.enterText(foodName, 'Fresh bread');
  final pickupAddress = find.widgetWithText(TextFormField, 'Pickup Address');
  await tester.ensureVisible(pickupAddress);
  await tester.enterText(pickupAddress, '1 Market Road');
  final quantity = find.widgetWithText(TextFormField, 'Quantity (kg)');
  await tester.ensureVisible(quantity);
  await tester.enterText(quantity, '5');
  final servings = find.widgetWithText(TextFormField, 'Servings');
  await tester.ensureVisible(servings);
  await tester.enterText(servings, '20');
  if (selectFoodType) {
    final foodType = find.byKey(const ValueKey('donation-food-type'));
    await tester.ensureVisible(foodType);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(foodType);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('Vegetarian').last);
    await tester.pump(const Duration(milliseconds: 500));
  }
  await tester.ensureVisible(find.text('CREATE DONATION'));
  await tester.pump(const Duration(milliseconds: 500));
}

/// Gives every test a phone-tall viewport so whole screens fit without
/// scrolling, and restores the real size afterwards.
void _tallScreen(WidgetTester tester, {double height = 3600}) {
  tester.view.physicalSize = Size(1080, height);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    FirebasePlatform.instance = _FakeFirebaseCorePlatform();
  });

  group('Claim transport coordination', () {
    testWidgets('shows persisted prompt, saves response, and reloads it',
        (tester) async {
      final api = _FakeApi(profile: _ngoProfile())
        ..transportCoordination = {
          'claim_id': 'claim-1',
          'provider_response': null,
          'ngo_response': null,
          'responsible_role': null,
          'status': 'awaiting_responses',
        };
      _tallScreen(tester);
      await tester.pumpWidget(_appWithState(
        const TransportCoordinationCard(claimId: 'claim-1', role: 'ngo'),
        api,
      ));
      await tester.pumpAndSettle();

      expect(api.transportCoordinationReads, 1);
      expect(
          find.text('Are you going to pick up the donation?'), findsOneWidget);
      expect(find.text('Yes'), findsOneWidget);
      expect(find.text('No'), findsOneWidget);

      await tester.tap(find.text('No'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(api.transportResponses, hasLength(1));
      expect(api.transportResponses.single['response'], 'no');
      expect(find.text('Searching for volunteers'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(_appWithState(
        const TransportCoordinationCard(claimId: 'claim-1', role: 'ngo'),
        api,
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(api.transportCoordinationReads, 2);
      expect(find.textContaining('Cannot handle transport'), findsOneWidget);
      expect(find.text('Are you going to pick up the donation?'), findsNothing);
    });

    testWidgets('shows retry when persisted coordination cannot be read',
        (tester) async {
      final api = _FakeApi(profile: _ngoProfile())
        ..transportCoordinationReadError =
            const ApiException(503, 'Database migration required.');
      _tallScreen(tester);
      await tester.pumpWidget(_appWithState(
        const TransportCoordinationCard(claimId: 'claim-1', role: 'ngo'),
        api,
      ));
      await tester.pumpAndSettle();

      expect(find.text('Database migration required.'), findsOneWidget);
      expect(find.byTooltip('Retry'), findsOneWidget);
      await tester.tap(find.byTooltip('Retry'));
      await tester.pumpAndSettle();
      expect(api.transportCoordinationReads, 2);
      expect(
          find.text('Are you going to pick up the donation?'), findsOneWidget);
    });
  });

  group('Profile completion dashboards', () {
    testWidgets('NGO dashboard lists matching fields missing after enrollment',
        (tester) async {
      final api = _FakeApi(profile: _ngoProfile());
      _tallScreen(tester);
      await tester.pumpWidget(_appWithState(const NgoDashboardScreen(), api));
      await tester.pumpAndSettle();

      expect(find.text('Profile completion'), findsOneWidget);
      expect(find.text('55%'), findsOneWidget);
      expect(find.text('6 of 11 required fields complete'), findsOneWidget);
      expect(
        find.textContaining('Remaining: Location coordinates, Operating hours'),
        findsOneWidget,
      );
      expect(find.text('Complete profile'), findsOneWidget);
    });

    testWidgets('100% NGO profile hides progress while verification is pending',
        (tester) async {
      final profile = _completeNgoProfile(verified: false);
      final api = _FakeApi(profile: profile);
      _tallScreen(tester);
      await tester.pumpWidget(_appWithState(const NgoDashboardScreen(), api));
      await tester.pumpAndSettle();

      expect(find.text('Profile completion'), findsNothing);
    });

    for (final role
        in UserRole.values.where((value) => value != UserRole.admin)) {
      testWidgets('${role.name} profile tab refreshes progress visibility',
          (tester) async {
        final api = _FakeApi(profile: _profileCompletionResponse(role, 50));
        _FakeAppState? state;
        _tallScreen(tester);
        await tester.pumpWidget(_appWithState(
          ProfileTab(role: role, name: 'Test user'),
          api,
          onState: (value) => state = value,
        ));
        state!.updateProfileCompletionFromResponse(api.profile);
        await tester.pumpAndSettle();
        expect(find.text('Profile completion'), findsOneWidget);

        final complete = _profileCompletionResponse(role, 100);
        api.profile = complete;
        state!.updateProfileCompletionFromResponse(complete);
        await tester.pumpAndSettle();
        expect(find.text('Profile completion'), findsNothing);
      });
    }

    testWidgets('100% NGO profile hides progress with verified status',
        (tester) async {
      final api = _FakeApi(profile: _completeNgoProfile(verified: true));
      _tallScreen(tester);
      await tester.pumpWidget(_appWithState(const NgoDashboardScreen(), api));
      await tester.pumpAndSettle();

      expect(find.text('Profile completion'), findsNothing);
    });

    testWidgets('profile refresh hides progress after completion reaches 100%',
        (tester) async {
      final incomplete = ProfileCompletion.calculate(
        role: 'ngo',
        account: _ngoProfile(),
        roleProfile: Map<String, dynamic>.from(_ngoProfile()['profile'] as Map),
      );
      final auth = _MutableProfileAuthService(AuthProfile(
        uid: 'ngo-uid',
        email: 'ngo@example.com',
        role: 'ngo',
        fullName: 'Gouri',
        orgLabel: 'Old age home',
        profileCompletion: incomplete,
      ));
      final api = _FakeApi(profile: _ngoProfile());
      _FakeAppState? state;
      _tallScreen(tester);
      await tester.pumpWidget(_appWithState(
        const NgoDashboardScreen(),
        api,
        authService: auth,
        onState: (value) => state = value,
      ));
      await tester.pumpAndSettle();
      expect(find.text('Profile completion'), findsOneWidget);
      final initialOfferReads = api.ngoOfferReads;

      auth.profile = AuthProfile(
        uid: 'ngo-uid',
        email: 'ngo@example.com',
        role: 'ngo',
        fullName: 'Gouri',
        orgLabel: 'Old age home',
        profileCompletion: ProfileCompletion.fromBackend(
          _completeNgoProfile(verified: false)['profile_completion']
              as Map<String, dynamic>,
        ),
      );
      await state!.refreshProfile();
      await tester.pumpAndSettle();

      expect(find.text('Profile completion'), findsNothing);
      expect(api.ngoOfferReads, greaterThan(initialOfferReads));
    });

    testWidgets('NGO profile tab hides progress at 100% even when pending',
        (tester) async {
      final api = _FakeApi(profile: _completeNgoProfile(verified: false));
      _FakeAppState? state;
      _tallScreen(tester);
      await tester.pumpWidget(_appWithState(
        const ProfileTab(role: UserRole.ngo, name: 'Gouri'),
        api,
        onState: (value) => state = value,
      ));
      await tester.pumpAndSettle();
      state!.updateProfileCompletionFromResponse(
          _completeNgoProfile(verified: false));
      await tester.pumpAndSettle();

      expect(find.text('Profile completion'), findsNothing);
    });

    test('profile progress is hidden only when completion reaches 100%', () {
      final completion = ProfileCompletion.fromBackend(
        _completeNgoProfile()['profile_completion'] as Map<String, dynamic>,
      );

      expect(completion.percentage, 100);
      expect(shouldShowProfileProgress(completion), isFalse);
      final incomplete = ProfileCompletion.fromBackend({
        'role': 'volunteer',
        'complete': false,
        'completed_fields': 1,
        'total_fields': 2,
        'percentage': 50,
        'missing_fields': ['City'],
      });
      expect(shouldShowProfileProgress(incomplete), isTrue);
    });

    testWidgets(
        'volunteer dashboard shows progress below 100 and hides it at 100',
        (tester) async {
      final api = _FakeApi(profile: _volunteerProfile(percentage: 50));
      _FakeAppState? state;
      _tallScreen(tester);
      await tester.pumpWidget(_appWithState(
        const VolunteerDashboardScreen(),
        api,
        onState: (value) => state = value,
      ));
      await tester.pumpAndSettle();
      expect(find.text('Profile completion'), findsOneWidget);

      api.profile = _volunteerProfile(percentage: 100);
      state!.updateProfileCompletionFromResponse(api.profile);
      await tester.pumpAndSettle();
      expect(find.text('Profile completion'), findsNothing);
    });

    testWidgets(
        'active handover code cannot be regenerated and can be refreshed',
        (tester) async {
      final api = _FakeApi(profile: _ngoProfile())
        ..handoverState = {
          'handover_verified': false,
          'handover_verified_at': null,
          'handover_photo_url': null,
          'has_active_code': true,
          'handover_code_expires_at':
              DateTime.now().add(const Duration(minutes: 5)).toIso8601String(),
          'receipt_ready': false,
        };
      final donation = Donation(
        id: 'donation-1',
        foodName: 'Fresh bread',
        category: 'Bakery',
        quantityKg: 5,
        quantity: 5,
        quantityUnit: 'kg',
        servings: 20,
        providerName: 'Test provider',
        distanceKm: null,
        expiryLabel: '',
        freshness: '',
        status: DonationStatus.claimed,
      );
      _tallScreen(tester);
      await tester.pumpWidget(
        _appWithState(ClaimedDonationDashboard(donation: donation), api),
      );
      await tester.pumpAndSettle();

      expect(api.handoverStateReads, 1);
      expect(find.textContaining('A code is active until'), findsOneWidget);
      expect(find.text('Refresh code status'), findsOneWidget);
      expect(find.text('WAIT FOR CODE EXPIRY'), findsOneWidget);
      final disabledButton = tester.widget<OutlinedButton>(
        find.ancestor(
          of: find.text('WAIT FOR CODE EXPIRY'),
          matching: find.byType(OutlinedButton),
        ),
      );
      expect(disabledButton.onPressed, isNull);

      await tester.tap(find.text('Refresh code status'));
      await tester.pumpAndSettle();
      expect(api.handoverStateReads, 2);
    });

    testWidgets('provider dashboard reports missing pickup coordinates',
        (tester) async {
      final api = _FakeApi(profile: _providerProfile());
      _tallScreen(tester);
      await tester
          .pumpWidget(_appWithState(const ProviderDashboardScreen(), api));
      await tester.pumpAndSettle();

      expect(find.text('Profile completion'), findsOneWidget);
      expect(find.text('86%'), findsOneWidget);
      expect(find.text('6 of 7 required fields complete'), findsOneWidget);
      expect(
        find.textContaining('Pickup location coordinates'),
        findsOneWidget,
      );
    });

    testWidgets('complete provider dashboard hides profile progress',
        (tester) async {
      final api = _FakeApi(profile: _completeProviderProfile());
      _tallScreen(tester);
      await tester
          .pumpWidget(_appWithState(const ProviderDashboardScreen(), api));
      await tester.pumpAndSettle();

      expect(find.text('Profile completion'), findsNothing);
    });

    testWidgets('NGO dashboard has no separate matching eligibility status',
        (tester) async {
      final api = _FakeApi(profile: _ngoProfile());
      _tallScreen(tester);
      await tester.pumpWidget(_appWithState(const NgoDashboardScreen(), api));
      await tester.pumpAndSettle();

      expect(find.text('SAHAAY matching eligibility'), findsNothing);
      expect(find.text('Check eligibility'), findsNothing);
      final visibleText = tester
          .widgetList<Text>(find.byType(Text))
          .map((widget) => widget.data ?? widget.textSpan?.toPlainText() ?? '')
          .join(' ');
      expect(
        visibleText,
        isNot(matches(RegExp('matching eligibility', caseSensitive: false))),
      );
      expect(
        visibleText,
        isNot(matches(RegExp(r'phone|ownership|OTP', caseSensitive: false))),
      );
    });

    for (final scenario in [
      (role: UserRole.provider, screen: const ProviderDashboardScreen()),
      (role: UserRole.ngo, screen: const NgoDashboardScreen()),
      (role: UserRole.volunteer, screen: const VolunteerDashboardScreen()),
    ]) {
      testWidgets(
          '${scenario.role.name} dashboard has no phone ownership controls',
          (tester) async {
        final api = _FakeApi(
          profile: scenario.role == UserRole.ngo
              ? _ngoProfile()
              : scenario.role == UserRole.provider
                  ? _providerProfile()
                  : _volunteerProfile(percentage: 50),
        );
        _tallScreen(tester);
        await tester.pumpWidget(_appWithState(scenario.screen, api));
        await tester.pumpAndSettle();

        expect(find.textContaining('Phone ownership'), findsNothing);
        expect(find.textContaining('Phone verified'), findsNothing);
        expect(find.textContaining('Check Status'), findsNothing);
        expect(find.textContaining('Send OTP'), findsNothing);
        expect(find.textContaining('Contact verification'), findsNothing);
        expect(find.byKey(const ValueKey('contact-phone-otp')), findsNothing);
      });
    }

    testWidgets('incomplete NGO cannot accept an offer from the dashboard',
        (tester) async {
      final api = _FakeApi(profile: _ngoProfile())
        ..ngoOffers = [
          {
            'id': 'offer-incomplete',
            'candidate_rank': 1,
            'status': 'pending',
            'offer_expires_at': DateTime.now()
                .add(const Duration(minutes: 4))
                .toIso8601String(),
            'donation': {
              'food_name': 'Fresh bread',
              'food_category': 'bakery',
              'quantity': 8,
              'unit': 'kg',
              'pickup_address': '12 Main Road, Pune',
            },
            'ranked_candidate': {
              'final_score': 87,
              'score_details': {'distance_km': 3.2, 'distance_source': 'road'},
            },
          },
        ];
      _tallScreen(tester);
      await tester.pumpWidget(_appWithState(const NgoDashboardScreen(), api));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Accept offer'));
      await tester.pumpAndSettle();

      expect(find.text('Complete your profile first'), findsOneWidget);
      expect(api.offerResponses, isEmpty);
    });
  });

  group('Donation submission progress', () {
    testWidgets('requires a dietary type and sends the selected type',
        (tester) async {
      final api = _FakeApi(profile: _completeProviderProfile());
      _tallScreen(tester, height: 8000);
      await _prepareDonationForm(tester, api, selectFoodType: false);

      await tester.ensureVisible(find.text('CREATE DONATION'));
      await tester.tap(find.text('CREATE DONATION'));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('Required for NGO matching'), findsOneWidget);
      expect(api.donationRequests, isEmpty);

      await tester.tap(find.byKey(const ValueKey('donation-food-type')));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.text('Vegan').last);
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.text('CREATE DONATION'));
      await tester.pumpAndSettle();

      expect(api.donationRequests.single['veg_type'], 'vegan');
    });

    testWidgets(
        'shows progress, blocks duplicate taps, and refreshes after success',
        (tester) async {
      final api = _FakeApi(profile: _completeProviderProfile())
        ..pendingDonationResponse = Completer<Map<String, dynamic>>()
        ..pendingGeocode = Completer<({double latitude, double longitude})?>();
      _tallScreen(tester, height: 8000);
      await _prepareDonationForm(tester, api);

      final submit = find.text('CREATE DONATION');
      final submitCenter = tester.getCenter(submit);
      await tester.tap(submit);
      await tester.pump();
      await tester.tapAt(submitCenter);
      await tester.pump();

      expect(find.byType(CircularProgressIndicator), findsWidgets);
      expect(find.text('Creating donation'), findsNothing);
      expect(api.donationRequests, isEmpty);
      expect(api.donationPhotoUploads, 0);

      api.pendingGeocode!.complete((latitude: 18.52, longitude: 73.85));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();

      expect(
        find.text('Creating donation and finding matching NGOs'),
        findsOneWidget,
      );
      expect(api.donationRequests, hasLength(1));
      expect(api.donationRequests.single['veg_type'], 'vegetarian');
      expect(api.donationPhotoUploads, 1);

      api.pendingDonationResponse!
          .complete(_createdDonation(api.donationRequests.single));
      await tester.pumpAndSettle();

      expect(
        find.text(
          'Donation listed, but no matching NGOs are available for it yet.',
        ),
        findsOneWidget,
      );
      expect(api.donationRequests, hasLength(1));
    });

    testWidgets(
        'preserves the draft and succeeds when retried after API failure',
        (tester) async {
      final api = _FakeApi(profile: _completeProviderProfile())
        ..donationError = const ApiException(
          503,
          'AI service unavailable',
        );
      _tallScreen(tester, height: 8000);
      await _prepareDonationForm(tester, api);

      await tester.tap(find.text('CREATE DONATION'));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));

      expect(api.donationRequests, hasLength(1));
      expect(api.donationPhotoUploads, 1);
      expect(find.text('Finding eligible NGOs'), findsNothing);
      expect(
        find.text(
          'Donation submission is temporarily unavailable. Your donation details are saved; please retry.',
        ),
        findsOneWidget,
      );
      final retryButton =
          find.widgetWithText(ElevatedButton, 'CREATE NEW DONATION');
      expect(retryButton, findsOneWidget);
      expect(tester.widget<ElevatedButton>(retryButton).onPressed, isNotNull);

      await tester.tap(retryButton);
      await tester.pump(const Duration(milliseconds: 500));
      expect(
        tester
            .widget<TextFormField>(
              find.widgetWithText(TextFormField, 'Food Name'),
            )
            .controller!
            .text,
        'Fresh bread',
      );
      expect(
        tester
            .widget<TextFormField>(
              find.widgetWithText(TextFormField, 'Pickup Address'),
            )
            .controller!
            .text,
        '1 Market Road',
      );
      expect(
        tester
            .widget<TextFormField>(
              find.widgetWithText(TextFormField, 'Quantity (kg)'),
            )
            .controller!
            .text,
        '5',
      );

      await tester.ensureVisible(find.text('CREATE DONATION'));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.text('CREATE DONATION'));
      await tester.pumpAndSettle();

      expect(api.donationRequests, hasLength(2));
      expect(api.donationPhotoUploads, 1);
      expect(api.donationRequests[1]['food_name'], 'Fresh bread');
      expect(api.donationRequests[1]['pickup_address'], '1 Market Road');
      expect(api.donations, hasLength(1));
      expect(api.donations.single['matching']['status'], 'no_candidates');
    });

    testWidgets('preserves form contents after food photo upload failure',
        (tester) async {
      final api = _FakeApi(profile: _completeProviderProfile())
        ..donationPhotoUploadError = const ApiException(
          503,
          'storage unavailable',
        );
      _tallScreen(tester, height: 8000);
      await _prepareDonationForm(tester, api);

      await tester.tap(find.text('CREATE DONATION'));
      await tester.pumpAndSettle();

      expect(api.donationPhotoUploads, 1);
      expect(api.donationRequests, isEmpty);
      expect(
        find.text(
          'Food photo upload is temporarily unavailable. Your donation details are saved; please retry.',
        ),
        findsOneWidget,
      );

      await tester.tap(find.textContaining('CREATE NEW DONATION'));
      await tester.pump(const Duration(milliseconds: 500));
      expect(
        tester
            .widget<TextFormField>(
              find.widgetWithText(TextFormField, 'Food Name'),
            )
            .controller!
            .text,
        'Fresh bread',
      );
      expect(
        tester
            .widget<TextFormField>(
              find.widgetWithText(TextFormField, 'Pickup Address'),
            )
            .controller!
            .text,
        '1 Market Road',
      );
    });
  });

  group('Donation matching detail correction', () {
    testWidgets('saves explicitly selected food type and reloads ranked offer',
        (tester) async {
      final api = _FakeApi(profile: _completeProviderProfile())
        ..persistedDonationOffers = {
          'matching_state': 'insufficient_data',
          'matching_reason':
              'Donation dietary type is missing or unsupported, so compatibility cannot be verified.',
          'ranked_candidates': <dynamic>[],
          'current_offer': null,
        };
      final donation = Donation.fromBackend({
        'id': 'donation-1',
        'food_name': 'Rice',
        'food_category': 'Cooked Meals',
        'quantity': 5,
        'unit': 'kg',
        'servings': 20,
        'status': 'available',
      });
      _tallScreen(tester, height: 8000);
      await tester.pumpWidget(_appWithState(
        ProviderDonationMatchDetailsScreen(donation: donation),
        api,
      ));
      await tester.pumpAndSettle();

      expect(
        find.text('No ranked offer has been saved for this donation yet.'),
        findsNothing,
      );
      expect(find.text('Choose the donation food type'), findsOneWidget);
      final correction =
          find.byKey(const ValueKey('donation-food-type-correction'));
      await tester.ensureVisible(correction);
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(correction);
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.text('Vegetarian').last);
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.text('Save food type and retry'));
      await tester.pumpAndSettle();

      expect(api.donationFoodTypeUpdates, ['vegetarian']);
      expect(api.persistedDonationOfferReads, 2);
      expect(find.text('Eligible Pantry'), findsOneWidget);
      expect(find.text('Choose the donation food type'), findsNothing);
    });
  });

  group('Vehicle availability — a transport failure must not brick the screen',
      () {
    testWidgets(
        'NGO: failed save shows an honest error and the retry actually works',
        (tester) async {
      final api = _FakeApi(profile: _ngoProfile())
        ..throwTransportErrorOnce = true;
      _tallScreen(tester);
      await tester.pumpWidget(_appWithState(const NgoDashboardScreen(), api));
      await tester.pumpAndSettle();

      // The prompt is visible (null answer is NOT read as "no").
      expect(find.text('Vehicle Availability'), findsOneWidget);
      expect(find.text('Yes, I have a vehicle'), findsOneWidget);

      await tester.tap(find.text('Yes, I have a vehicle'));
      await tester.pumpAndSettle();

      // The raw transport error is surfaced honestly…
      expect(find.text(_transportErrorText), findsOneWidget);
      // …the state was reset (prompt still answerable, not stuck saving)…
      expect(find.text('Yes, I have a vehicle'), findsOneWidget);
      expect(api.vehicleAnswers, [true]);
      await _settleSnackbar(tester);

      // …and the NEXT tap reaches the backend and persists.
      await tester.tap(find.text('Yes, I have a vehicle'));
      await tester.pumpAndSettle();

      expect(api.vehicleAnswers, [true, true]);
      // Answered -> the prompt is gone.
      expect(find.text('Yes, I have a vehicle'), findsNothing);
    });

    testWidgets(
        'provider: failed save shows an honest error and the retry actually works',
        (tester) async {
      final api = _FakeApi(profile: _providerProfile())
        ..throwTransportErrorOnce = true;
      _tallScreen(tester);
      await tester
          .pumpWidget(_appWithState(const ProviderDashboardScreen(), api));
      await tester.pumpAndSettle();

      expect(find.text('Vehicle Availability'), findsOneWidget);

      await tester.tap(find.text('Yes, I have a vehicle'));
      await tester.pumpAndSettle();

      expect(find.text(_transportErrorText), findsOneWidget);
      expect(find.text('Yes, I have a vehicle'), findsOneWidget);
      expect(api.vehicleAnswers, [true]);
      await _settleSnackbar(tester);

      await tester.tap(find.text('Yes, I have a vehicle'));
      await tester.pumpAndSettle();

      expect(api.vehicleAnswers, [true, true]);
      expect(find.text('Yes, I have a vehicle'), findsNothing);
    });

    testWidgets('NGO: answering "No" persists an explicit false, not null',
        (tester) async {
      final api = _FakeApi(profile: _ngoProfile());
      _tallScreen(tester);
      await tester.pumpWidget(_appWithState(const NgoDashboardScreen(), api));
      await tester.pumpAndSettle();

      await tester.tap(find.text("No, I don't"));
      await tester.pumpAndSettle();

      expect(api.vehicleAnswers, [false]);
      expect(find.text('Vehicle Availability'), findsNothing);
    });
  });

  group('My Claims empty state', () {
    testWidgets(
        'restores persisted claim details and verified provider contact',
        (tester) async {
      final api = _FakeApi(profile: _ngoProfile())
        ..claims = [
          {
            'status': 'accepted',
            'donation': {
              'id': 'donation-1',
              'food_name': 'Rice meals',
              'food_category': 'prepared_meals',
              'quantity': 12,
              'servings': 24,
              'status': 'claimed',
              'pickup_deadline': '2026-10-14T12:00:00Z',
              'expiry_time': '2026-10-14T13:00:00Z',
              'pickup_address': '12 Main Road, Pune',
              'provider': {
                'organization_name': 'Verified Kitchen',
                'phone': '+91 8830392843',
                'verified': true,
              },
            },
          },
        ];
      _tallScreen(tester);
      await tester.pumpWidget(_appWithState(const NgoDashboardScreen(), api));
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(
          of: find.byType(BottomNavigationBar), matching: find.text('Claims')));
      await tester.pumpAndSettle();

      expect(find.text('Rice meals'), findsOneWidget);
      expect(find.text('Verified Kitchen'), findsOneWidget);
      await tester.tap(find.text('View claim details'));
      await tester.pumpAndSettle();

      expect(find.text('Provider / restaurant'), findsOneWidget);
      expect(find.text('12 Main Road, Pune'), findsOneWidget);
      expect(find.text('+91 8830392843'), findsOneWidget);
      expect(find.text('Claim status'), findsOneWidget);
      expect(find.text('accepted'), findsOneWidget);
    });

    testWidgets(
        'is centered vertically and horizontally in the available content area',
        (tester) async {
      final api = _FakeApi(profile: _ngoProfile());
      _tallScreen(tester);
      await tester.pumpWidget(_appWithState(const NgoDashboardScreen(), api));
      await tester.pumpAndSettle();

      // Navigate to the claims tab through the real bottom navigation.
      await tester.tap(find.descendant(
          of: find.byType(BottomNavigationBar), matching: find.text('Claims')));
      await tester.pumpAndSettle();

      const message = 'No active claims yet. Claim a donation from Find Food.';
      expect(find.text(message), findsOneWidget);

      // The content block (icon + text) must sit in the MIDDLE of the area
      // the EmptyState is given — both axes.
      final stateRect = tester.getRect(find.byType(EmptyState));
      final blockRect = tester.getRect(find.descendant(
          of: find.byType(EmptyState), matching: find.byType(Column)));

      expect((blockRect.center.dy - stateRect.center.dy).abs(), lessThan(24.0),
          reason: 'empty state must be vertically centered in the page');
      expect((blockRect.center.dx - stateRect.center.dx).abs(), lessThan(24.0),
          reason: 'empty state must be horizontally centered in the page');
    });

    testWidgets('EmptyState centers itself in any bounded area',
        (tester) async {
      await tester.pumpWidget(_app(const SizedBox(
        key: Key('bounds'),
        height: 500,
        child: EmptyState(
          icon: Icons.assignment_outlined,
          message: 'No active claims yet. Claim a donation from Find Food.',
        ),
      )));

      final outer = tester.getRect(find.byKey(const Key('bounds')));
      final block = tester.getRect(find.descendant(
          of: find.byType(EmptyState), matching: find.byType(Column)));

      expect((block.center.dy - outer.center.dy).abs(), lessThan(24.0),
          reason: 'empty state must be vertically centered');
      expect((block.center.dx - outer.center.dx).abs(), lessThan(24.0),
          reason: 'empty state must be horizontally centered');
    });
  });

  group('Ranked NGO donation offers', () {
    testWidgets('renders the persisted distance and avoids an edit CTA at 100%',
        (tester) async {
      final api = _FakeApi(profile: _completeNgoProfile(verified: true));
      const offer = {
        'status': 'pending',
        'candidate_rank': 1,
        'donation': {'food_name': 'Vegetable meals'},
        'ranked_candidate': {
          'final_score': 82.0,
          'score_details': {
            'distance_km': 1.55,
            'distance_source': 'straight_line',
          },
        },
      };
      _tallScreen(tester);
      await tester.pumpWidget(_appWithState(
        const MatchScoreCard(offer: offer),
        api,
      ));
      await tester.pumpAndSettle();

      expect(find.text('1.6 km straight-line'), findsOneWidget);
      expect(find.textContaining('Complete Profile'), findsNothing);
      expect(find.textContaining('Edit Profile'), findsNothing);
    });

    group('NGO donation claims', () {
      testWidgets('keeps a pending claim distinct from claimed donation state',
          (tester) async {
        final api = _FakeApi(profile: _completeNgoProfile(verified: true))
          ..donations = [
            {
              'id': 'donation-open',
              'food_name': 'Fresh vegetables',
              'food_category': 'produce',
              'quantity': 5,
              'unit': 'kg',
              'servings': 20,
              'status': 'available',
              'expiry_time': DateTime.now()
                  .add(const Duration(hours: 2))
                  .toIso8601String(),
            },
          ];
        _tallScreen(tester);
        await tester.pumpWidget(_appWithState(const NgoDashboardScreen(), api));
        await tester.pumpAndSettle();

        await tester.tap(find.text('CLAIM').first);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Confirm'));
        await tester.pumpAndSettle();

        expect(api.claimRequests, hasLength(1));
        expect(api.claims.single['status'], 'pending');
        expect(api.donations.single['status'], 'available');
        expect(find.textContaining('Claim request submitted'), findsOneWidget);
        expect(find.byType(ClaimedDonationDashboard), findsNothing);
        expect(find.text('Available Donations'), findsOneWidget);
      });
    });

    testWidgets('shows persisted score and accepts a live offer through API',
        (tester) async {
      final profile = _ngoProfile()
        ..['profile'] = {
          ...(_ngoProfile()['profile'] as Map<String, dynamic>),
          'latitude': 18.53,
          'longitude': 73.86,
          'available_from': '07:00',
          'available_to': '22:00',
          'max_capacity_kg': 25,
          'preferred_food_types': ['Cooked Meals'],
          'dietary_preferences': ['vegetarian'],
          'verified': true,
        }
        ..['profile_completion'] = {
          'role': 'ngo',
          'complete': true,
          'completed_fields': 11,
          'total_fields': 11,
          'percentage': 100,
          'missing_fields': <String>[],
          'verified': true,
          'matching_reason': 'Profile complete.',
        };
      final api = _FakeApi(profile: profile)
        ..ngoOffers = [
          {
            'id': 'offer-1',
            'candidate_rank': 1,
            'status': 'pending',
            'offer_expires_at': DateTime.now()
                .add(const Duration(minutes: 4))
                .toIso8601String(),
            'donation': {
              'food_name': 'Fresh bread',
              'food_category': 'bakery',
              'quantity': 8,
              'unit': 'kg',
              'pickup_address': '12 Main Road, Pune',
            },
            'ranked_candidate': {
              'final_score': 87,
              'score_details': {
                'distance_km': 3.2,
                'distance_source': 'road',
              },
            },
          },
        ];
      _tallScreen(tester);
      await tester.pumpWidget(_appWithState(const NgoDashboardScreen(), api));
      await tester.pumpAndSettle();

      expect(find.text('Donation Offers'), findsOneWidget);
      expect(find.text('Fresh bread'), findsOneWidget);
      expect(find.text('Pickup: 12 Main Road, Pune'), findsOneWidget);
      expect(find.text('Match score: 87.0%'), findsNWidgets(2));
      expect(find.text('3.2 km driving'), findsNWidgets(2));
      expect(
        find.textContaining('Scores are calculated for eligible NGOs'),
        findsNothing,
      );
      expect(find.text('Accept offer'), findsOneWidget);

      await tester.tap(find.text('Accept offer'));
      await tester.pumpAndSettle();

      expect(api.offerResponses, [('offer-1', 'accepted')]);
      expect(find.text('Offer accepted. The donation is now in My Claims.'),
          findsOneWidget);
    });

    testWidgets('refreshes persisted offers to show the next ranked NGO offer',
        (tester) async {
      final api = _FakeApi(profile: _ngoProfile());
      _tallScreen(tester);
      await tester.pumpWidget(_appWithState(const NgoDashboardScreen(), api));
      await tester.pumpAndSettle();
      expect(api.ngoOfferReads, 1);
      expect(find.text('Next NGO offer'), findsNothing);

      api.ngoOffers = [
        {
          'id': 'offer-next',
          'candidate_rank': 2,
          'status': 'pending',
          'offer_expires_at':
              DateTime.now().add(const Duration(minutes: 4)).toIso8601String(),
          'donation': {
            'food_name': 'Next NGO offer',
            'food_category': 'cooked',
            'quantity': 3,
            'unit': 'kg',
          },
          'ranked_candidate': {
            'final_score': 81,
            'score_details': {
              'distance_km': 1.8,
              'distance_source': 'straight_line',
            },
          },
        },
      ];
      await tester.pump(const Duration(seconds: 30));
      await tester.pumpAndSettle();

      expect(api.ngoOfferReads, 2);
      expect(find.text('Next NGO offer'), findsOneWidget);
      expect(find.text('Match score: 81.0%'), findsNWidgets(2));
      expect(find.text('1.8 km straight-line'), findsNWidgets(2));
    });

    testWidgets('does not offer a response action after the deadline',
        (tester) async {
      final api = _FakeApi(profile: _ngoProfile())
        ..ngoOffers = [
          {
            'id': 'offer-expired',
            'candidate_rank': 1,
            'status': 'pending',
            'offer_expires_at': DateTime.now()
                .subtract(const Duration(minutes: 1))
                .toIso8601String(),
            'donation': {'food_name': 'Expired offer'},
            'ranked_candidate': {'final_score': 75},
          },
        ];
      _tallScreen(tester);
      await tester.pumpWidget(_appWithState(const NgoDashboardScreen(), api));
      await tester.pumpAndSettle();

      expect(find.text('Offer deadline passed'), findsOneWidget);
      expect(find.text('Accept offer'), findsNothing);
      expect(find.text('Decline'), findsNothing);
      expect(api.offerResponses, isEmpty);
    });
  });

  testWidgets('provider opens details with scores and persisted offer state',
      (tester) async {
    final api = _FakeApi(profile: _providerProfile())
      ..donations = [
        {
          'id': 'donation-match',
          'food_name': 'Vegetable meals',
          'food_category': 'prepared_meals',
          'quantity': 10,
          'servings': 20,
          'status': 'available',
          'pickup_address': '12 Main Road, Pune',
          'pickup_deadline':
              DateTime.now().add(const Duration(hours: 1)).toIso8601String(),
          'expiry_time':
              DateTime.now().add(const Duration(hours: 2)).toIso8601String(),
        },
      ]
      ..persistedDonationOffers = {
        'matching_state': 'active',
        'current_offer': {
          'status': 'pending',
          'candidate_rank': 1,
          'offer_expires_at':
              DateTime.now().add(const Duration(minutes: 4)).toIso8601String(),
        },
        'ranked_candidates': [
          {
            'match_rank': 1,
            'final_score': 88.4,
            'score_details': {
              'distance_km': 2.5,
              'distance_source': 'road',
              'distance_score': 90,
              'quantity_fit_score': 80,
            },
            'ngo': {'organization_name': 'Trusted NGO', 'city': 'Pune'},
          },
          {
            'match_rank': 2,
            'final_score': 70,
            'score_details': {
              'distance_km': null,
              'distance_source': null,
            },
            'ngo': {'organization_name': 'Legacy NGO', 'city': 'Pune'},
          },
        ],
      };
    _tallScreen(tester);
    await tester
        .pumpWidget(_appWithState(const ProviderDashboardScreen(), api));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(
        of: find.byType(BottomNavigationBar),
        matching: find.text('Donations')));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Matched NGOs'));
    await tester.pumpAndSettle();

    expect(api.persistedDonationOfferReads, 1);
    expect(api.manualMatchCalls, 0);
    expect(find.text('Trusted NGO'), findsOneWidget);
    expect(find.text('2.5 km driving'), findsWidgets);
    expect(find.text('Legacy NGO'), findsOneWidget);
    expect(find.text('Distance unavailable'), findsOneWidget);
    expect(find.text('Match score: 88.4%'), findsOneWidget);
    expect(find.text('Matching rank #1'), findsOneWidget);
    expect(find.textContaining('Five-minute offer sent to ranked NGO #1'),
        findsOneWidget);
    expect(find.text('Donation details'), findsOneWidget);
    expect(find.text('Freshness'), findsOneWidget);
    expect(find.text('Not available'), findsOneWidget);

    await tester.tap(find.text('Trusted NGO'));
    await tester.pumpAndSettle();
    expect(find.textContaining('saved candidate'), findsOneWidget);
    expect(find.text('2.5 km driving'), findsWidgets);
    expect(find.text('Distance score: 90 / 100'), findsOneWidget);
  });

  testWidgets('persisted backend rank order is preserved in provider details',
      (tester) async {
    final api = _FakeApi(profile: _providerProfile())
      ..persistedDonationOffers = {
        'matching_state': 'active',
        'current_offer': {
          'status': 'pending',
          'candidate_rank': 1,
          'offer_expires_at':
              DateTime.now().add(const Duration(minutes: 4)).toIso8601String(),
        },
        'ranked_candidates': [
          {
            'match_rank': 1,
            'final_score': 72.5,
            'score_details': {
              'distance_km': 4.1,
              'distance_source': 'road',
              'distance_score': 80,
              'quantity_fit_score': 70,
              'dietary_compatibility_score': 100,
              'pickup_time_feasibility_score': 90,
              'restaurant_reliability_score': 60,
            },
            'ngo': {
              'organization_name': 'Second-ranked NGO',
              'verified': true,
              'food_capacity': 50,
              'preferred_food_types': ['veg'],
              'available_from': '09:00',
              'available_to': '18:00',
            },
          },
          {
            'match_rank': 2,
            'final_score': 94,
            'score_details': {
              'distance_km': 2.4,
              'distance_source': 'straight_line',
              'distance_score': 95,
              'quantity_fit_score': 90,
              'dietary_compatibility_score': 100,
              'pickup_time_feasibility_score': 90,
              'restaurant_reliability_score': 80,
            },
            'ngo': {'organization_name': 'Top-scoring NGO', 'verified': true},
          },
        ],
      };
    final donation = Donation.fromBackend({
      'id': 'donation-live',
      'food_name': 'Jeera Rice',
      'food_category': 'prepared_meals',
      'quantity': 4,
      'unit': 'kg',
      'servings': 8,
      'pickup_address': '12 Main Road, Pune',
      'status': 'available',
    });
    _tallScreen(tester);
    await tester.pumpWidget(_appWithState(
      ProviderDonationMatchDetailsScreen(donation: donation),
      api,
    ));
    await tester.pumpAndSettle();

    final first = tester.getTopLeft(find.text('Second-ranked NGO'));
    final second = tester.getTopLeft(find.text('Top-scoring NGO'));
    expect(first.dy, lessThan(second.dy));
    expect(find.text('Match score: 94.0%'), findsOneWidget);
    expect(find.text('Match score: 72.5%'), findsOneWidget);
    expect(find.text('2.4 km straight-line'), findsOneWidget);
    expect(find.text('4.1 km driving'), findsOneWidget);
    expect(api.manualMatchCalls, 0);

    await tester.tap(find.text('Top-scoring NGO'));
    await tester.pumpAndSettle();
    expect(find.textContaining('saved candidate'), findsOneWidget);
    expect(find.text('Match score: 94.0%'), findsNWidgets(2));

    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Escalate'));
    await tester.pumpAndSettle();
    expect(api.rankedEscalationCalls, 1);
    expect(find.textContaining('still within its five-minute'), findsOneWidget);
  });

  testWidgets('escalate action is disabled without an active pending offer',
      (tester) async {
    final api = _FakeApi(profile: _providerProfile());
    final donation = Donation.fromBackend({
      'id': 'donation-no-offer',
      'food_name': 'Jeera Rice',
      'food_category': 'prepared_meals',
      'quantity': 4,
      'unit': 'kg',
      'servings': 8,
      'status': 'available',
    });

    _tallScreen(tester);
    await tester.pumpWidget(_appWithState(
      ProviderDonationMatchDetailsScreen(donation: donation),
      api,
    ));
    await tester.pumpAndSettle();

    final button = tester.widget<OutlinedButton>(
      find.ancestor(
        of: find.text('Escalate'),
        matching: find.byType(OutlinedButton),
      ),
    );
    expect(button.onPressed, isNull);
    expect(
      find.text(
        'Escalation is available after a ranked NGO has an active pending offer.',
      ),
      findsOneWidget,
    );
    expect(api.rankedEscalationCalls, 0);
  });

  testWidgets('no completed NGO profiles is an honest matching empty state',
      (tester) async {
    final api = _FakeApi(profile: _providerProfile())
      ..persistedDonationOffers = {
        'matching_state': 'no_matching_profiles',
        'matching_reason':
            'No completed NGO profiles are available for matching yet.',
        'ranked_candidates': <dynamic>[],
      };
    final donation = Donation.fromBackend({
      'id': 'donation-no-candidates',
      'food_name': 'Jeera Rice',
      'food_category': 'prepared_meals',
      'quantity': 4,
      'unit': 'kg',
      'servings': 8,
      'status': 'available',
    });

    _tallScreen(tester);
    await tester.pumpWidget(_appWithState(
      ProviderDonationMatchDetailsScreen(donation: donation),
      api,
    ));
    await tester.pumpAndSettle();

    expect(
        find.text('No completed NGO profiles are available for matching yet.'),
        findsOneWidget);
    expect(api.manualMatchCalls, 0);
    expect(
      find.text('The AI service is temporarily unavailable. Please try again.'),
      findsNothing,
    );
  });

  testWidgets('insufficient matching data remains distinct from no candidates',
      (tester) async {
    final api = _FakeApi(profile: _providerProfile())
      ..persistedDonationOffers = {
        'matching_state': 'not_started',
        'matching_reason':
            'No eligible ranking has been saved yet. Matching runs automatically.',
        'ranked_candidates': <dynamic>[],
      };
    final donation = Donation.fromBackend({
      'id': 'donation-insufficient-data',
      'food_name': 'Jeera Rice',
      'food_category': 'prepared_meals',
      'quantity': 4,
      'unit': 'kg',
      'servings': 8,
      'status': 'available',
    });

    _tallScreen(tester);
    await tester.pumpWidget(_appWithState(
      ProviderDonationMatchDetailsScreen(donation: donation),
      api,
    ));
    await tester.pumpAndSettle();

    expect(find.textContaining('Matching runs automatically'), findsOneWidget);
    expect(find.text('No matching NGO is available for this pickup.'),
        findsNothing);
    expect(
      find.text('The AI service is temporarily unavailable. Please try again.'),
      findsNothing,
    );
  });

  testWidgets('AI upstream failure is mapped to a service error',
      (tester) async {
    final api = _FakeApi(profile: _providerProfile())
      ..persistedDonationOfferError = const ApiException(
        503,
        'Unable to load saved rankings.',
      );
    final donation = Donation.fromBackend({
      'id': 'donation-ai-failure',
      'food_name': 'Jeera Rice',
      'food_category': 'prepared_meals',
      'quantity': 4,
      'unit': 'kg',
      'servings': 8,
      'status': 'available',
    });

    _tallScreen(tester);
    await tester.pumpWidget(_appWithState(
      ProviderDonationMatchDetailsScreen(donation: donation),
      api,
    ));
    await tester.pumpAndSettle();

    expect(find.text('Unable to load saved rankings.'), findsOneWidget);
    expect(
      find.text(
        'Food safety verification is temporarily unavailable. Please try again.',
      ),
      findsNothing,
    );
  });

  testWidgets('non-AI 503 detail is not mislabeled as an AI outage',
      (tester) async {
    final api = _FakeApi(profile: _providerProfile())
      ..persistedDonationOfferError = const ApiException(
        503,
        'Eligible NGOs were matched, but their ranked offers could not be saved.',
      );
    final donation = Donation.fromBackend({
      'id': 'donation-save-failure',
      'food_name': 'Jeera Rice',
      'food_category': 'prepared_meals',
      'quantity': 4,
      'unit': 'kg',
      'servings': 8,
      'status': 'available',
    });

    _tallScreen(tester);
    await tester.pumpWidget(_appWithState(
      ProviderDonationMatchDetailsScreen(donation: donation),
      api,
    ));
    await tester.pumpAndSettle();

    expect(
      find.text(
        'Eligible NGOs were matched, but their ranked offers could not be saved.',
      ),
      findsOneWidget,
    );
    expect(
      find.text('The AI service is temporarily unavailable. Please try again.'),
      findsNothing,
    );
  });

  group('Provider claimed donation details', () {
    testWidgets('shows backend claim, NGO display name, and saved address',
        (tester) async {
      final api = _FakeApi(profile: _providerProfile())
        ..providerClaims = [
          {
            'donation_id': 'donation-1',
            'status': 'accepted',
            'ngo': {
              'organization_name': 'Hope Foundation',
              'city': 'Pune',
            },
          },
        ];
      final donation = Donation.fromBackend({
        'id': 'donation-1',
        'food_name': 'Jeera Rice',
        'food_category': 'prepared_meals',
        'quantity': 4,
        'servings': 8,
        'pickup_address': '12 Main Road, Pune',
        'status': 'claimed',
      });
      _tallScreen(tester);
      await tester.pumpWidget(_appWithState(
          ProviderClaimedDonationScreen(donation: donation), api));
      await tester.pumpAndSettle();

      expect(find.text('Jeera Rice'), findsOneWidget);
      expect(find.text('Hope Foundation'), findsOneWidget);
      expect(find.text('Pune'), findsOneWidget);
      expect(find.textContaining('Claim status: Accepted'), findsOneWidget);
      expect(find.text('12 Main Road, Pune'), findsOneWidget);
      expect(find.text('donation-1'), findsNothing);
    });

    testWidgets('uses an honest fallback when NGO display name is missing',
        (tester) async {
      final api = _FakeApi(profile: _providerProfile())
        ..providerClaims = [
          {'donation_id': 'donation-2', 'status': 'accepted', 'ngo': {}},
        ];
      final donation = Donation.fromBackend({
        'id': 'donation-2',
        'food_name': 'Rice meals',
        'status': 'claimed',
      });
      _tallScreen(tester);
      await tester.pumpWidget(_appWithState(
          ProviderClaimedDonationScreen(donation: donation), api));
      await tester.pumpAndSettle();

      expect(find.text('Not provided'), findsWidgets);
      expect(find.textContaining('Claim status: Accepted'), findsOneWidget);
    });

    test('missing freshness is labelled as unavailable, not as a dash', () {
      final donation = Donation.fromBackend({
        'id': 'donation-3',
        'food_name': 'Rice meals',
      });

      expect(donation.freshnessLabel, 'Not available');
    });
  });
}
