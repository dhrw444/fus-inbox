/// 判断这台机器的 WebView 内核版本够不够过 Cloudflare Turnstile。
///
/// ## 为什么需要它
///
/// 真机上踩到过：验证页标题栏出来了，页面里一直转圈 / 一片空白，用户完全
/// 不知道该干什么。而在另一台机器上（Han1meViewer）同一条流程会**直接把
/// 版本号摊在提示里**：
///
/// ```
/// 当前WebView版本: 114.0.5735.196
/// ⚠ WebView版本过低，可能会验证失败，推荐版本为 120.x.x.x以上
/// ```
///
/// 114 就是过不去的 —— Turnstile 在旧内核上要么转圈到超时、要么直接渲染
/// 失败。这不是网络问题、不是代理问题、也不是「验证框没找到」，换代理换
/// 出口都没用。用户不知道这一点的话会一直重试，那是纯粹的浪费。
///
/// ## 阈值取 120 的依据
///
/// 取自 Han1meViewer 的实测结论（`CloudflareActivity.kt` 里写死 `parts[0] < 120`
/// 就提示过低）。没有更权威的来源 —— Cloudflare 不公布 Turnstile 的内核
/// 要求 —— 所以照它的经验值，并在文案里说清这是「推荐」而不是硬门槛：
/// 114 的机器**偶尔**也能过，只是成功率低到不该让人一直试。
///
/// ## 为什么参数是裸 String
///
/// 和 `challenge_focus.dart` 当初的理由一样：纯 Dart 里没有 `dart:ui`，
/// 这个文件要能在 `tool/` 下单测。输入是 UA 串，输出是纯数据。
library;

/// 推荐的最低 WebView 主版本号。见文件头。
const recommendedWebViewMajor = 120;

/// 一次版本检查的结论。
class const WebViewVersionCheck({
  required this.major,
  required this.display,
  required this.tooLow,
}) {
  /// 解析出来的主版本号。解析不出来时是 0。
  final int major;

  /// 给人看的版本号（`114.0.5735.196`）。解析不出来时是空串。
  final String display;

  /// 是否低于 [recommendedWebViewMajor]。
  final bool tooLow;

  /// 解析不出来时既不该报警也不该说「够用」—— 只能沉默。
  bool get unknown => display.isEmpty;
}

/// 从 WebView 的默认 UA 里读出内核版本。
///
/// UA 形如
/// `Mozilla/5.0 (Linux; Android 14; SM-S918B) AppleWebKit/537.36 (KHTML, like Gecko)
///  Version/4.0 Chrome/114.0.5735.196 Mobile Safari/537.36`。
///
/// **只认 `Chrome/`**：安卓 WebView 的 UA 里同时有 `Version/4.0`（那是
/// WebView 自己的老标记，恒为 4.0）和 `Chrome/<真版本>`。读错那个就会
/// 把所有机器都判成「版本 4，太低了」。
WebViewVersionCheck checkWebViewVersion(String userAgent) {
  final match = RegExp(r'Chrome/(\d+)\.(\d+)\.(\d+)\.(\d+)')
      .firstMatch(userAgent);
  if (match == null) {
    return const WebViewVersionCheck(major: 0, display: '', tooLow: false);
  }
  final major = int.tryParse(match.group(1) ?? '') ?? 0;
  final display = match.group(0)!.substring('Chrome/'.length);
  return WebViewVersionCheck(
    major: major,
    display: display,
    tooLow: major > 0 && major < recommendedWebViewMajor,
  );
}
