/// 用户可见的常量：仓库地址、包名。
///
/// 这两项都在界面上露给用户，错了会把人引到别处，所以单独立一条。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:fus_inbox/core/constants/app_constants.dart';

void main() {
  group('AppConstants', () {
    test('points user-facing source links to the release repository', () {
      expect(AppConstants.appSourceUrl, 'https://github.com/dhrw444/fus-inbox');
      expect(Uri.tryParse(AppConstants.appSourceUrl)?.host, 'github.com');
    });

    test('uses the Android application id as package name', () {
      expect(AppConstants.appPackageName, 'com.yg.fusinbox');
    });
  });
}
