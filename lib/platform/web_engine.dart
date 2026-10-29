/// WebView 引擎。**收件页唯一允许碰的 WebView 抽象。**
///
/// ## 为什么要有这一层
///
/// 原来收件页直接依赖 `webview_flutter` 的 `WebViewController`。那个包
/// 到 4.14.1（2026-07）仍然只有 android / ios / macos —— **没有 Windows
/// 实现**，官方也一直没有。要加 Windows x86，就必须换掉它。
///
/// 换成了 `flutter_inappwebview`（一个包覆盖 Android / iOS / macOS /
/// Windows / Linux / Web）。但这个文件的意义不是「换个包」，而是
/// **把收件页和包解耦**：以后任何一个平台实现变了、或者要再换一次包，
/// 只有 `lib/platform/` 下面那几个文件要动，收件页一行不用改。
///
/// ## 契约怎么定的
///
/// 不是照抄某个包的 API，而是**照收件页实际用到的能力**列的。全仓扫过
/// 一遍，用得上的就这些 —— 少一个都编不过，多一个就是给未来留的坑。
///
/// ## 时序是硬要求，不是建议
///
/// 有几件事**必须在加载任何 URL 之前**做完，晚一步就是真实 IP 或者真实
/// 设备指纹先露一次：
///
/// 1. [setUserAgent] —— 第一个请求就已经决定自称谁。代理不在这一层：
///    它是**进程级**的东西（Windows 的 WebView2 环境参数、Android 的
///    ProxyController），统一由 `core/proxy/native_proxy.dart` 管，
///    和「哪个页面用哪个引擎」不是一回事。
/// 2. [injectOnDocumentStart] —— 垫片要在站点脚本读到 `navigator` 之前装上
///
/// 所以这几个方法都设计成「在 [buildView] 之前调」，实现里把它们攒着，
/// 等视图真正创建时一次性交给内核。
library;

import 'package:flutter/widgets.dart';

/// 一个 WebView 会话。
///
/// 生命周期：`create()` → 配置 → [buildView] → [loadUrl] → …→ [dispose]。
///
/// [dispose] 之后其它方法全部当空操作（不抛）：页面销毁和定时器回调之间
/// 有天然的竞态，那种时候抛异常只会把日志淹掉。
///
/// 末尾的 `()` 是主构造器的空标记（本仓统一写法）：这个接口没有构造参数。
abstract class WebEngine() {
  /// 造一个可挂进 widget 树的视图。
  ///
  /// **同一个实例只能调一次** —— 内核里一个控制器对应一个平台视图。
  /// 调用之后各配置方法才真正生效（在调它之前调，会被攒起来一起交下去）。
  Widget buildView({Key? key});

  /// 页面开始加载。
  void onPageStarted(void Function(String url) handler);

  /// 页面加载完成。
  void onPageFinished(void Function(String url) handler);

  /// 网络层错误。**只有主框架的错才该打断收件页** —— 子资源（图床、
  /// 埋点）失败是常态，拿它当页面失败会让每张图挂掉一次就重试一轮。
  void onWebResourceError(void Function(WebEngineError error) handler);

  /// 导航闸门。返回 false 会拦下这次导航。
  ///
  /// 收件页用它把导航限制在站点自己的域名上：JS 通道会把页面发来的
  /// JSON **直接交给状态层**，任何第三方页面拿到通道都是不该有的攻击面。
  /// 放在引擎层是因为「哪些导航算越界」是安全判断，不该分散在各平台的
  /// 实现里各写一遍。
  void onNavigationRequest(bool Function(String url) allow);

  /// 页面里的 JS 通过约定通道发回消息。
  ///
  /// [name] 是通道名（收件页只用一个）；[message] 是 JS 侧
  /// `JSON.stringify` 过的字符串。
  void onMessage(String name, void Function(String message) handler);

  /// 设 UA。每个身份一台「设备」，见 `browser_identity.dart`。
  Future<void> setUserAgent(String userAgent);

  /// 在**页面脚本执行之前**注入 JS。
  ///
  /// 只对之后加载的文档生效，所以必须在 [loadUrl] 之前调。
  void injectOnDocumentStart(String script);

