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
    this.platform = platformAndroid,
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

  /// 操作系统名：`Android` 或 `Windows`。
  ///
  /// ## 为什么必须有这个字段
  ///
  /// `Sec-CH-UA-Platform` 以前是**写死 `"Android"`** 的，UA 串也写死
  /// `(Linux; Android …) Mobile Safari/537.36`。那在安卓上没问题，到了
  /// Windows 上就是**自相矛盾的三件套**：
  ///
  ///   - 底下跑的引擎是 WebView2（桌面 Chromium）
  ///   - UA 说「我是安卓手机」
  ///   - `Sec-CH-UA-Platform` 说 `"Android"`
  ///
  /// 而桌面 WebView2 的默认真实 UA 是 `(Windows NT 10.0; Win64; x64) …
  /// Chrome/… Safari/537.36 Edg/…` —— 里面那个 `Edg/` 是 Edge 内核的招牌
  /// （WebView2 基于 Edge），和安卓那套 `; wv` / `Version/4.0` 是同一类
  /// 东西，都得剥。
  ///
  /// 把这个维度显式存下来，三个投影（UA / hints / 落盘）才能由同一份真相
  /// 推出来，不会各写各的。
  final String platform;

  static const platformAndroid = 'Android';
  static const platformWindows = 'Windows';

  /// 桌面平台（Windows）没有机型串，也不该发 `Sec-CH-UA-Model`。
  ///
  /// 判据写成「**等于** Windows」而不是「不等于 Android」：落盘里要是存了
  /// 个拼错的平台名，前者当安卓处理（走兜底、至少自洽），后者会把它当
  /// 桌面 —— 于是一条安卓身份被当成桌面，不一致得更隐蔽。
  bool get isDesktop => platform == platformWindows;

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
  String get secChUaPlatform => '"$platform"';

  /// `Sec-CH-UA-Platform-Version` 的值（**含引号**）。
  ///
  /// 两边形状不一样，别硬用同一个模板拼：
  ///   - 安卓：字段里存的是 `14`，真 Chrome 发的是 `"14.0.0"`；
  ///   - Windows：真 Chrome 发的是 `"10.0.0"`，本身就是完整四段式。
  ///
  /// 以前调用方无条件 `'"${platformVersion}.0.0"'`，在 Windows 上会拼出
  /// `"10.0.0.0.0"` —— 一个不存在的版本号。
  String get secChUaPlatformVersion => '"$platformVersionHint"';

  /// **裸值**（不带引号）。`Sec-CH-UA-Platform-Version` 的两种消费方共用它：
  /// 原生请求头那边要 `'"$v"'`，页面垫片那边要裸串。
  ///
  /// 以前两处各写一遍 `'${platformVersion}.0.0'`，于是我在 `http_headers`
  /// 里把形状改成按平台分支之后，**垫片那份没跟着改** —— Windows 上产出
  /// 五段的 `10.0.0.0.0`。同一件事只有一个定义处，才不会再漂。
  String get platformVersionHint {
    if (isDesktop) return platformVersion;
    // 安卓存的是 `14` 这种大版本。空串兜底成 14 —— 否则会拼出
    // `Android `（UA 里）和 `".0.0"`（头里）两个畸形值。
    final v = platformVersion.isEmpty ? '14' : platformVersion;
    return '$v.0.0';
  }

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
  // 键名是 `os` 不是 `platform` —— 上面那个 `platform` 存的是平台**版本**
  // （`14`），名字已经占了。老记录里没有这个键，一律当安卓（那时候只有安卓）。
  'os': identity.platform,
};

/// 从落盘数据恢复。字段不全或类型不对就返回 null，由调用方回落到真实值。
BrowserIdentity? identityFromJson(Object? raw) {
  if (raw is! Map) return null;
  final ua = raw['ua'];
  final major = raw['major'];
  final model = raw['model'];
  final platform = raw['platform'];
  if (ua is! String || major is! String || model is! String) return null;
  // 只要求 UA 和大版本。**不要求 model**：Windows 的身份天生没有机型串，
  // 以前那条 `model.isEmpty → null` 会把桌面身份整个判成坏数据、
  // 回落成安卓兜底 —— 正好和这个字段要修的问题是一件事。
  if (ua.isEmpty || major.isEmpty) return null;
  // 平台名**过白名单**：只有这两个值合法。落盘里可能是手改的、或者旧版
  // 写进去的别的字符串，原样透传会拼出 `Sec-CH-UA-Platform: "windows"`。
  final os = raw['os'];
  final platformName = os == BrowserIdentity.platformWindows
      ? BrowserIdentity.platformWindows
      : BrowserIdentity.platformAndroid;
  final isWindows = platformName == BrowserIdentity.platformWindows;
  return BrowserIdentity(
    userAgent: ua,
    chromeMajor: major,
    model: model,
    // 版本兜底按平台分支：Windows 的真值是 `10.0.0`，兜成 `14` 会让桌面
    // 身份报 `platform-version: "14"` —— 一个 Windows 上不存在的版本。
    platformVersion: platform is String && platform.isNotEmpty
        ? platform
        : (isWindows ? '10.0.0' : '14'),
    // `mobile` 优先取落盘，但**与平台冲突时以平台为准**：落盘里
    // `mobile: true` + `os: Windows` 会得到「桌面 UA + ?1」。
    isMobile: isWindows
        ? false
        : (raw['mobile'] is bool ? raw['mobile']! as bool : true),
    platform: platformName,
  );
}
