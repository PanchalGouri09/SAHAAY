import 'dart:async';
import 'dart:math';

import 'package:firebase_auth/firebase_auth.dart' as fb;

import '../models/user_model.dart';

/// Thrown by any [AuthService] implementation on a handled auth failure,
/// so the UI can show a friendly message regardless of which backend
/// (mock or Firebase) is currently active.
class AuthException implements Exception {
  final String message;
  AuthException(this.message);
  @override
  String toString() => message;
}

/// Abstraction so screens never talk to Firebase directly.
///
/// This is the seam that lets us swap between [MockAuthService] (for demo
/// mode, before Firebase is configured) and [FirebaseAuthService] (real)
/// WITHOUT changing a single screen.
abstract class AuthService {
  /// Fires whenever the signed-in user changes (including on sign out -> null).
  Stream<AppUser?> get authStateChanges;

  AppUser? get currentUser;

  Future<AppUser> signIn({required String email, required String password});

  Future<AppUser> register({
    required String email,
    required String password,
    required String fullName,
    required String phone,
    required UserRole role,
    Map<String, dynamic> extra,
  });

  Future<void> sendPasswordResetEmail(String email);

  Future<void> signOut();
}

/// ---------------------------------------------------------------------
/// MOCK implementation — used when EnvConfig.demoMode == true.
/// Keeps everything in memory so the whole app is demonstrable without
/// any Firebase project set up yet.
/// ---------------------------------------------------------------------
class MockAuthService implements AuthService {
  final _controller = StreamController<AppUser?>.broadcast();
  AppUser? _currentUser;

  // A tiny in-memory "users table" keyed by email, so registered demo
  // accounts can log back in during the same app session.
  final Map<String, _MockAccount> _accounts = {
    // A few pre-seeded demo accounts so the app can be shown instantly.
    'provider@demo.com': _MockAccount(
      password: 'demo1234',
      user: AppUser(
        id: 'demo-provider-1',
        email: 'provider@demo.com',
        fullName: 'Hotel XYZ',
        phone: '9876543210',
        role: UserRole.provider,
        createdAt: DateTime.now(),
        address: 'Koregaon Park, Pune',
        extra: {'providerType': ProviderType.hotel.name, 'organizationName': 'Hotel XYZ'},
      ),
    ),
    'ngo@demo.com': _MockAccount(
      password: 'demo1234',
      user: AppUser(
        id: 'demo-ngo-1',
        email: 'ngo@demo.com',
        fullName: 'ABC Foundation',
        phone: '9876500000',
        role: UserRole.ngo,
        createdAt: DateTime.now(),
        address: 'Camp, Pune',
        extra: {'registrationId': 'NGO-REG-2024-001', 'capacityServed': 200},
      ),
    ),
    'volunteer@demo.com': _MockAccount(
      password: 'demo1234',
      user: AppUser(
        id: 'demo-volunteer-1',
        email: 'volunteer@demo.com',
        fullName: 'Rahul Sharma',
        phone: '9876511111',
        role: UserRole.volunteer,
        createdAt: DateTime.now(),
        address: 'Viman Nagar, Pune',
        extra: {'preferredDistanceKm': 5, 'availableDays': ['Sat', 'Sun']},
      ),
    ),
    'admin@demo.com': _MockAccount(
      password: 'demo1234',
      user: AppUser(
        id: 'demo-admin-1',
        email: 'admin@demo.com',
        fullName: 'SAHAAY Admin',
        phone: '9999999999',
        role: UserRole.admin,
        createdAt: DateTime.now(),
      ),
    ),
  };

  @override
  Stream<AppUser?> get authStateChanges => _controller.stream;

  @override
  AppUser? get currentUser => _currentUser;

  Future<void> _simulateNetworkDelay() =>
      Future.delayed(const Duration(milliseconds: 700));

  @override
  Future<AppUser> signIn({required String email, required String password}) async {
    await _simulateNetworkDelay();
    final account = _accounts[email.trim().toLowerCase()];
    if (account == null || account.password != password) {
      throw AuthException('Incorrect email or password.');
    }
    _currentUser = account.user;
    _controller.add(_currentUser);
    return _currentUser!;
  }

  @override
  Future<AppUser> register({
    required String email,
    required String password,
    required String fullName,
    required String phone,
    required UserRole role,
    Map<String, dynamic> extra = const {},
  }) async {
    await _simulateNetworkDelay();
    final key = email.trim().toLowerCase();
    if (_accounts.containsKey(key)) {
      throw AuthException('An account already exists with this email.');
    }
    if (password.length < 6) {
      throw AuthException('Password must be at least 6 characters.');
    }

    final newUser = AppUser(
      id: 'demo-${role.name}-${Random().nextInt(999999)}',
      email: key,
      fullName: fullName,
      phone: phone,
      role: role,
      createdAt: DateTime.now(),
      extra: extra,
    );
    _accounts[key] = _MockAccount(password: password, user: newUser);
    _currentUser = newUser;
    _controller.add(_currentUser);
    return newUser;
  }

