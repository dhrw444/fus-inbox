/// 按平台造 [WebEngine]。
///
/// **同步是刻意的**：`initState` 里就要拿到它。这里不等任何异步 ——
/// Windows 的 WebView2 环境在 App 启动阶段已经由
/// `webview2_bootstrap.dart` 的 [ensureWebViewEnvironment] 建好，
/// 这里只是把它和身份一起交给引擎。
///
/// ## 为什么这里**没有**代理参数
///
/// 曾经有过 `proxyHost` / `proxyPort` 两个参数，但它们是死的：引擎从来
/// 没读过它们。代理在这个项目里是**进程级**的东西，不是「哪个页面用哪个
/// 引擎」——Windows 的 WebView2 代理是环境创建参数（在
/// [ensureWebViewEnvironment] 里定死，指向常驻桥），Android 的走
/// `ProxyController`（在 `core/proxy/native_proxy.dart` 里）。**两个平台
/// 都不需要引擎自己知道代理。** 留着这对参数只会让人以为「引擎能按页换
/// 出口」，而实际不会。
///
/// 其余两个文件是从这里按职责拆出去的：
/// `webview2_bootstrap.dart`（Windows 那个「第一次创建之前」的环境）、
/// `webview_info.dart`（只读的探测函数）。
library;

import 'package:fus_inbox/platform/inapp_web_engine.dart';
import 'package:fus_inbox/platform/web_engine.dart';
import 'package:fus_inbox/platform/webview2_bootstrap.dart';
// 拆出去的那两块从老入口原样转出口：main.dart / native_capabilities.dart
// 的 import 一行不用改。
export 'package:fus_inbox/platform/webview2_bootstrap.dart'
    show ensureWebViewEnvironment;
export 'package:fus_inbox/platform/webview_info.dart'
    show defaultWebViewUserAgent;

/// 造一个引擎。
WebEngine createWebEngine({required String userAgent}) {
  return InAppWebEngine(
    userAgent: userAgent,
    environment: windowsWebViewEnvironment,
  );
}
