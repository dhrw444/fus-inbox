/// WebView 内核参数。
///
/// 纯数据、无副作用，所以是个顶层函数而不是方法 —— 它只是「这些开关
/// 各自为什么这么设」的集合，不依赖引擎的任何状态。
///
/// ## 只传**改了默认值**的那条
///
/// 下面大部分开关的值等于 `InAppWebViewSettings` 自己的默认值，
/// 显式传一遍会被 `avoid_redundant_argument_values` 判为冗余（CI 跑
/// `--fatal-infos`，会直接挂）。所以它们的**理由写在这里**，
/// 代码里只留真正偏离默认值的那一项。
///
/// 这些是「我们确实依赖、但默认就满足」的：
///
/// - `javaScriptEnabled` —— 整个抓取层的立足点，站点接口要求页面上下文签名。
/// - `domStorageEnabled` / `databaseEnabled` —— 站点把 reader 密钥放在
///   IndexedDB、把「看过哪些号」放在 localStorage。关掉任何一个，
///   站点都会把这次访问当成「全新访客」。
/// - `cacheEnabled` —— 换身份时会显式清缓存，但两次换身份之间要复用。
/// - `thirdPartyCookiesEnabled` —— Turnstile 的挑战页在跨域 iframe 里。
/// - `mediaPlaybackRequiresUserGesture` —— 站点页面上的广告视频不该自动播。
/// - `useWideViewPort` / `loadWithOverviewMode` —— 站点模板是移动端优先的，
///   viewport 要按设备宽度算。
/// - `isInspectable` —— 非调试版不把 WebView 暴露成可调试：站点能探测到
///   `window.__REMOTE_DEBUGGING__` 一类的东西。
library;

import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// 造一套内核参数。[userAgent] 由引擎现推（见 `browser_identity.dart`）。
InAppWebViewSettings engineSettings(String userAgent) => InAppWebViewSettings(
  userAgent: userAgent,
  // 唯一偏离默认值的一条：这一项默认是 **false**，而导航闸门要生效就必须
  // 打开它 —— 关着的话站点内的重定向会直接跑掉，第三方页面一旦被引进来
  // 就能往 JS 通道里塞数据（`onNavigationRequest` 形同虚设）。
  useShouldOverrideUrlLoading: true,
);
