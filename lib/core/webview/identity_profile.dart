/// 浏览器身份的**值类型**：一台设备的 UA / 机型 / 内核大版本，以及由它派生
/// 出来的 client hints 和落盘形状。
///
/// ## 为什么单独拆一个文件
///
/// 从 `browser_identity.dart` 拆出来，理由和 `identity_binding.dart` 那次
/// 一样：那边要同时装「当前身份」这个可变状态、UA 解析、以及轮换时的随机
/// 逻辑，再加这个只有字段和派生 getter 的值类就太挤了。
///
/// ## 它为什么不能拆得更细
///
/// client hints（`secChUa` / `secChUaModel` / `secChUaPlatform`）和落盘 JSON
/// 必须和字段住在同一个文件里，因为它们是**同一份真相的三种投影**：
///
///   - hints 是「发出去的形状」—— UA 里的版本和 `Sec-CH-UA` 里的版本
///     必须是同一个来源算出来的，两边各写一份就是撕裂；
///   - JSON 是「存下来的形状」—— 字段增删必须和这里同步，否则重启之后
///     身份会退化成一组自相矛盾的值。
///
/// 这个文件**没有任何本仓依赖**（连 `dart:math` 都不用），所以能被纯逻辑
/// 测试直接引用。
library;

/// 设备的真实浏览器身份。
///
/// 全部字段来自内核自报的默认 UA（`WebEngine.defaultUserAgent`），没有编造值。
class BrowserIdentity {
  // 这个类有 5 个字段和一堆派生 getter（secChUa / secChUaModel / ...）。
  // 主构造器写法要额外拆一组字段声明出去，读起来比现在绕，不划算。
  // ignore: use_primary_constructors
  const BrowserIdentity({
    required this.userAgent,
    required this.chromeMajor,
    required this.model,
    required this.platformVersion,
    required this.isMobile,
  });

  /// 完整的 UA 串，已剥掉 WebView 特征。
  final String userAgent;

  /// 主版本号，如 `141`。client hints 用它。
  final String chromeMajor;

  /// 机型串，如 `SM-S918B`。
  final String model;

  /// 平台版本，如 `"14"`。`Sec-CH-UA-Platform-Version` 用它。
  final String platformVersion;

  final bool isMobile;

  /// `Sec-CH-UA` 的值。
  ///
  /// 必须和 UA 里的版本**完全一致**。真 Chrome 的格式是：
  /// `"Chromium";v="141", "Google Chrome";v="141", "Not?A_Brand";v="99"`
  /// 那个 `Not?A_Brand` 是 Chrome 的 GREASE 值，每个大版本会换，
  /// 但 `99` 在 110+ 一直是合法的。
  String get secChUa =>
      '"Chromium";v="$chromeMajor", "Google Chrome";v="$chromeMajor", '
      '"Not?A_Brand";v="99"';

  /// `Sec-CH-UA-Platform` 的值。
  String get secChUaPlatform => '"Android"';

  /// `Sec-CH-UA-Model` 的值。
  String get secChUaModel => '"$model"';

  /// 原生探测失败时的兜底。
  ///
  /// 不编版本号：用 Chrome 141 这个真实存在的大版本，
  /// 但机型串留空 —— 宁可少一个头，也不给出一组自相矛盾的假身份。
  static const fallback = BrowserIdentity(
    userAgent:
        'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/141.0.0.0 Mobile Safari/537.36',
    chromeMajor: '141',
    model: '',
    platformVersion: '14',
    isMobile: true,
  );
}

/// 序列化成能落盘的形状。
Map<String, Object?> identityToJson(BrowserIdentity identity) => {
  'ua': identity.userAgent,
  'major': identity.chromeMajor,
  'model': identity.model,
  'platform': identity.platformVersion,
  'mobile': identity.isMobile,
};

/// 从落盘数据恢复。字段不全或类型不对就返回 null，由调用方回落到真实值。
BrowserIdentity? identityFromJson(Object? raw) {
  if (raw is! Map) return null;
  final ua = raw['ua'];
  final major = raw['major'];
  final model = raw['model'];
  final platform = raw['platform'];
  if (ua is! String || major is! String || model is! String) return null;
  if (ua.isEmpty || major.isEmpty || model.isEmpty) return null;
  return BrowserIdentity(
    userAgent: ua,
    chromeMajor: major,
    model: model,
    platformVersion: platform is String && platform.isNotEmpty
        ? platform
        : '14',
    isMobile: raw['mobile'] is bool ? raw['mobile']! as bool : true,
  );
}
