import 'dart:ui' as ui;

import 'package:firebase_core_platform_interface/firebase_core_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:sahaay/main.dart';
import 'package:sahaay/services/firebase_auth_service.dart';

/// In-memory Firebase core so `FirebaseAuth.instance` resolves inside a widget
/// test with no real project, network call or platform channel. `currentUser`
/// stays null, so AppState sees no session and the splash must route to the
/// login screen.
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

void main() {
  setUpAll(() {
    FirebasePlatform.instance = _FakeFirebaseCorePlatform();
  });

  AppState freshState() => AppState(FirebaseAuthService());

  Widget withState(Widget home) => ChangeNotifierProvider<AppState>.value(
        value: freshState(),
        child: MaterialApp(theme: sahaayLightTheme, home: home),
      );

  Widget withLoginState(_LoginAppState state) =>
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: MaterialApp(theme: sahaayLightTheme, home: const LoginScreen()),
      );

  group('startup splash', () {
    testWidgets('launch shows the animated mark before any login UI',
        (WidgetTester tester) async {
      await tester.pumpWidget(withState(const SplashScreen()));

      // First frame: the splash is the only thing on screen.
      expect(find.byType(SplashScreen), findsOneWidget);
      expect(find.byType(LoginScreen), findsNothing);
      expect(find.text('Email'), findsNothing);
      expect(find.text('LOGIN'), findsNothing);

      // The animated mark is present and is the S-hand symbol only.
      expect(find.byType(SahaayLogo), findsOneWidget);
      final logo = tester.widget<SahaayLogo>(find.byType(SahaayLogo));
      expect(logo.showWordmark, isFalse,
          reason: 'splash must animate the S-hand mark, not the wordmark');
    });

    testWidgets('splash hands over to LoginScreen when signed out',
        (WidgetTester tester) async {
      await tester.pumpWidget(withState(const SplashScreen()));
      await tester.pumpAndSettle();

      expect(find.byType(SplashScreen), findsNothing);
      expect(find.byType(LoginScreen), findsOneWidget);
      expect(find.byType(RoleRouter), findsNothing);
    });

    testWidgets('the mark animates rather than sitting static',
        (WidgetTester tester) async {
      await tester.pumpWidget(withState(const SplashScreen()));

      // The grow phase is driven by a scale Transform wrapping the mark. Read the
      // matrix rather than the laid-out size, because a Transform does not
      // change its child's layout size. The wrappers sit above the mark, so
      // search within the splash: the translate has m11 == 1 and is skipped.
      double? scaleNow() {
        for (final t in tester.widgetList<Transform>(find.descendant(
            of: find.byType(SplashScreen), matching: find.byType(Transform)))) {
          final s = t.transform.storage[0];
          if (s != 1.0) return s;
        }
        return null;
      }

      await tester.pump(const Duration(milliseconds: 20));
      final early = scaleNow();
      await tester.pump(const Duration(milliseconds: 380));
      final grown = scaleNow();

      expect(early, isNotNull, reason: 'enter phase should start scaled down');
      expect(grown, isNotNull);
      expect(early, lessThan(1.0), reason: 'enter phase should start small');
      expect(grown, greaterThan(early!),
          reason: 'the mark should grow into the silhouette');
    });
  });

  group('login screen is minimal', () {
    testWidgets('shows every element in the required order',
        (WidgetTester tester) async {
      await tester.pumpWidget(
          MaterialApp(theme: sahaayLightTheme, home: const LoginScreen()));

      expect(find.byType(SahaayLogo), findsOneWidget);
      expect(find.text('Email'), findsOneWidget);
      expect(find.text('Password'), findsOneWidget);
      expect(find.text('Forgot password?'), findsOneWidget);
      expect(find.text('LOGIN'), findsOneWidget);
      expect(find.text('Continue with Google'), findsOneWidget);
      expect(find.text("Don't have an account?"), findsOneWidget);
      expect(find.text('Register'), findsOneWidget);

      // The reference layout is positional: mark, email, password, forgot,
      // LOGIN, Google, register. Assert the vertical order so a later
      // rearrangement cannot silently break it.
      final order = <double>[];
      for (final f in <Finder>[
        find.byType(SahaayLogo),
        find.widgetWithText(AppInputField, 'Email'),
        find.widgetWithText(AppInputField, 'Password'),
        find.text('Forgot password?'),
        find.text('LOGIN'),
        find.text('Continue with Google'),
        find.text('Register'),
      ]) {
        expect(f, findsOneWidget, reason: 'element missing from the layout');
        order.add(tester.getCenter(f).dy);
      }
      for (var i = 1; i < order.length; i++) {
        expect(order[i], greaterThan(order[i - 1]),
            reason: 'layout element $i is out of order');
      }
    });

    testWidgets('no old welcome/onboarding content remains',
        (WidgetTester tester) async {
      await tester.pumpWidget(
          MaterialApp(theme: sahaayLightTheme, home: const LoginScreen()));

      // Everything the removed welcome screen used to show.
      expect(find.text('Turning Surplus Food Into Hope.'), findsNothing);
      expect(
          find.textContaining('SAHAAY connects food providers'), findsNothing);
      expect(find.text('GET STARTED'), findsNothing);
      expect(find.text('View Public Impact Leaderboard'), findsNothing);
      expect(find.text('FOOD PROVIDER'), findsNothing);
      expect(find.text('VOLUNTEER (OPTIONAL)'), findsNothing);
      expect(find.text('PEOPLE / COMMUNITY'), findsNothing);
      expect(find.text('Already have an account? Login'), findsNothing);

      // And the extra login clutter the minimal design drops. Note that
      // "Forgot password?" and "Continue with Google" are intentionally NOT in
      // this list: the reference design restores both, and they are asserted as
      // present further down.
      // The intended current copy: the enlarged heading, the existing
      // subtitle and register affordance. The obsolete "career workspace"
      // string and the unused alternate copy never ship.
      expect(find.text('Welcome back!'), findsOneWidget);
      expect(find.text('Log in to continue making an impact.'), findsOneWidget);
      expect(find.text('Sign in to continue your career workspace.'),
          findsNothing);
      expect(find.text('Sign in to continue donating surplus.'), findsNothing);
    });

    testWidgets('the mark on login is the S-hand symbol only',
        (WidgetTester tester) async {
      await tester.pumpWidget(
          MaterialApp(theme: sahaayLightTheme, home: const LoginScreen()));

      final logo = tester.widget<SahaayLogo>(find.byType(SahaayLogo));
      expect(logo.showWordmark, isFalse);
    });
  });

  group('logo has no white box', () {
    /// Bytes of a declared asset, trimmed to the real payload.
    Future<Uint8List> assetBytes(String key) async {
      final data = await rootBundle.load(key);
      return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    }

    testWidgets('the S asset is genuinely transparent, not a white canvas',
        (WidgetTester tester) async {
      // Regression guard for the white-box bug. PNG IHDR: bytes 0-7 signature,
      // 8-11 length, 12-15 "IHDR", 16-19 width, 20-23 height, 24 bit depth,
      // 25 colour type. 2 = RGB (opaque), 6 = RGBA.
      // Everything real-async runs inside tester.runAsync, because
      // instantiateImageCodec never completes in the fake-async test zone.
      await tester.runAsync(() async {
        final original = await assetBytes('assets/images/sahaay_icon.png');
        expect(original[25], 2,
            reason: 'original artwork is RGB with no alpha - that is the bug');

        final fixed =
            await assetBytes('assets/images/sahaay_icon_transparent.png');
        expect(fixed[25], 6,
            reason: 'the mark asset must carry an alpha channel');

        // Decode it and prove the corners are actually transparent, so the mark
        // composites straight onto the app background.
        final codec = await ui.instantiateImageCodec(fixed);
        final frame = await codec.getNextFrame();
        final raw = (await frame.image
            .toByteData(format: ui.ImageByteFormat.rawStraightRgba))!;
        final w = frame.image.width, h = frame.image.height;
        int alphaAt(int x, int y) => raw.getUint8((y * w + x) * 4 + 3);

        expect(alphaAt(0, 0), 0, reason: 'top-left must be transparent');
        expect(alphaAt(w - 1, 0), 0, reason: 'top-right must be transparent');
        expect(alphaAt(0, h - 1), 0, reason: 'bottom-left must be transparent');
        expect(alphaAt(w - 1, h - 1), 0,
            reason: 'bottom-right must be transparent');

        // And the gradient itself must survive: plenty of fully opaque pixels.
        var opaque = 0;
        for (var i = 3; i < raw.lengthInBytes; i += 4) {
          if (raw.getUint8(i) == 255) opaque++;
        }
        expect(opaque, greaterThan(100000),
            reason: 'the blue gradient must not be stripped');
      });
    });

    testWidgets('login renders the transparent asset with no card or container',
        (WidgetTester tester) async {
      await tester.pumpWidget(
          MaterialApp(theme: sahaayLightTheme, home: const LoginScreen()));

      final image = tester.widget<Image>(find.byType(Image).first);
      expect((image.image as AssetImage).assetName,
          'assets/images/sahaay_icon_transparent.png');

      // No Card anywhere above the mark, in either theme branch.
      expect(
          find.ancestor(
              of: find.byType(SahaayLogo), matching: find.byType(Card)),
          findsNothing);

      // No ancestor paints a white/light box behind the mark.
      for (final box in tester.widgetList<Container>(find.ancestor(
          of: find.byType(SahaayLogo), matching: find.byType(Container)))) {
        final decoration = box.decoration;
        if (decoration is BoxDecoration && decoration.color != null) {
          expect(decoration.color, isNot(Colors.white),
              reason: 'the mark must not sit on a white box');
        }
      }
    });

    testWidgets('the mark is horizontally centred above the form',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(411, 891);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
          MaterialApp(theme: sahaayLightTheme, home: const LoginScreen()));
      await tester.pumpAndSettle();

      final logoCentre = tester.getCenter(find.byType(SahaayLogo));
      final screenCentre = tester.getCenter(find.byType(MaterialApp));
      expect((logoCentre.dx - screenCentre.dx).abs(), lessThan(1.0),
          reason: 'the S must be horizontally centred, not left aligned');

      // Near the upper portion: clearly above the middle of the screen.
      expect(logoCentre.dy, lessThan(891 / 2));
    });
  });

  group('restored auth entry points', () {
    testWidgets('"Forgot password?" invokes the existing reset flow',
        (WidgetTester tester) async {
      await tester.pumpWidget(withState(const LoginScreen()));

      await tester.tap(find.text('Forgot password?'));
      await tester.pumpAndSettle();

      // First branch of the untouched _resetPassword(): it needs an email, so
      // the guard message proves the action is wired to that method.
      expect(find.text('Enter your email first to reset your password.'),
          findsOneWidget);
    });

    testWidgets('"Continue with Google" invokes the existing Google flow',
        (WidgetTester tester) async {
      await tester.pumpWidget(withState(const LoginScreen()));

      final button = find.ancestor(
        of: find.text('Continue with Google'),
        matching: find.byType(OutlinedButton),
      );
      expect(button, findsOneWidget);

      await tester.tap(button);
      // Exactly one bounded pump: _googleLoading is set synchronously at the top
      // of _signInWithGoogle, before the credential request. Never settle - the
      // spinner animates forever by design.
      await tester.pump();

      // Proves the tap reached the real implementation, which swaps the button
      // content for its loading spinner.
      expect(find.byType(CircularProgressIndicator), findsWidgets);
    });
  });

  group('login interaction', () {
    testWidgets('empty submit surfaces the field validators',
        (WidgetTester tester) async {
      await tester.pumpWidget(
          MaterialApp(theme: sahaayLightTheme, home: const LoginScreen()));

      await tester.tap(find.text('LOGIN'));
      await tester.pumpAndSettle();

      expect(find.text('Enter a valid email'), findsOneWidget);
      expect(find.text('Password is required'), findsOneWidget);
    });

    testWidgets('password visibility can be toggled',
        (WidgetTester tester) async {
      await tester.pumpWidget(
          MaterialApp(theme: sahaayLightTheme, home: const LoginScreen()));

      final field = find.widgetWithText(AppInputField, 'Password');
      expect(tester.widget<AppInputField>(field).obscureText, isTrue);

      await tester.tap(find.byIcon(Icons.visibility_off_outlined));
      await tester.pumpAndSettle();

      expect(tester.widget<AppInputField>(field).obscureText, isFalse);
    });

    testWidgets('a pending sign-in keeps the loading state and stays on screen',
        (WidgetTester tester) async {
      await tester.pumpWidget(withState(const LoginScreen()));

      await tester.enterText(
          find.widgetWithText(AppInputField, 'Email'), 'nobody@example.com');
      await tester.enterText(
          find.widgetWithText(AppInputField, 'Password'), 'wrong-password');
      await tester.tap(find.text('LOGIN'));

      // Firebase has no such account under the fake platform, so the request
      // stays in flight. Never settle here: the busy spinner animates forever
      // by design. Pump a bounded number of frames instead.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byType(LoginScreen), findsOneWidget);
      // Loading state preserved: PrimaryButton swaps its label for a spinner.
      expect(find.byType(CircularProgressIndicator), findsWidgets);
      expect(find.text('LOGIN'), findsNothing);
    });

    testWidgets('an existing NGO account logs in instead of opening enrollment',
        (WidgetTester tester) async {
      final state = _LoginAppState(profile: _profile('ngo'));
      await tester.pumpWidget(withLoginState(state));
      await tester.enterText(
          find.widgetWithText(AppInputField, 'Email'), 'ngo@example.org');
      await tester.enterText(
          find.widgetWithText(AppInputField, 'Password'), 'test-password');
      await tester.tap(find.text('LOGIN'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.byType(RoleRouter), findsOneWidget);
      expect(find.byType(RoleSelectionScreen), findsNothing);
      expect(state.currentRole, UserRole.ngo);
    });

    for (final role in <String>['provider', 'volunteer']) {
      testWidgets('existing $role account uses the stored role on login',
          (WidgetTester tester) async {
        final state = _LoginAppState(profile: _profile(role));
        await tester.pumpWidget(withLoginState(state));
        await tester.enterText(
            find.widgetWithText(AppInputField, 'Email'), '$role@example.org');
        await tester.enterText(
            find.widgetWithText(AppInputField, 'Password'), 'test-password');
        await tester.tap(find.text('LOGIN'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));

        expect(find.byType(RoleRouter), findsOneWidget);
        expect(find.byType(RoleSelectionScreen), findsNothing);
        expect(state.currentRole?.name, role);
      });
    }

    testWidgets('backend configuration failure never opens enrollment',
        (WidgetTester tester) async {
      const message = 'The FastAPI backend URL is not configured. Set a valid '
          'API_BASE_URL in sahaay/env.json and rebuild with '
          'sahaay/scripts/build_release.ps1.';
      final state = _LoginAppState(
        googleError: const AuthException(message),
        hasFirebaseSession: true,
      );
      await tester.pumpWidget(withLoginState(state));
      final googleButton = find.ancestor(
        of: find.text('Continue with Google'),
        matching: find.byType(OutlinedButton),
      );
      await tester.tap(googleButton);
      await tester.pumpAndSettle();

      expect(find.text(message), findsOneWidget);
      expect(find.byType(LoginScreen), findsOneWidget);
      expect(find.byType(RoleSelectionScreen), findsNothing);
    });

    testWidgets('backend network failure never opens enrollment',
        (WidgetTester tester) async {
      const message = 'Network connection failed. Please try again.';
      final state = _LoginAppState(
        googleError: const AuthException(message),
        hasFirebaseSession: true,
      );
      await tester.pumpWidget(withLoginState(state));
      final googleButton = find.ancestor(
        of: find.text('Continue with Google'),
        matching: find.byType(OutlinedButton),
      );
      await tester.tap(googleButton);
      await tester.pumpAndSettle();

      expect(find.text(message), findsOneWidget);
      expect(find.byType(LoginScreen), findsOneWidget);
      expect(find.byType(RoleSelectionScreen), findsNothing);
    });
  });

  group('register navigation', () {
    testWidgets('"Register now" opens the existing role selection flow',
        (WidgetTester tester) async {
      // RoleSelectionScreen keeps its original AppBar with ThemeToggleButton,
      // which reads AppState - so the provider has to be present, exactly as
      // it is above the navigator in the real app.
      await tester.pumpWidget(withState(const LoginScreen()));

      await tester.ensureVisible(find.text('Register'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Register'));
      await tester.pumpAndSettle();

      // The untouched registration entry point.
      expect(find.byType(RoleSelectionScreen), findsOneWidget);
      expect(find.text('Join SAHAAY'), findsOneWidget);
      expect(find.text('What would you like to do?'), findsOneWidget);
      // And all three role choices are still reachable from there.
      expect(find.textContaining('donating surplus food'), findsOneWidget);
      expect(find.textContaining('Discover and claim'), findsOneWidget);
      expect(
          find.textContaining('Optionally help deliver food'), findsOneWidget);
    });
  });

  group('responsive layout', () {
    for (final size in <Size>[
      const Size(320, 640), // small Android
      const Size(411, 891), // POCO X6 NEO class
    ]) {
      testWidgets(
          'login has no overflow at ${size.width.toInt()}x${size.height.toInt()}',
          (WidgetTester tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(
            MaterialApp(theme: sahaayLightTheme, home: const LoginScreen()));
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(find.text('LOGIN'), findsOneWidget);
        expect(find.text('Register'), findsOneWidget);
      });
    }
  });
}

AuthProfile _profile(String role) => AuthProfile(
      uid: 'firebase-$role',
      email: '$role@example.org',
      role: role,
      fullName: 'Test $role',
      orgLabel: 'Test organization',
    );

class _LoginAppState extends AppState {
  _LoginAppState({
    this.profile,
    this.googleError,
    this.hasFirebaseSession = false,
  }) : super(FirebaseAuthService());

  final AuthProfile? profile;
  final AuthException? googleError;
  final bool hasFirebaseSession;

  @override
  bool get hasFirebaseUser => hasFirebaseSession;

  @override
  Future<void> login(String email, String password) async {
    _applyTestProfile();
  }

  @override
  Future<AuthProfile?> loginWithGoogle() async {
    if (googleError != null) throw googleError!;
    _applyTestProfile();
    return profile;
  }

  void _applyTestProfile() {
    final value = profile;
    if (value == null) return;
    currentRole = UserRole.values.firstWhere((role) => role.name == value.role);
    isLoggedIn = true;
    currentName = value.fullName;
    currentOrgLabel = value.orgLabel;
  }
}
