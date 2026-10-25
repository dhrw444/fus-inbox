class AppConstants() {
  static const String appName = 'SMS 收件箱';
  static const String appDescription = 'freeussms 公共号码收件箱。';
  static const String appPackageName = 'com.yg.fusinbox';
  static const String appSourceUrl = 'https://github.com/dhrw444/fus-inbox';
  static const String appVersion = .fromEnvironment(
    'APP_VERSION',
    defaultValue: '0.1.0',
  );
}
