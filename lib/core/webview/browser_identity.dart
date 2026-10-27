/// 浏览器身份。
///
/// ## 为什么不再随机编 UA
///
/// 之前这里有一批手写的「真实 Chrome UA」，用户点「换身份」就换一个。
/// 那个思路是错的，而且**越换越容易被风控**：
///
///   - `Android 13; K` —— `K` 是 Chrome UA 缩减（UA Reduction）后的
///     占位机型。缩减版固定写 `Android 10`。写 13 是自相矛盾。
///   - `Chrome/120.0.0.0` —— 末两段全 0 是模拟器的默认版本号，
///     真 Chrome 从来不是这个形态。
///   - 最致命的是**和 client hints 撕裂**：WebView 引擎的
///     `Sec-CH-UA` / `Sec-CH-UA-Full-Version` 由内核按真实版本发出，
///     Dart 侧改不掉。于是请求变成「UA 说 Chrome 120、
///     Sec-CH-UA 说 Chrome 141」，这是比不伪装更明显的机器特征。
///
/// ## 现在怎么做
///
/// 全部取自 WebView 自己报的那串（`WebSettings.getDefaultUserAgent`），
/// 它是这台设备上**真实存在**的浏览器版本和真实机型串：
///
///   - UA 的 Chrome 版本 = 真实内核版本
///   - `Sec-CH-UA` 的版本 = 同一个版本
///   - 机型串 = 真实机型
///
/// 唯一需要加工的是剥掉 WebView 的招牌（`; wv` 标记和
/// `Version/4.0` 那段），否则 UA 自己就写着「我是 WebView」。
///
/// 「换身份」保留，但只换机型串和版本，且仍然自洽——用户手动点的时候
/// 站点可能已经把这个身份记进风控名单，换一个能重新开始。
library;

import 'dart:math';

/// 设备的真实浏览器身份。
///
/// 全部字段来自原生 `getDeviceProfile`，没有编造值。
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

/// 从 WebView 的默认 UA 里提取真实身份。
///
/// 输入形如：
/// ```
/// Mozilla/5.0 (Linux; Android 14; SM-S918B Build/UP1A.231005.007; wv)
/// AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0
/// Chrome/141.0.7390.122 Mobile Safari/537.36
/// ```
///
/// 输出要剥掉两处 WebView 招牌：
///   1. `; wv` —— WebView 专属标记
///   2. `Version/4.0 ` —— 只有 WebView 带这一段
///
/// 机型串里的 `Build/...` 也要去掉：真 Chrome 的 UA 里没有它。
BrowserIdentity parseWebViewUserAgent(
  String raw, {
  String? model,
  String? platformVersion,
}) {
  final chrome = RegExp(r'Chrome/([\d.]+)').firstMatch(raw)?.group(1);
  if (chrome == null) return BrowserIdentity.fallback;

  final major = chrome.split('.').first;

  // 机型串：优先用原生给的 Build.MODEL。
  //
  // 这一点很关键：Chrome 的 UA 缩减会把机型串抹成 "K"（见第三个测试用例）。
  // 从 UA 里抠出来就是 "K"，那是个明显的缩减版特征。
  // Build.MODEL 才是这台设备真实的机型名。
  var deviceModel = model ?? '';
  if (deviceModel.isEmpty) {
    // 从 "(Linux; Android 14; SM-S918B Build/..." 里抠。
    final m = RegExp(r'Android [\d.]+;\s*([^;)]+?)(?:\s+Build/|;|\))')
        .firstMatch(raw);
    deviceModel = m?.group(1)?.trim() ?? '';
  }

  final platform = platformVersion ?? _androidFrom(raw);

  // 重建 UA：保留 Android 版本和机型，去掉 wv / Build / Version/4.0。
  final cleaned =
      'Mozilla/5.0 (Linux; Android $platform'
      '${deviceModel.isEmpty ? '' : '; $deviceModel'}) '
      'AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/$chrome Mobile Safari/537.36';

  return BrowserIdentity(
    userAgent: cleaned,
    chromeMajor: major,
    model: deviceModel,
    platformVersion: platform,
    isMobile: true,
  );
}

String _androidFrom(String raw) {
  final m = RegExp(r'Android ([\d.]+)').firstMatch(raw);
  return m?.group(1) ?? '14';
}

/// 当前身份。
///
/// 默认是设备真实身份。用户点「换浏览器身份」时会换一个**仍然自洽**的
/// 组合：换机型串和 Chrome 版本，但 UA 和 client hints 永远同步变。
BrowserIdentity _current = BrowserIdentity.fallback;

BrowserIdentity get currentIdentity => _current;

/// 用原生探测到的真实身份初始化。App 启动时调用一次。
void initBrowserIdentity(BrowserIdentity identity) {
  _current = identity;
}

/// UA 字符串。收件箱 WebView 和所有原生 HTTP 都用这一个。
String get currentUserAgent => _current.userAgent;

/// 换一个身份。
///
/// 和旧实现的区别：旧版是**只换 UA、client hints 不变**，
/// 那正是撕裂的来源。现在 UA 和 hints 一起换，始终自洽。
///
/// 机型串从 [knownModels] 里挑，Chrome 版本在真实版本附近浮动
/// （±3 个大版本，都在真实存在的范围内）。
BrowserIdentity rotateIdentity([Random? rnd]) {
  final r = rnd ?? Random();
  final base = _current;

  // 真实内核版本是基准，只在附近浮动——编一个不存在的版本
  // 比固定版本更可疑。
  final baseMajor = int.tryParse(base.chromeMajor) ?? 141;
  final major = baseMajor + r.nextInt(4) - 2;
  final version = '$major.0.${6000 + r.nextInt(4000)}.${r.nextInt(200)}';

  final model = _knownModels[r.nextInt(_knownModels.length)];

  _current = BrowserIdentity(
    userAgent:
        'Mozilla/5.0 (Linux; Android ${base.platformVersion}; $model) '
        'AppleWebKit/537.36 (KHTML, like Gecko) '
        'Chrome/$version Mobile Safari/537.36',
    chromeMajor: '$major',
    model: model,
    platformVersion: base.platformVersion,
    isMobile: true,
  );
  return _current;
}

/// 真实存在的 Android 机型串。
///
/// 都是 `Build.MODEL` 的合法值，不是编的营销名。
const _knownModels = <String>[
  'SM-S918B',
  'SM-S928B',
  'SM-A546E',
  'SM-G991B',
  'Pixel 7',
  'Pixel 8',
  'Pixel 8 Pro',
  'CPH2451',
  'CPH2581',
  '2201117TY',
  '22101316G',
  'V2227A',
  'RMX3630',
  'M2101K7AG',
  'LE2121',
  'NE2211',
];
