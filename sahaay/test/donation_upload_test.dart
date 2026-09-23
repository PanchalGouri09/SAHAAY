import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';

import 'package:sahaay/main.dart';
import 'package:sahaay/services/api_service.dart';

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

void main() {
  late String tempDir;
  late File pngFile;
  late File jpgFile;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('sahaay_upload_test').path;
    pngFile = File('$tempDir${Platform.pathSeparator}food.png')
      ..writeAsBytesSync([0x89, 0x50, 0x4E, 0x47]);
    jpgFile = File('$tempDir${Platform.pathSeparator}food.jpg')
      ..writeAsBytesSync([0xFF, 0xD8, 0xFF, 0xE0]);
  });

  tearDown(() {
    try {
      Directory(tempDir).deleteSync(recursive: true);
    } catch (_) {}
  });

  group('ApiService.mimeForPath', () {
    test('resolves a valid image/* content type for every supported format',
        () {
      expect(ApiService.mimeForPath('a/food.png'), 'image/png');
      expect(ApiService.mimeForPath('a/food.jpg'), 'image/jpeg');
      expect(ApiService.mimeForPath('a/food.jpeg'), 'image/jpeg');
      expect(ApiService.mimeForPath('a/food.webp'), 'image/webp');
      expect(ApiService.mimeForPath('a/food.heic'), 'image/heic');
      expect(ApiService.mimeForPath('a/food.heif'), 'image/heif');
    });

    test('falls back to octet-stream for unknown extensions', () {
      expect(ApiService.mimeForPath('a/photo'), 'application/octet-stream');
      expect(ApiService.mimeForPath('a/photo.bin'), 'application/octet-stream');
    });
  });

  group('ApiService.buildUploadRequest', () {
    test('PNG is uploaded with an explicit image/png content type', () async {
      final request =
          await ApiService.buildUploadRequest(baseUrl: 'http://localhost:8000',
              token: 'tok-123', file: pngFile);

      expect(request.method, 'POST');
      expect(request.url.toString(),
          'http://localhost:8000/api/v1/donations/upload');
      expect(request.headers['Authorization'], 'Bearer tok-123');
      expect(request.files, hasLength(1));
      expect(request.files.single.contentType.mimeType, 'image/png');
      expect(request.files.single.filename, 'food.png');
    });

    test('JPG is uploaded with an explicit image/jpeg content type', () async {
      final request =
          await ApiService.buildUploadRequest(baseUrl: 'http://localhost:8000',
              token: 'tok-123', file: jpgFile);

      expect(request.files.single.contentType.mimeType, 'image/jpeg');
      expect(request.files.single.filename, 'food.jpg');
    });
  });

  group('pickFoodPhoto', () {
    late ImagePickerPlatform original;
    late _FakeImagePickerPlatform fake;

    setUp(() {
      original = ImagePickerPlatform.instance;
      fake = _FakeImagePickerPlatform();
      ImagePickerPlatform.instance = fake;
    });

    tearDown(() {
      ImagePickerPlatform.instance = original;
    });

    test('opening the camera routes to getImageFromSource(camera)', () async {
      fake.result = XFile(pngFile.path);

      final picked = await pickFoodPhoto(ImageSource.camera);

      expect(fake.lastSource, ImageSource.camera);
      expect(picked, isNotNull);
      expect(picked!.path, pngFile.path);
    });

    test('gallery selection routes to getImageFromSource(gallery)', () async {
      fake.result = XFile(jpgFile.path);

      final picked = await pickFoodPhoto(ImageSource.gallery);

      expect(fake.lastSource, ImageSource.gallery);
      expect(picked, isNotNull);
    });

    test('returns null when the user cancels the picker', () async {
      fake.result = null;

      final picked = await pickFoodPhoto(ImageSource.camera);

      expect(fake.lastSource, ImageSource.camera);
      expect(picked, isNull);
    });
  });
}