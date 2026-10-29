import 'dart:io';

import 'package:firebase_core_platform_interface/firebase_core_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:provider/provider.dart';

import 'package:sahaay/main.dart';
import 'package:sahaay/services/api_service.dart';
import 'package:sahaay/services/firebase_auth_service.dart';
import 'package:sahaay/services/permission_service.dart';

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

/// Scripted backend. Every method Edit Profile touches is overridden, so no
/// request ever leaves the test process.
class _FakeApi extends ApiService {
  _FakeApi({this.profile, this.profileError});

  /// A GET /profile response. The role join may be an object or a one-row list,
  /// depending on the PostgREST relationship shape.
  Map<String, dynamic>? profile;
  Object? profileError;
  Map<String, dynamic> contactVerification = {
    'email_verified': true,
    'phone_verified': false,
    'phone_auth_configured': false,
  };

  Map<String, dynamic>? lastPatch;
  final List<String> uploadedPhotoPaths = [];

  @override
  Future<Map<String, dynamic>> getProfile() async {
    final error = profileError;
    if (error != null) throw error;
    return profile!;
  }

  @override
  Future<Map<String, dynamic>> getContactVerification() async =>
      contactVerification;

  @override
  Future<Map<String, dynamic>> updateProfile(
      Map<String, dynamic> payload) async {
    lastPatch = payload;
    return {'ok': true};
  }

  @override
  Future<String> uploadProfilePhoto(File file) async {
    uploadedPhotoPaths.add(file.path);
    return 'https://cdn.test/profile-photos/confirmed.png';
  }
}

/// Real GET /profile payload for the live PROVIDER account
/// (panchalgouri0901) — `description` is NULL, exactly like an existing
/// profile that never filled one in.
Map<String, dynamic> _providerProfile() => {
      'id': 'c8032556-d315-4f6c-be7e-0608c6a683f7',
      'firebase_uid': 'j6Y5Fe5scQNwaSRxqfMMMQraJxa2',
      'full_name': 'Gouri Panchal',
      'email': 'panchalgouri0901@gmail.com',
      'phone': '8830392843',
      'role': 'provider',
      'profile_image_url': null,
      'profile': {
        'id': '546df4e7-b9d5-4f7a-ae51-825867aa08e6',
        'user_id': 'c8032556-d315-4f6c-be7e-0608c6a683f7',
        'organization_name': 'Shree krishna veg',
        'organization_type': 'restaurant',
        'phone': '8830392843',
        'address': 'VadgaonSheri',
        'city': 'Pune',
        'description': null,
        'latitude': null,
        'longitude': null,
        'vehicle_available': null,
        'verified': false,
      },
    };

/// Real GET /profile payload for the live NGO account (panchalgouri2008),
/// with a stored description so loading one is exercised too.
Map<String, dynamic> _ngoProfile() => {
      'id': '0938057b-f943-4100-9950-c02bff40a4bb',
      'firebase_uid': 'fd5V0FU78eQ57WIp3AxM6DPg7sh2',
      'full_name': 'Gouri',
      'email': 'panchalgouri2008@gmail.com',
      'phone': '8830392843',
      'role': 'ngo',
      'profile_image_url': null,
      'profile': {
        'id': '6c4d5e0c-d3d1-45b4-88bf-50d690efb4a5',
        'user_id': '0938057b-f943-4100-9950-c02bff40a4bb',
        'organization_name': 'Old age home',
        'phone': '8830392843',
        'address': 'VadgaonSheri',
        'city': 'Pune',
        'registration_number': '4545',
        'description': 'A safe home for senior citizens.',
        'food_capacity': 50,
        'preferred_food_types': ['Cooked Meals', 'Rice'],
        'dietary_preferences': ['vegetarian'],
        'vehicle_available': false,
        'max_capacity_kg': 25,
        'available_from': '08:00',
        'available_to': '18:00',
        'latitude': null,
        'longitude': null,
      },
    };

