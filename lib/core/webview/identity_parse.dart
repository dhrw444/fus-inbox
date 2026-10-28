/// 从 UA 串里还原一份身份。
///
/// ## 为什么单独拆一个文件
///
/// `browser_identity.dart` 里原先有两种「把字符串变成身份」的逻辑混在状态
/// 和轮换之间，它们的输入来源不同、清洗规则也不同：
///
///   1. **原生报的 WebView UA**（启动探测）：要剥掉 WebView 的招牌
///      （`; wv`、`Version/4.0`、`Build/...`），因为真 Chrome 的 UA 里没有
///      这三样，留着等于自报「我是 WebView」。
///   2. **账本里存的旧 UA**（切回原出口）：只补 model / major，**不动 UA
///      本身** —— 那串是上次真的发出去过的，改它等于换了个身份。
///
/// 两条路的规则不一样，混在一起时最容易改错。放在同一个文件里，差别一眼
/// 看得见。
///
/// 这个文件只依赖 [BrowserIdentity]，不碰任何状态。
library;

import 'package:fus_inbox/core/webview/identity_profile.dart';

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

  final platform = platformVersion ?? platformVersionFromUserAgent(raw);

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

/// 从 UA 里取 Android 版本。取不到就按 Chrome UA 缩减后的固定值
/// `14` 兜底 —— 缩减版 UA 里写死的就是这个数（见本文件开头）。
String platformVersionFromUserAgent(String raw) {
  final m = RegExp(r'Android ([\d.]+)').firstMatch(raw);
  return m?.group(1) ?? '14';
}

/// 从 UA 里取机型串。取不到返回空串，由调用方决定怎么兜。
String modelFromUserAgent(String ua) {
  final m = RegExp(r'Android [\d.]+; ([^;)]+)\)').firstMatch(ua);
  return m?.group(1)?.trim() ?? '';
}

/// 从 UA 里取 Chrome 大版本。取不到就给一个真实存在过的版本，不给空串。
String chromeMajorFromUserAgent(String ua) {
  final m = RegExp(r'Chrome/(\d+)').firstMatch(ua);
  return m?.group(1) ?? '141';
}
