/// 阅读器用的 [WebViewWidget] 工厂。
///
/// 实现已抽到 `core/webview/webview_widget.dart`，这里只保留旧入口，
/// 让阅读器与它的测试不必同时改动。[readerPlatformChannel] 一并转出，
/// 原有测试仍然可以 mock 它。
library;

import 'package:webview_flutter/webview_flutter.dart';

import 'package:fus_inbox/core/webview/webview_widget.dart';

export 'package:fus_inbox/core/webview/webview_widget.dart'
    show platformWebViewChannel;

/// 保留的旧名字，等价于 [platformWebViewChannel]。
const readerPlatformChannel = platformWebViewChannel;

Future<WebViewWidget> createReaderWebView(WebViewController controller) =>
    createPlatformWebView(controller);
