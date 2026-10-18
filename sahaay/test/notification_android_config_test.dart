import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('notification branding uses the transparent S glyph, not the launcher',
      () {
    final manifest =
        File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
    final pushConfig =
        File('lib/services/push_notifications.dart').readAsStringSync();
    final smallIcon =
        File('android/app/src/main/res/drawable-nodpi/ic_stat_sahaay.png');
    final largeIcon = File(
        'android/app/src/main/res/drawable-nodpi/sahaay_notification_large.png');

    expect(manifest, contains('android:icon="@mipmap/ic_launcher"'));
    expect(
      manifest,
      contains('android:resource="@drawable/ic_stat_sahaay"'),
    );
    expect(pushConfig, contains("icon: 'ic_stat_sahaay'"));
    expect(pushConfig,
        contains("DrawableResourceAndroidBitmap('sahaay_notification_large')"));
    expect(smallIcon.existsSync(), isTrue);
    expect(largeIcon.existsSync(), isTrue);

    final png = smallIcon.readAsBytesSync();
    expect(
      png.take(8).toList(),
      [137, 80, 78, 71, 13, 10, 26, 10],
    );
    final header = ByteData.sublistView(png);
    expect(header.getUint32(16), 96);
    expect(header.getUint32(20), 96);
    expect(png[25], 6, reason: 'Notification glyph should retain alpha.');
  });
}