  @override
  Future<void> sendPasswordResetEmail(String email) async {
    await _simulateNetworkDelay();
    if (!_accounts.containsKey(email.trim().toLowerCase())) {
      throw AuthException('No account found with this email.');
    }
    // In demo mode we just pretend the email was sent.
  }

  @override
  Future<void> signOut() async {
    await _simulateNetworkDelay();
    _currentUser = null;
    _controller.add(null);
  }
}

class _MockAccount {
  final String password;
  final AppUser user;
  _MockAccount({required this.password, required this.user});
}

/// ---------------------------------------------------------------------
/// REAL Firebase implementation.
///
/// NOTE (Phase 1 scope): this wires up real Firebase Authentication.
/// Persisting the *full* profile (role, provider type, NGO capacity, etc.)
/// into Supabase Postgres happens in Phase 9 once supabase_service.dart
/// is built. Until then, this class keeps a lightweight in-memory profile
/// cache keyed by UID for the current app session so navigation/role
/// checks still work end-to-end.
/// ---------------------------------------------------------------------
class FirebaseAuthService implements AuthService {
  final fb.FirebaseAuth _auth = fb.FirebaseAuth.instance;
  final Map<String, AppUser> _profileCache = {};

  @override
  Stream<AppUser?> get authStateChanges {
    return _auth.authStateChanges().map((fbUser) {
      if (fbUser == null) return null;
      return _profileCache[fbUser.uid] ??
          AppUser(
            id: fbUser.uid,
            email: fbUser.email ?? '',
            fullName: fbUser.displayName ?? '',
            phone: fbUser.phoneNumber ?? '',
            // TODO(Phase 9): replace with the real role fetched from Supabase.
            role: UserRole.volunteer,
            createdAt: fbUser.metadata.creationTime ?? DateTime.now(),
            photoUrl: fbUser.photoURL,
          );
    });
  }

  @override
  AppUser? get currentUser {
    final fbUser = _auth.currentUser;
    if (fbUser == null) return null;
    return _profileCache[fbUser.uid];
  }

  @override
  Future<AppUser> signIn({required String email, required String password}) async {
    try {
      final cred = await _auth.signInWithEmailAndPassword(email: email, password: password);
      final fbUser = cred.user!;
      final cached = _profileCache[fbUser.uid];
      if (cached != null) return cached;
      // TODO(Phase 9): fetch the real profile row from Supabase here.
      return AppUser(
        id: fbUser.uid,
        email: fbUser.email ?? email,
        fullName: fbUser.displayName ?? '',
        phone: fbUser.phoneNumber ?? '',
        role: UserRole.volunteer,
        createdAt: fbUser.metadata.creationTime ?? DateTime.now(),
      );
    } on fb.FirebaseAuthException catch (e) {
      throw AuthException(_mapFirebaseError(e));
    }
  }

  @override
  Future<AppUser> register({
    required String email,
    required String password,
    required String fullName,
    required String phone,
    required UserRole role,
    Map<String, dynamic> extra = const {},
  }) async {
    try {
      final cred = await _auth.createUserWithEmailAndPassword(email: email, password: password);
      final fbUser = cred.user!;
      await fbUser.updateDisplayName(fullName);

      final profile = AppUser(
        id: fbUser.uid,
        email: email,
        fullName: fullName,
        phone: phone,
        role: role,
        createdAt: DateTime.now(),
        extra: extra,
      );
      _profileCache[fbUser.uid] = profile;
      // TODO(Phase 9): insert this profile as a row in Supabase Postgres.
      return profile;
    } on fb.FirebaseAuthException catch (e) {
      throw AuthException(_mapFirebaseError(e));
    }
  }

  @override
  Future<void> sendPasswordResetEmail(String email) async {
    try {
      await _auth.sendPasswordResetEmail(email: email);
    } on fb.FirebaseAuthException catch (e) {
      throw AuthException(_mapFirebaseError(e));
    }
  }

  @override
  Future<void> signOut() async {
    await _auth.signOut();
  }

  String _mapFirebaseError(fb.FirebaseAuthException e) {
    switch (e.code) {
      case 'user-not-found':
        return 'No account found with this email.';
      case 'wrong-password':
      case 'invalid-credential':
        return 'Incorrect email or password.';
      case 'email-already-in-use':
        return 'An account already exists with this email.';
      case 'weak-password':
        return 'Password must be at least 6 characters.';
      case 'invalid-email':
        return 'Please enter a valid email address.';
      default:
        return e.message ?? 'Something went wrong. Please try again.';
    }
  }
}
