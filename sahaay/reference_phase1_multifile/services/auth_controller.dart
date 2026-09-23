import 'dart:async';

import 'package:flutter/foundation.dart';

import '../config/env_config.dart';
import '../models/user_model.dart';
import 'auth_service.dart';

enum AuthStatus { unknown, authenticated, unauthenticated }

/// The single source of truth for "who is logged in" across the whole app.
///
/// Screens should NOT talk to [AuthService] directly — they should call
/// through this controller, which is exposed via `provider` in main.dart.
/// This keeps state management simple (just ChangeNotifier + Provider,
/// no extra architecture) while still being swappable/testable.
class AuthController extends ChangeNotifier {
  late final AuthService _service;
  StreamSubscription<AppUser?>? _sub;

  AuthStatus status = AuthStatus.unknown;
  AppUser? user;
  String? errorMessage;
  bool isLoading = false;

  AuthController() {
    // The seam: demo mode -> Mock backend. Configured -> real Firebase.
    _service = EnvConfig.demoMode ? MockAuthService() : FirebaseAuthService();
    _sub = _service.authStateChanges.listen((u) {
      user = u;
      status = u == null ? AuthStatus.unauthenticated : AuthStatus.authenticated;
      notifyListeners();
    });
    // If nothing has emitted yet within a tick, resolve to unauthenticated
    // so the splash screen doesn't hang forever on a fresh install.
    Future.microtask(() {
      if (status == AuthStatus.unknown) {
        status = AuthStatus.unauthenticated;
        notifyListeners();
      }
    });
  }

  bool get isDemoMode => EnvConfig.demoMode;

  Future<bool> signIn(String email, String password) => _run(() async {
        user = await _service.signIn(email: email, password: password);
      });

  Future<bool> register({
    required String email,
    required String password,
    required String fullName,
    required String phone,
    required UserRole role,
    Map<String, dynamic> extra = const {},
  }) =>
      _run(() async {
        user = await _service.register(
          email: email,
          password: password,
          fullName: fullName,
          phone: phone,
          role: role,
          extra: extra,
        );
      });

  Future<bool> sendPasswordReset(String email) => _run(() async {
        await _service.sendPasswordResetEmail(email);
      });

  Future<void> signOut() async {
    isLoading = true;
    notifyListeners();
    await _service.signOut();
    user = null;
    status = AuthStatus.unauthenticated;
    isLoading = false;
    notifyListeners();
  }

  /// Runs an auth action with consistent loading/error handling so every
  /// screen doesn't have to reimplement try/catch + isLoading toggling.
  Future<bool> _run(Future<void> Function() action) async {
    isLoading = true;
    errorMessage = null;
    notifyListeners();
    try {
      await action();
      isLoading = false;
      notifyListeners();
      return true;
    } on AuthException catch (e) {
      errorMessage = e.message;
      isLoading = false;
      notifyListeners();
      return false;
    } catch (e) {
      errorMessage = 'Something went wrong. Please try again.';
      isLoading = false;
      notifyListeners();
      return false;
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}
