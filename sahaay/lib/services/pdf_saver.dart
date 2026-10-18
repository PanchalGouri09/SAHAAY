// Saves a generated acknowledgment/receipt PDF somewhere the user can actually
// find it. On Android the bytes go through a small Kotlin bridge into the shared
// Downloads collection (MediaStore on API 29+, the public Downloads directory
// below that); everywhere else, or if the bridge is unavailable, it falls back
// to the app's documents directory. The returned location is only reported
// after the write actually succeeded.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// Outcome of a PDF save, so the UI can tell the user exactly where the file
/// went instead of claiming a generic "saved".
class SavedPdf {
  /// True when the file was written to the shared Downloads location (visible
  /// in a file manager / the Downloads app), false for the app-private fallback.
  final bool inDownloads;

  /// Human-readable location, e.g. `Downloads/sahaay_acknowledgment_ab12.pdf`.
  final String location;

  const SavedPdf({required this.inDownloads, required this.location});
}

const MethodChannel _pdfChannel = MethodChannel('sahaay/files');

/// Writes [bytes] as [fileName] to the platform's user-visible Downloads
/// location, falling back to the app documents directory when the native bridge
/// is missing (non-Android platforms, tests) or fails.
Future<SavedPdf> savePdfToDownloads(String fileName, List<int> bytes) async {
  try {
    final path = await _pdfChannel.invokeMethod<String>('savePdf', {
      'bytes': Uint8List.fromList(bytes),
      'fileName': fileName,
    });
    if (path != null && path.trim().isNotEmpty) {
      return SavedPdf(inDownloads: true, location: path.trim());
    }
  } on MissingPluginException {
    // No native bridge (desktop/web/tests): fall through to the app directory.
  } on PlatformException {
    // Bridge present but the platform refused (e.g. storage unavailable):
    // fall through to the app directory rather than reporting a false success.
  }

  final dir = await getApplicationDocumentsDirectory();
  final file = File('${dir.path}${Platform.pathSeparator}$fileName');
  await file.writeAsBytes(bytes, flush: true);
  return SavedPdf(inDownloads: false, location: file.path);
}
