/// WebView 的只读探测函数：默认 UA、运行时版本、平台名。
///
/// 全都是「问一句、答一句」的查询，不持有状态、不改变任何东西 ——
/// 和会改变世界的那两类（建引擎、建 WebView2 环境）分开，是因为诊断
/// 代码最爱调它们，混在工厂文件里会让人不敢 import。
///
/// 探测失败一律返回空串 / 「未知」，不抛：一次探测不该挡住启动，
/// 也不该挡住一行日志。
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
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
    return '';
  }
}

/// 已经装好的 WebView2 版本。只用于诊断。
Future<String> webViewRuntimeVersion() async {
  if (!Platform.isWindows) return '未知';
  try {
    return await WebViewEnvironment.getAvailableVersion() ?? '未安装';
  } catch (_) {
    return '未知';
  }
}

/// 平台名，写日志和提示时用。
String platformName() {
  if (kIsWeb) return 'Web';
  if (Platform.isAndroid) return 'Android';
  if (Platform.isWindows) return 'Windows';
  if (Platform.isLinux) return 'Linux';
  if (Platform.isMacOS) return 'macOS';
  return Platform.operatingSystem;
}
