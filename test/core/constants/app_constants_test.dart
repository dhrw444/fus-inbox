import 'package:flutter_test/flutter_test.dart';
import 'package:fus_inbox/core/constants/app_constants.dart';
import 'package:fus_inbox/core/utils/external_url_launcher.dart';

void main() {
  group('AppConstants', () {
    test('points user-facing source links to the release repository', () {
      expect(AppConstants.appSourceUrl, 'https://github.com/dhrw444/fus-inbox');
      expect(
        parseExternalHttpUrl(AppConstants.appSourceUrl),
        Uri.parse('https://github.com/dhrw444/fus-inbox'),
      );
    });

    test('uses the Android application id as package name', () {
      expect(AppConstants.appPackageName, 'com.yg.fusinbox');
    });
  });
}