/// AppState wired to the scripted API, exactly as production wires it.
class _FakeAppState extends AppState {
  _FakeAppState(this._api) : super(FirebaseAuthService());
  final ApiService _api;

  @override
  ApiService get api => _api;
}

Widget _app(Widget child) => MaterialApp(
      theme: sahaayLightTheme,
      home: child,
    );

Widget _appWithState(Widget child, _FakeApi api) =>
    ChangeNotifierProvider<AppState>.value(
      value: _FakeAppState(api),
      child: _app(child),
    );

/// Opens Settings (the real navigation path) and taps "Edit profile details",
/// exactly like the user does. Uses a phone-tall viewport so the whole form
/// (which lives in a ListView) is laid out at once.
Future<void> _openEditProfile(
  WidgetTester tester,
  UserRole role, {
  double width = 1080,
  double height = 3600,
}) async {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
      _appWithState(SettingsScreen(role: role, name: 'Test Org'), _lastApi!));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Edit profile details'));
  await tester.pumpAndSettle();
}

/// The last _FakeApi handed to a screen (set by each test before pumping).
_FakeApi? _lastApi;

/// Valid 1x1 PNG so Image.file decode succeeds in the preview test.
final List<int> _tinyPng = <int>[
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
  0x00,
  0x00,
  0x00,
  0x0D,
  0x49,
  0x48,
  0x44,
  0x52,
  0x00,
  0x00,
  0x00,
  0x01,
  0x00,
  0x00,
  0x00,
  0x01,
  0x08,
  0x06,
  0x00,
  0x00,
  0x00,
  0x1F,
  0x15,
  0xC4,
  0x89,
  0x00,
  0x00,
  0x00,
  0x0A,
  0x49,
  0x44,
  0x41,
  0x54,
  0x78,
  0x9C,
  0x63,
  0x00,
  0x01,
  0x00,
  0x00,
  0x05,
  0x00,
  0x01,
  0x0D,
  0x0A,
  0x2D,
  0xB4,
  0x00,
  0x00,
  0x00,
  0x00,
  0x49,
  0x45,
  0x4E,
  0x44,
  0xAE,
  0x42,
  0x60,
  0x82,
];

class _FakeImagePickerPlatform extends ImagePickerPlatform {
  ImageSource? lastSource;
  XFile? result;

  @override
  Future<XFile?> getImageFromSource({
    required ImageSource source,
    ImagePickerOptions options = const ImagePickerOptions(),
  }) async {
    lastSource = source;
    return result;
  }
}

class _FakeGateway implements PermissionGateway {
  @override
  Future<PermissionOutcome> status(AppPermission permission) async =>
      PermissionOutcome.granted;

  @override
  Future<PermissionOutcome> request(AppPermission permission) async =>
      PermissionOutcome.granted;

  @override
  Future<bool> isLocationServiceEnabled() async => true;

  @override
  Future<bool> openLocationSettings() async => true;

