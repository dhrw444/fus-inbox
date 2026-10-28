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

/// 这个 UA 是不是桌面平台（Windows）报的。
///
/// 判据用 `Windows NT`：安卓 WebView 报的是 `(Linux; Android …)`，
/// Windows 上的 WebView2 报的是 `(Windows NT 10.0; Win64; x64)`。
/// 两边前缀就不同，不需要更复杂的嗅探。
bool isDesktopUserAgent(String raw) => raw.contains('Windows NT');

/// 从安卓 UA 里抠机型串。**只有这一处定义。**
///
/// 收尾用 `(?:\s+Build/|;|\))` 把 `Build/...` 一并剥掉 —— 真 Chrome 的 UA
/// 里没有那一段，留着等于自报「我是 WebView」。
///
/// 以前这里有两套正则：`parseWebViewUserAgent` 剥 `Build/`，
/// 而 `modelFromUserAgent` 那道写的是 `([^;)]+)\)`，会把
/// `SM-S918B Build/UP1A.231005.007` **整段**当机型返回 ——
/// 于是 `applyBoundIdentity` 会把 `Build/...` 塞进 `sec-ch-ua-model`，
/// 一个只有 WebView 才有的特征。同一件事只有一个定义处。
final _androidModelRe = RegExp(
  r'Android [\d.]+;\s*([^;)]+?)(?:\s+Build/|;|\))',
);

/// 从 UA 里提取真实身份。**按平台走两套规则。**
///
/// 安卓的输入形如：
/// ```
/// Mozilla/5.0 (Linux; Android 14; SM-S918B Build/UP1A.231005.007; wv)
/// AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0
/// Chrome/141.0.7390.122 Mobile Safari/537.36
/// ```
/// 要剥 `; wv`、`Version/4.0`、机型串里的 `Build/...`。
///
/// Windows 的输入形如：
/// ```
/// Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36
/// (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36 Edg/141.0.0.0
/// ```
/// 要剥尾巴上的 ` Edg/<版本>`。桌面 UA 里**没有机型**，也不该有
/// `Mobile` —— 所以 model 留空、`isMobile` 为 false。
///
/// ## 为什么以前在 Windows 上是错的
///
/// 这个函数以前**无条件**拿安卓模板重建 UA（`(Linux; Android $platform;
/// $model) … Mobile Safari/537.36`）。于是 Windows 上：真实 UA 是桌面
/// Edge 内核的，被重建成「安卓手机」—— 底下的引擎是 WebView2、UA 说自己是
/// 安卓、`Sec-CH-UA-Platform` 也写 `"Android"`，三件套互相矛盾。
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
  // ── Windows：桌面 UA，没有机型、不是 mobile ──
  if (isDesktopUserAgent(raw)) {
    // 剥掉尾巴上的 ` Edg/<版本>`。
    //
    // 用 `\s*` 而不是 `\s+`：前者允许 `Edg/` 紧贴前文（零空白），
    // 也就是**不依赖**「Edg 前面一定有空格」这个前提。真 UA 里那一段是
    // `Safari/537.36 Edg/141.0.0.0`，两种写法都能匹配上；区别在容错。
    //
    // （这条注释我第一版写反了，把 `\s*` 说成「兜住有空格的前提」——
    //  正好是反的。）
    final cleaned = raw.replaceAll(RegExp(r'\s*Edg/[\d.]+'), '').trim();
    return BrowserIdentity(
      userAgent: cleaned,
      chromeMajor: major,
      // 桌面 Chrome 的 UA 里没有机型位。
      model: '',
      // 真 Chrome 在 Windows 上发 `"10.0.0"`（本身就是完整四段式，
      // 别再补 `.0.0`，见 secChUaPlatformVersion 的注释）。
      platformVersion: platformVersion ?? '10.0.0',
      isMobile: false,
      platform: BrowserIdentity.platformWindows,
    );
  }

  // ── 安卓：保持原样 ──
  var deviceModel = model ?? '';
  if (deviceModel.isEmpty) {
    deviceModel = modelFromUserAgent(raw);
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
  // Windows：真 Chrome 在 Windows 上发 `"10.0.0"`。
  //
  // 注意**不从 UA 里取** —— UA 里写的是 `Windows NT 10.0`，那是系统版本，
  // 和 client hints 的 `platform-version` 不是同一个数（后者是「平台版本」，
  // 微软出于兼容一直报 10.0.0）。照 UA 取会把两个不同语义的东西对上。
  if (isDesktopUserAgent(raw)) return '10.0.0';
  final m = RegExp(r'Android ([\d.]+)').firstMatch(raw);
  return m?.group(1) ?? '14';
}

/// 从 UA 里取机型串。取不到返回空串，由调用方决定怎么兜。
String modelFromUserAgent(String ua) {
  final m = _androidModelRe.firstMatch(ua);
  return m?.group(1)?.trim() ?? '';
}

/// 从 UA 里取 Chrome 大版本。取不到就给一个真实存在过的版本，不给空串。
String chromeMajorFromUserAgent(String ua) {
  final m = RegExp(r'Chrome/(\d+)').firstMatch(ua);
  return m?.group(1) ?? '141';
}
