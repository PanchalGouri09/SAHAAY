import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sahaay/services/api_service.dart';

const _compiledApiBaseUrl = String.fromEnvironment('API_BASE_URL');

class _UnusedFirebaseAuth extends Fake implements FirebaseAuth {}

void main() {
  group('FastAPI base URL configuration', () {
    test('the compiled API_BASE_URL agrees with runtime validation', () {
      final api = ApiService(auth: _UnusedFirebaseAuth());

      expect(
        api.isConfigured,
        ApiService.isValidBaseUrl(_compiledApiBaseUrl),
      );
    });

    test('missing build configuration reports how to fix it', () async {
      if (ApiService.isValidBaseUrl(_compiledApiBaseUrl)) return;

      await expectLater(
        ApiService(auth: _UnusedFirebaseAuth()).getProfile(),
        throwsA(
          isA<ApiException>()
              .having((error) => error.statusCode, 'statusCode', 0)
              .having(
                (error) => error.message,
                'message',
                contains('scripts/build_release.ps1'),
              ),
        ),
      );
    });

    test('accepts deployed HTTPS and private-LAN HTTP endpoints', () {
      expect(
        ApiService.isValidBaseUrl('https://api.sahaay.org'),
        isTrue,
      );
      expect(
        ApiService.isValidBaseUrl('http://192.168.1.9:8000'),
        isTrue,
      );
      expect(
        ApiService.isValidBaseUrl('https://api.sahaay.org/backend/'),
        isTrue,
      );
    });

    test('rejects missing, placeholder, loopback, and malformed endpoints', () {
      for (final value in <String>[
        '',
        'https://your-deployed-fastapi.example.com',
        'http://localhost:8000',
        'http://127.0.0.1:8000',
        'http://0.0.0.0:8000',
        'ftp://api.sahaay.org',
        'https://user:password@api.sahaay.org',
        'https://api.sahaay.org?token=secret',
        'https://api.sahaay.org/#fragment',
        'not a URL',
      ]) {
        expect(
          ApiService.isValidBaseUrl(value),
          isFalse,
          reason: 'Expected invalid URL: $value',
        );
      }
    });
  });
}