  @override
  Future<bool> openAppSettings() async => true;
}

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    FirebasePlatform.instance = _FakeFirebaseCorePlatform();
  });

  tearDown(() {
    // Never let a test seam leak into another test.
    permissionServiceOverride = null;
  });

  group('Edit Profile — existing data is displayed (the "blank screen" bug)',
      () {
    testWidgets(
        'shows phone linking when backend phone verification is enabled',
        (tester) async {
      final api = _FakeApi(profile: _providerProfile())
        ..contactVerification = {
          'email_verified': true,
          'phone_verified': false,
          'phone_auth_configured': true,
        };
      _lastApi = api;
      await _openEditProfile(tester, UserRole.provider);

      expect(
        find.text(
          'Link a verified phone to accept deliveries and complete protected handover actions.',
        ),
        findsOneWidget,
      );
      expect(find.text('VERIFY PHONE NUMBER'), findsOneWidget);
    });

    testWidgets('profile sections stay readable on a narrow screen',
        (tester) async {
      final api = _FakeApi(profile: _providerProfile());
      _lastApi = api;
      await _openEditProfile(
        tester,
        UserRole.provider,
        width: 320,
        height: 2400,
      );

      expect(tester.takeException(), isNull);
      expect(find.text('Personal information'), findsOneWidget);
      expect(find.text('Organization profile'), findsOneWidget);
      expect(
        tester.getRect(find.byType(Form)).right,
        lessThanOrEqualTo(320),
      );
    });

    testWidgets('provider: every field is prefilled from GET /profile',
        (tester) async {
      final api = _FakeApi(profile: _providerProfile());
      _lastApi = api;
      await _openEditProfile(tester, UserRole.provider);

      // The screen must show the REAL account data, not an empty form.
      expect(find.text('Gouri Panchal'), findsOneWidget);
      expect(find.text('Shree krishna veg'), findsNWidgets(2));
      expect(find.text('VadgaonSheri'), findsOneWidget);
      expect(find.text('Pune'), findsOneWidget);
      expect(find.text('8830392843'), findsWidgets);
      // A profile that never filled a description still renders normally,
      // with an empty (not missing) description field.
      expect(find.text('Description'), findsOneWidget);
      expect(find.text('SAVE CHANGES'), findsOneWidget);
      expect(find.byType(TextFormField), findsWidgets);
    });

    testWidgets('provider role profile also loads from a joined row list',
        (tester) async {
      final profile = _providerProfile();
      profile['profile'] = [profile['profile']];
      final api = _FakeApi(profile: profile);
      _lastApi = api;
      await _openEditProfile(tester, UserRole.provider);

      expect(find.text('Gouri Panchal'), findsOneWidget);
      expect(find.text('Shree krishna veg'), findsNWidgets(2));
      expect(find.text('VadgaonSheri'), findsOneWidget);
      expect(find.text('Pune'), findsOneWidget);
    });

    testWidgets('NGO: every field is prefilled, including description',
        (tester) async {
      final api = _FakeApi(profile: _ngoProfile());
      _lastApi = api;
      await _openEditProfile(tester, UserRole.ngo);

      expect(find.text('Gouri'), findsOneWidget);
      expect(find.text('Old age home'), findsNWidgets(2));
      expect(find.text('VadgaonSheri'), findsOneWidget);
      expect(find.text('4545'), findsOneWidget);
      expect(find.text('A safe home for senior citizens.'), findsOneWidget);
      expect(find.text('Registration number'), findsOneWidget);
    });

    testWidgets(
        'a failed load renders a retryable error state, never a blank page',
        (tester) async {
      final api = _FakeApi(
          profile: _providerProfile(),
          profileError: const ApiException(500, 'boom'));
      _lastApi = api;
      await _openEditProfile(tester, UserRole.provider);

      // 500 maps to a clear message + Retry, not a blank/white screen.
      expect(find.text('Something went wrong on the server. Please try again.'),
          findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      expect(find.text('SAVE CHANGES'), findsNothing);

      // Retry once the backend is healthy again -> the form appears.
      api.profileError = null;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.text('Shree krishna veg'), findsNWidgets(2));
      expect(find.text('SAVE CHANGES'), findsOneWidget);
    });
  });

  group('Edit Profile — description round-trips through PATCH /profile', () {
    testWidgets('provider description edit is sent in the PATCH payload',
        (tester) async {
      final api = _FakeApi(profile: _providerProfile());
      _lastApi = api;
      await _openEditProfile(tester, UserRole.provider);

      await tester.enterText(find.widgetWithText(TextFormField, 'Description'),
          'Fresh rotis donated every evening.');
      await tester.tap(find.text('SAVE CHANGES'));
      await tester.pumpAndSettle();

      expect(api.lastPatch, isNotNull);
      final provider =
          Map<String, dynamic>.from(api.lastPatch!['provider'] as Map);
      expect(provider['description'], 'Fresh rotis donated every evening.');
      // Unrelated fields ride along unchanged.
      expect(provider['organization_name'], 'Shree krishna veg');
      expect(api.lastPatch!['full_name'], 'Gouri Panchal');
      // Save returns to Settings (navigation popped, not a dead end).
      expect(find.text('Edit profile details'), findsOneWidget);
    });

    testWidgets('NGO description edit is sent in the PATCH payload',
        (tester) async {
      final api = _FakeApi(profile: _ngoProfile());
      _lastApi = api;
      await _openEditProfile(tester, UserRole.ngo);

      await tester.enterText(find.widgetWithText(TextFormField, 'Description'),
          'We cook 200 meals daily for the elderly.');
      await tester.tap(find.text('SAVE CHANGES'));
      await tester.pumpAndSettle();

      expect(api.lastPatch, isNotNull);
      final ngo = Map<String, dynamic>.from(api.lastPatch!['ngo'] as Map);
      expect(ngo['description'], 'We cook 200 meals daily for the elderly.');
      expect(ngo['registration_number'], '4545');
      expect(ngo['organization_name'], 'Old age home');
    });

    testWidgets('NGO matching preferences and vehicle edit are saved',
        (tester) async {
      final api = _FakeApi(profile: _ngoProfile());
      _lastApi = api;
      await _openEditProfile(tester, UserRole.ngo);

      final capacityField = tester.widget<AppInputField>(
        find.byWidgetPredicate(
          (widget) =>
              widget is AppInputField &&
              widget.label == 'Maximum donation amount (kg)',
        ),
      );
      expect(capacityField.controller.text, '25');
      expect(find.text('Opens: 8:00 AM'), findsOneWidget);
      expect(find.text('Closes: 6:00 PM'), findsOneWidget);
      expect(
        tester
            .widget<FilterChip>(find.widgetWithText(FilterChip, 'Rice'))
            .selected,
        isTrue,
      );
      expect(
        tester
            .widget<FilterChip>(
              find.widgetWithText(FilterChip, 'Vegetarian'),
            )
            .selected,
        isTrue,
      );
      expect(
        tester
            .widget<ChoiceChip>(
              find.widgetWithText(ChoiceChip, 'Unavailable'),
            )
            .selected,
        isTrue,
      );

      await tester.tap(find.widgetWithText(FilterChip, 'Rice'));
      await tester.tap(find.widgetWithText(FilterChip, 'Bread'));
      await tester.tap(find.widgetWithText(FilterChip, 'Vegan'));
      await tester.tap(find.widgetWithText(ChoiceChip, 'Available'));
      await tester.tap(find.text('SAVE CHANGES'));
      await tester.pumpAndSettle();

      final ngo = Map<String, dynamic>.from(api.lastPatch!['ngo'] as Map);
      expect(
        ngo['preferred_food_types'],
        containsAll(['Cooked Meals', 'Bread']),
      );
      expect(ngo['preferred_food_types'], isNot(contains('Rice')));
      expect(ngo['dietary_preferences'], containsAll(['vegetarian', 'vegan']));
      expect(ngo['vehicle_available'], isTrue);
    });

    testWidgets('clearing all NGO matching preferences is saved as null',
        (tester) async {
      final api = _FakeApi(profile: _ngoProfile());
      _lastApi = api;
      await _openEditProfile(tester, UserRole.ngo);

      await tester.tap(find.widgetWithText(FilterChip, 'Cooked Meals'));
      await tester.tap(find.widgetWithText(FilterChip, 'Rice'));
      await tester.tap(find.widgetWithText(FilterChip, 'Vegetarian'));
      await tester.tap(find.text('SAVE CHANGES'));
      await tester.pumpAndSettle();

      final ngo = Map<String, dynamic>.from(api.lastPatch!['ngo'] as Map);
      expect(ngo['preferred_food_types'], isNull);
      expect(ngo['dietary_preferences'], isNull);
    });
  });

  group('Edit Profile — profile picture (provider and NGO share the screen)',
      () {
    late Directory tempDir;
    late File picture;
    late ImagePickerPlatform originalPicker;
    late _FakeImagePickerPlatform picker;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('sahaay_profile_photo');
      picture = File('${tempDir.path}${Platform.pathSeparator}shot.png')
        ..writeAsBytesSync(_tinyPng);
      originalPicker = ImagePickerPlatform.instance;
      picker = _FakeImagePickerPlatform();
      ImagePickerPlatform.instance = picker;
      permissionServiceOverride = PermissionService(_FakeGateway());
    });

    tearDown(() {
      ImagePickerPlatform.instance = originalPicker;
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    });

    testWidgets(
        'sheet offers camera and gallery; gallery stages a preview WITHOUT uploading',
        (tester) async {
      final api = _FakeApi(profile: _providerProfile());
      _lastApi = api;
      picker.result = XFile(picture.path);
      await _openEditProfile(tester, UserRole.provider);

      await tester.tap(find.text('CHANGE PHOTO'));
      await tester.pumpAndSettle();

      // One shared photo-source sheet, both sources offered.
      expect(
          find.descendant(
              of: find.byType(BottomSheet),
              matching: find.text('Profile photo')),
          findsOneWidget);
      expect(find.text('Take Photo'), findsOneWidget);
      expect(find.text('Choose from Gallery'), findsOneWidget);

      await tester.tap(find.text('Choose from Gallery'));
      await tester.pumpAndSettle();

      expect(picker.lastSource, ImageSource.gallery);
      // Preview is staged, NOT uploaded yet.
      expect(find.text('Preview — not saved yet'), findsOneWidget);
      expect(find.text('UPLOAD PHOTO'), findsOneWidget);
      expect(api.uploadedPhotoPaths, isEmpty);
    });

    testWidgets('camera source goes through the permission layer and previews',
        (tester) async {
      final api = _FakeApi(profile: _ngoProfile());
      _lastApi = api;
      picker.result = XFile(picture.path);
      await _openEditProfile(tester, UserRole.ngo);

      await tester.tap(find.text('CHANGE PHOTO'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Take Photo'));
      await tester.pumpAndSettle();

      expect(picker.lastSource, ImageSource.camera);
      expect(find.text('Preview — not saved yet'), findsOneWidget);
      expect(api.uploadedPhotoPaths, isEmpty);
    });

    testWidgets(
        'confirming the preview uploads through the existing endpoint and persists the URL',
        (tester) async {
      final api = _FakeApi(profile: _providerProfile());
      _lastApi = api;
      picker.result = XFile(picture.path);
      await _openEditProfile(tester, UserRole.provider);

      await tester.tap(find.text('CHANGE PHOTO'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Choose from Gallery'));
      await tester.pumpAndSettle();
      expect(find.text('UPLOAD PHOTO'), findsOneWidget);

      await tester.tap(find.text('UPLOAD PHOTO'));
      await tester.pumpAndSettle();

      // Exactly one upload through the existing authenticated endpoint.
      expect(api.uploadedPhotoPaths, hasLength(1));
      // The pending state is consumed; the avatar now shows the SAVED URL.
      expect(find.text('Preview — not saved yet'), findsNothing);
      expect(find.text('UPLOAD PHOTO'), findsNothing);
      expect(find.text('CHANGE PHOTO'), findsOneWidget);
    });

    testWidgets('discard drops the preview without touching the backend',
        (tester) async {
      final api = _FakeApi(profile: _providerProfile());
      _lastApi = api;
      picker.result = XFile(picture.path);
      await _openEditProfile(tester, UserRole.provider);

      await tester.tap(find.text('CHANGE PHOTO'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Choose from Gallery'));
      await tester.pumpAndSettle();
      expect(find.text('Preview — not saved yet'), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(find.text('Preview — not saved yet'), findsNothing);
      expect(find.text('UPLOAD PHOTO'), findsNothing);
      expect(find.text('CHANGE PHOTO'), findsOneWidget);
      expect(api.uploadedPhotoPaths, isEmpty);
    });
  });
}
