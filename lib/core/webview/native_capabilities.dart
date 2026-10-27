/// 原生能力探测。
///
/// 与具体业务无关，只负责问原生侧要几样 Dart 拿不到的东西。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fus_inbox/core/webview/browser_identity.dart';

/// 原生侧能力查询通道。
const platformWebViewChannel = MethodChannel('fusinbox/webview');

/// 浏览器身份在磁盘上的键。
const _kIdentityKey = 'fus:identity:current:v1';

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

/// 交给系统浏览器打开一个链接。
///
/// 走原生而不是 WebView：用户点仓库链接是想在真浏览器里看。
/// 设备上没有能处理该 URL 的应用时返回 false，调用方据此提示。
Future<bool> openExternalUrl(String url) async {
  try {
    final ok = await platformWebViewChannel
        .invokeMethod<bool>('openUrl', {'url': url})
        .timeout(const Duration(seconds: 2));
    return ok ?? false;
  } on MissingPluginException {
    return false;
  } on PlatformException catch (e) {
    debugPrint('打开链接失败：$e');
    return false;
  } on TimeoutException {
    return false;
  }
}

/// 给 WebView 装上浏览器能力垫片。
///
/// ## 为什么
///
/// Android System WebView 内核**不提供**三样真 Chrome 必有之物：
///
///   navigator.userAgentData  → undefined
///   window.chrome            → undefined
///   navigator.plugins        → 空
///
/// Cloudflare 的 Turnstile 先查这三项。缺任何一样，UA 写得多像
/// 都会被判成伪装的浏览器 —— 这正是「只换 UA 反而更容易被风控」
/// 的根本原因：UA 自称 Chrome，JS 却探测不到 Chrome 该有的能力。
///
/// ## 为什么走原生
///
/// 必须用 `addDocumentStartJavaScript` —— 注入时机是「文档创建后、
/// **页面任何脚本执行前**」。用 Dart 的 runJavaScript 太晚了：
/// 那时站点脚本和 Turnstile 早就跑完并做出判定。
///
/// ## 传入的身份
///
/// 全部取自 [currentIdentity]，和 UA / Sec-CH-UA 同源。
/// 版本号一旦对不上，垫片自己就成了新的矛盾点。
///
/// 返回 false 表示这台设备的内核不支持（89 以下），页面照常打开。
Future<bool> installBrowserShim() async {
  final id = currentIdentity;
  // appVersion 要三段，形如 134.0.6998。UA 里是完整四段，
  // 这里截前三段 —— client hints 的 uaFullVersion 就是这个格式。
  final parts = RegExp(r'Chrome/([\d.]+)').firstMatch(id.userAgent);
  final full = parts?.group(1) ?? '';
  final segments = full.split('.');
  final appVersion = segments.length >= 3
      ? segments.take(3).join('.')
      : '$full.0.0';
  try {
    final ok = await platformWebViewChannel
        .invokeMethod<bool>('installBrowserShim', {
          'chromeMajor': id.chromeMajor,
          'appVersion': appVersion,
          'platform': 'Android',
          'model': id.model,
          'isMobile': id.isMobile,
        })
        .timeout(const Duration(seconds: 2));
    return ok ?? false;
  } on MissingPluginException {
    return false;
  } on PlatformException catch (e) {
    debugPrint('装垫片失败：$e');
    return false;
  } on TimeoutException {
    return false;
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
  // 先看磁盘上有没有上次用的身份。有就先用它 —— 站点那边每对
  // reader 密钥是跟身份绑的，重启回到设备真实值等于拿旧密钥配新
  // 机型，反而更容易被认出来。探测失败时也回落到它，不要落回
  // 出厂兜底值（那会换掉用户的身份）。
  BrowserIdentity? saved;
  try {
    final prefs = await SharedPreferences.getInstance();
    saved = identityFromJson(
      jsonDecode(prefs.getString(_kIdentityKey) ?? 'null'),
    );
    if (saved != null) restoreIdentity(saved);
  } catch (e) {
    debugPrint('读回浏览器身份失败：$e');
  }

  try {
    final raw = await platformWebViewChannel
        .invokeMapMethod<String, Object?>('getDeviceProfile')
        .timeout(const Duration(seconds: 2));
    if (raw != null) {
      final ua = raw['userAgent'] as String?;
      if (ua != null && ua.isNotEmpty) {
        // 探测出来的真实身份只在**第一次**用 —— 之后一切以磁盘上
        // 那份为准，否则用户换过的身份每次启动都会被真实值顶掉。
        final identity =
            saved ??
            parseWebViewUserAgent(
              ua,
              model: raw['model'] as String?,
              platformVersion: raw['release'] as String?,
            );
        initBrowserIdentity(identity);
        await _persistIdentity(identity);
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

/// 记下当前身份。换身份之后必须调，否则重启就丢了。
Future<void> persistCurrentIdentity() async {
  await _persistIdentity(currentIdentity);
}

Future<void> _persistIdentity(BrowserIdentity identity) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kIdentityKey, jsonEncode(identityToJson(identity)));
  } catch (e) {
    debugPrint('存浏览器身份失败：$e');
  }
}