  /// 加载一个 URL。
  Future<void> loadUrl(String url);

  /// 直接装一段 HTML 当页面。
  ///
  /// [baseUrl] 决定**页面算哪个源** —— 验证页必须挂在站点自己的源上，
  /// 否则它里面拉的 `reader.js` 会被 CORS 拦掉、`window.isSecureContext`
  /// 也不成立（站点脚本里明写这两个前提）。
  Future<void> loadHtml(String html, {required String baseUrl});

  /// 在页面里执行一段 JS（不关心返回值）。
  Future<void> runJavaScript(String script);

  /// 执行 JS 并拿回结果。
  ///
  /// 收件页用它读页面里的运行时状态（比如站点自己暴露的会话标记）。
  /// 内核返回的可能是 JSON 串、数字或 null，所以返回 [Object] 而不是
  /// 硬转 String —— 调用方自己判类型。
  Future<Object?> evaluateJavascript(String script);

  /// 重新加载当前页面。
  ///
  /// 和 [loadUrl] 分开：`reload` 走浏览器缓存、复用当前会话，而
  /// `loadUrl` 是一次全新导航。换身份之后要的是后者（见
  /// `IdentityRotator.wipeThenReload`）。
  Future<void> reload();

  /// 读指定 URL 的 cookie（含 HttpOnly）。
  ///
  /// 收件页用它把 `cf_clearance` 搬到 `dart:io` 那边 —— 两条链路不共享
  /// cookie 库，不搬的话目录和收录时间每次都要单独被挑战。
  Future<Map<String, String>> readCookies(String url);

  /// 清掉这个应用在 WebView 里的**全部**站点数据
  /// （cookie / localStorage / IndexedDB / cache）。
  ///
  /// 换身份时必须清：站点认人靠 IndexedDB 里那对 ECDSA 密钥，只换 UA
  /// 的话新身份会带着旧密钥回来，站点眼里还是同一个人。
  Future<bool> clearSiteData();

  /// 内核的默认 UA。用于第一次探测设备真实身份。
  Future<String> defaultUserAgent();

  /// 收尾。
  Future<void> dispose();
}

/// 主框架错误。
class const WebEngineError({
  required this.description,
  required this.code,
  required this.isForMainFrame,
  this.url = '',
}) {
  /// 内核给的原始描述（**英文**，来自 Chromium 的 net error）。
  ///
  /// 只该进日志，不该直接贴给用户 —— 见 [userMessage]。
  final String description;

  final int code;

  /// 是不是主框架的错。
  final bool isForMainFrame;

  final String url;

  /// 给用户看的一句话。
  ///
  /// ## 为什么不直接显示 [description]
  ///
  /// 内核报的是 `net::ERR_NAME_NOT_RESOLVED` 这类英文短语。用户看到的是
  /// 「页面加载失败（-105）：net::ERR_NAME_NOT_RESOLVED」—— 既不知道
  /// 是什么坏了，也不知道该做什么。
  ///
  /// 这里按网络的几个真实故障点分类，每一类给一句**能照着做**的话。
  /// 认不出来的错误才退回原始描述，那时至少还留了排查线索。
  String get userMessage {
    // Chromium 的 net error 常量。只列这个 App 真会撞上的几种：
    // 域名解析、连不上、超时、TLS、被拦。
    return switch (code) {
      -105 || -137 => '找不到服务器。检查一下网络，或者稍后再试。',
      -106 => '网络断了。连上网络再重新打开这个号。',
      -102 || -118 => '连接超时。可能是代理不通，换一条出口再试。',
      -101 || -100 || -107 || -109 => '连不上服务器。检查代理是不是还活着。',
      -200 || -201 || -202 => '站点的证书有问题。如果开了代理，先关掉它再试。',
      -20 => '请求被中断了。重新加载一次试试。',
      -27 => '页面太大，加载到一半失败了。重新加载一次试试。',
      _ => description.isEmpty ? '页面加载失败（$code）。' : description,
    };
  }
}
