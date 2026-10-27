/// 原生能力探测。
///
/// 与具体业务无关，只负责问原生侧要几样 Dart 拿不到的东西。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:fus_inbox/core/webview/browser_identity.dart';

/// 原生侧能力查询通道。
const platformWebViewChannel = MethodChannel('fusinbox/webview');

/// 读 Android SDK 版本，决定 WebView 用哪种合成方式。
Future<int?> androidSdkVersion() async {
  try {
    return await platformWebViewChannel
        .invokeMethod<int>('getAndroidSdkVersion')
        .timeout(const Duration(seconds: 1));
  } on MissingPluginException {
    return null;
  } on PlatformException {
    return null;
  } on TimeoutException {
    return null;
  }
}

/// 读某个 URL 下的全部 cookie（含 HttpOnly）。
///
/// 读失败返回空 map，不抛异常——调用方据此区分「没拿到」和
/// 「拿到了但里面没有 cf_clearance」。
Future<Map<String, String>> readCookies(String url) async {
  try {
    final raw = await platformWebViewChannel
        .invokeMapMethod<String, String>('getCookies', {'url': url})
        .timeout(const Duration(seconds: 2));
    return raw ?? const {};
  } on MissingPluginException {
    return const {};
  } on PlatformException catch (e) {
    debugPrint('读 cookie 失败：$e');
    return const {};
  } on TimeoutException {
    return const {};
  }
}

/// 清空 WebView 的全部站点数据（cookie / localStorage / IndexedDB）。
///
/// 站点把访客身份绑在一对 ECDSA 密钥上，密钥存在 IndexedDB。
/// 只换 UA 的话密钥不变，服务端认出的还是同一个身份 —— 那等于没换。
///
/// 原生侧负责 cookie / WebStorage / HTTP 凭据。
/// IndexedDB 没有原生清除 API，必须回到页面里用 JS 删
/// （见 inbox_screen 的 `_clearSiteStorage`），两步都做完才算真的换了。
///
/// 只动 WebView 的站点数据，App 自己的磁盘缓存（号码目录、
/// 收录时间、译文）完全不受影响。
Future<bool> clearBrowsingData() async {
  try {
    final ok = await platformWebViewChannel
        .invokeMethod<bool>('clearBrowsingData')
        .timeout(const Duration(seconds: 4));
    return ok ?? false;
  } on MissingPluginException {
    return false;
  } on PlatformException catch (e) {
    debugPrint('清站点数据失败：$e');
    return false;
  } on TimeoutException {
    debugPrint('清站点数据超时');
    return false;
  }
}

/// 探测设备的真实浏览器身份并装载。
///
/// 这一步必须在**任何网络请求之前**完成：UA 和 client hints 都要用
/// 同一份真实数据，否则又回到「UA 说一个版本、hints 说另一个」的撕裂。
///
/// 探测失败不抛异常——退回 [BrowserIdentity.fallback]，App 照常启动。
/// 一次能力探测不该挡住整个应用。
Future<BrowserIdentity> bootstrapBrowserIdentity() async {
  try {
    final raw = await platformWebViewChannel
        .invokeMapMethod<String, Object?>('getDeviceProfile')
        .timeout(const Duration(seconds: 2));
    if (raw != null) {
      final ua = raw['userAgent'] as String?;
      if (ua != null && ua.isNotEmpty) {
        final identity = parseWebViewUserAgent(
          ua,
          model: raw['model'] as String?,
          platformVersion: raw['release'] as String?,
        );
        initBrowserIdentity(identity);
        return identity;
      }
    }
  } on MissingPluginException {
    // 测试环境或非 Android 平台没有原生实现。
  } on PlatformException catch (e) {
    debugPrint('浏览器身份探测失败：$e');
  } on TimeoutException {
    debugPrint('浏览器身份探测超时，用兜底身份');
  }
  return currentIdentity;
}
