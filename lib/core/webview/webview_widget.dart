/// 跨平台 [WebViewWidget] 构造。
///
/// 与具体业务无关：阅读器和收件箱都用它，避免业务代码互相依赖。
///
/// Android 上按系统版本决定是否启用 hybrid composition —— SDK ≥ 29 用
/// native composition 绕开纹理路径的滚动抖动；Android 10 以下保留默认
/// 模式，省掉逐帧拷贝。系统版本查询走 `fusinbox/webview` 原生通道，
/// 查询失败一律退回插件默认，不让一次能力探测挡住页面渲染。
library;

import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import 'package:fus_inbox/core/webview/native_capabilities.dart';

/// 用给定的 controller 造一个可挂进 widget 树的 [WebViewWidget]。
///
/// 同一个 [WebViewController] 只能对应一个 widget 实例。
Future<WebViewWidget> createPlatformWebView(
  WebViewController controller,
) async {
  var params = PlatformWebViewWidgetCreationParams(
    controller: controller.platform,
  );

  if (WebViewPlatform.instance is AndroidWebViewPlatform) {
    final sdk = await androidSdkVersion();
    final useNativeComposition = sdk != null && sdk >= 29;
    params =
        AndroidWebViewWidgetCreationParams.fromPlatformWebViewWidgetCreationParams(
          params,
          displayWithHybridComposition: useNativeComposition,
        );
  }

  return WebViewWidget.fromPlatformCreationParams(params: params);
}
