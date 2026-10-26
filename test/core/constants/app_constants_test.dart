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
