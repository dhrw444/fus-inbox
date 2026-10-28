/// WebView 的只读探测：内核自带的默认 UA。
///
/// 「问一句、答一句」的查询，不持有状态、不改变任何东西 —— 和会改变世界的
/// 两类（建引擎、建 WebView2 环境）分开，是因为诊断和启动路径都要调它，
/// 混在工厂文件里会让人不敢 import。
///
/// 探测失败返回空串、不抛：一次探测不该挡住启动，也不该挡住一行日志。
///
/// 这里**只有**这一个函数了。原先还有 `webViewRuntimeVersion()` 和
/// `platformName()`，两者全仓零调用方（只在 `web_engine_factory.dart` 里
/// 被 re-export 出去），属于「留着等以后可能有用」的类型 —— 已删。
library;

import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// 内核自带的默认 UA。
///
/// 这就是「这台机器真实的浏览器身份」的来源：默认 UA 里带着内核自己的
/// 版本号和机型串，把它解析出来当基准，UA 和 client hints 才同源。
///
/// 探测失败返回空串，调用方回落到兜底身份。
Future<String> defaultWebViewUserAgent() async {
  try {
    // 不加 `?? ''`：这方法返回非空 String，兜底永远走不到
    // （analyzer 报 dead_code + dead_null_aware_expression）。
    return await InAppWebViewController.getDefaultUserAgent();
  } catch (_) {
    // 探测失败就是空串 —— 见文件头：不抛、不挡启动。
    return '';
  }
}
