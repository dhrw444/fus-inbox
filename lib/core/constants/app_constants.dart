/// 全 App 共用的常量。
///
/// 只有真正跨模块的东西才放这里 —— 单文件内部用的常量就写在那个文件里，
/// 堆到这儿会变成一个谁都不敢删的杂物间。
library;

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
