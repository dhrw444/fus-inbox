/// 原生侧的杂项通道。
///
/// 单独一个文件是为了让这条通道有**唯一一个常量**：
/// `setMethodCallHandler` 是覆盖式的，另开一个 `MethodChannel` 挂同名通道
/// 会把原来的整个 handler 顶掉。所以谁要用，都 import 这一个。
///
/// Kotlin 侧（`MainActivity.configureFlutterEngine`）只挂了两个方法：
///
/// | 方法 | 为什么还得走原生 |
/// |---|---|
/// | `applyUserAgentMetadata` | `Sec-CH-UA*` 请求头由引擎按真实内核生成，Dart 侧改不掉；只有 `WebSettingsCompat.setUserAgentMetadata` 能改 |
/// | `openUrl` | 用系统浏览器打开；不引 `url_launcher` 是为了不动 `pubspec.lock` |
///
/// 代理、cookie、清站点数据、装垫片**都不在这里** —— 见
/// `native_capabilities.dart` 顶部那张对照表。
library;

import 'package:flutter/services.dart';

/// 原生侧的杂项通道。
const platformChannel = MethodChannel('fusinbox/webview');
