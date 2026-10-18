import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sahaay/services/pdf_saver.dart';

/// Verifies the PDF saver talks to the native Downloads bridge and only reports
/// a shared-Downloads success when the platform actually confirmed a path.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('sahaay/files');

  void mockHandler(Future<Object?> Function(MethodCall call)? handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, handler);
  }

  tearDown(() => mockHandler(null));

  test('reports the shared Downloads path the platform returned', () async {
    MethodCall? captured;
    mockHandler((call) async {
      captured = call;
      return 'Downloads/receipt_ab12.pdf';
    });

    final saved = await savePdfToDownloads('receipt_ab12.pdf', [1, 2, 3]);

    expect(saved.inDownloads, isTrue);
    expect(saved.location, 'Downloads/receipt_ab12.pdf');
    expect(captured?.method, 'savePdf');
    final args = captured?.arguments as Map?;
    expect(args?['fileName'], 'receipt_ab12.pdf');
    expect((args?['bytes'] as List?)?.length, 3);
  });

  test('never claims a Downloads save when the platform returns no path',
      () async {
    mockHandler((call) async => '');
    // No native bridge path and no path_provider in tests -> the fallback
    // itself fails, so the caller sees an error instead of a false success.
    await expectLater(
      savePdfToDownloads('receipt.pdf', [1]),
      throwsA(anything),
    );
  });
}
