/// 清单文件里那条「关掉 Flutter 深层链接」的开关。
///
/// 不关的话，站点上的任何链接都可能被系统当成 App 的深链拉起来，
/// 而本 App 没有注册任何路由 —— 表现是点了链接 App 闪一下又回来。
library;

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
