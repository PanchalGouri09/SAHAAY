import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sahaay/services/api_service.dart';
import 'package:sahaay/services/firebase_auth_service.dart';

void main() {
  test('NGO registration skips the separate matching eligibility endpoint',
      () async {
    final auth = _RegistrationAuth(_RegistrationUser());
    final api = _RegistrationApi(auth);
    final service = FirebaseAuthService(auth: auth, api: api);

    final profile = await service.register(
      email: 'ngo@example.org',
      password: 'test-password',
      role: 'ngo',
      fullName: 'NGO Contact',
      orgLabel: 'Community Pantry',
      phone: '9876543210',
    );

    expect(api.eligibilityEvaluations, 0);
    expect(profile.profileCompletion?.isComplete, isTrue);
  });
}

class _RegistrationApi extends ApiService {
  _RegistrationApi(FirebaseAuth auth) : super(auth: auth);

  int eligibilityEvaluations = 0;

  @override
  Future<Map<String, dynamic>> createProfile(
      Map<String, dynamic> payload) async {
    expect(payload['role'], 'ngo');
    expect(payload['phone'], '9876543210');
    return {
      'role': 'ngo',
      'full_name': payload['full_name'],
      'email': payload['email'],
      'profile': {'organization_name': 'Community Pantry'},
      'profile_completion': {
        'role': 'ngo',
        'complete': true,
        'completed_fields': 1,
        'total_fields': 1,
        'percentage': 100,
        'missing_fields': <String>[],
      },
    };
  }

  Future<Map<String, dynamic>> evaluateNgoDemoVerification() async {
    eligibilityEvaluations++;
    return {
      'status': 'eligible',
      'demo_verified': true,
      'production_verified': false,
      'label':
          'SAHAAY account eligibility only; this is not legal NGO verification.',
      'checks': {
        'email_verified': true,
        'address_valid': true,
        'profile_complete': true,
      },
      'blockers': <String>[],
    };
  }
}

class _RegistrationAuth implements FirebaseAuth {
  _RegistrationAuth(this.user);

  final _RegistrationUser user;

  @override
  User get currentUser => user;

  @override
  Future<UserCredential> createUserWithEmailAndPassword({
    required String email,
    required String password,
  }) async {
    user.email = email;
    return _RegistrationCredential(user);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _RegistrationUser implements User {
  @override
  final String uid = 'firebase-ngo-uid';

  @override
  String? email;

  @override
  String? displayName;

  @override
  Future<void> updateDisplayName(String? name) async {
    displayName = name;
  }

  @override
  Future<void> reload() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _RegistrationCredential implements UserCredential {
  _RegistrationCredential(this.user);

  @override
  final User user;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
