import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('MainActivity disables Flutter deep linking', () async {
    final manifest = await File('android/app/src/main/AndroidManifest.xml')
        .readAsString();
    final activity = RegExp(r'<activity\b[^>]*>([\s\S]*?)</activity>')
        .firstMatch(manifest)!
        .group(1)!;
    expect(
      activity,
      contains(
        'android:name="flutter_deeplinking_enabled" android:value="false"',
      ),
    );
  });
}
