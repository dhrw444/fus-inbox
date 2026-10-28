/// 平台能力与浏览器身份。
///
/// ## 这个文件现在只剩什么
///
/// 换到 `flutter_inappwebview` 之后，原来靠原生通道做的四件事有三件被
/// 插件自己覆盖了，全部搬走：
///
/// | 原来 | 现在 |
/// |---|---|
/// | `installBrowserShim`（通道 → Kotlin 拼 JS） | `browser_shim.dart`，两端同一份 JS |
/// | `readCookies` | `WebEngine.readCookies` |
/// | `clearBrowsingData` | `WebEngine.clearSiteData` |
/// | `getDeviceProfile` | `WebEngine.defaultUserAgent` |
///
/// 剩下的都是**这个 App 自己的事**，跟用哪个 WebView 包无关：
/// 浏览器身份的探底与落盘、以及「用系统浏览器打开链接」。
library;

import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:fus_inbox/core/log.dart';
import 'package:fus_inbox/core/prefs/storage_keys.dart';
import 'package:fus_inbox/core/webview/browser_identity.dart';
import 'package:fus_inbox/core/webview/platform_channel.dart';
import 'package:fus_inbox/platform/web_engine_factory.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 交给系统浏览器打开一个链接。
///
/// 走原生而不是 WebView：用户点仓库链接是想在真浏览器里看。
/// 设备上没有能处理该 URL 的应用时返回 false，调用方据此提示。
Future<bool> openExternalUrl(String url) async {
  try {
    final ok = await platformChannel
        .invokeMethod<bool>('openUrl', {'url': url})
        .timeout(const Duration(seconds: 2));
    return ok ?? false;
  } on MissingPluginException {
    return false;
  } on PlatformException catch (e) {
    logLine('打开链接失败：$e');
    return false;
  } on TimeoutException {
    return false;
  }
}

/// 探测设备的真实浏览器身份并装载。
///
/// 这一步必须在**任何网络请求之前**完成：UA 和 client hints 都要用同一份
/// 真实数据，否则又回到「UA 说一个版本、hints 说另一个」的撕裂。
///
/// 探测失败不抛异常 —— 退回 [BrowserIdentity.fallback]，App 照常启动。
/// 一次能力探测不该挡住整个应用。
Future<BrowserIdentity> bootstrapBrowserIdentity() async {
  // 先看磁盘上有没有上次用的身份。有就先用它 —— 站点那边每对 reader 密钥
  // 是跟身份绑的，重启回到设备真实值等于拿旧密钥配新机型，反而更容易被认出来。
  BrowserIdentity? saved;
  try {
    final prefs = await SharedPreferences.getInstance();
    saved = identityFromJson(
      jsonDecode(kIdentityCurrentKey.readString(prefs) ?? 'null'),
    );
    if (saved != null) restoreIdentity(saved);
    // 探测失败时也得有基准可用。先读上次记下的，下面探测成功会用真值覆盖。
    final km = kIdentityKernelKey.readInt(prefs);
    if (km != null) noteKernelMajor('$km');
  } catch (e) {
    logLine('读回浏览器身份失败：$e');
  }

  try {
    // 内核的默认 UA 里带着它自己的版本号和机型串 —— 这就是我们要探的
    // 「这台机器真实的浏览器身份」。跨平台可用，不再走原生通道。
    final ua = await defaultWebViewUserAgent();
    if (ua.isNotEmpty) {
      // 探测出来的真实身份只在**第一次**用 —— 之后一切以磁盘上那份为准，
      // 否则用户换过的身份每次启动都会被真实值顶掉。
      final probed = parseWebViewUserAgent(ua);
      // 两件事的规则**不一样**，别混：
      //   身份     → 认磁盘（saved 优先），探测值只在第一次用；
      //   内核基准 → 认探测，因为磁盘那份可能已经被轮换漂过了，
      //              拿它当基准等于把漂移固化。
      noteKernelMajor(probed.chromeMajor);
      await _persistKernelMajor();
      // **平台不一致时，磁盘上那份必须丢掉。**
      //
      // `saved ?? probed` 那种无条件优先在这里是错的：用户在安卓上用过这个
      // 号、之后在 Windows 上打开（或者反过来），磁盘上那份带着**另一个
      // 平台**的 UA 和 `Sec-CH-UA-Platform`。留着它就回到
      // 「UA 说安卓、底下引擎是 WebView2」的撕裂 —— 而 client hints 是引擎
      // 按自己的真值发的，我们从 Dart 侧改不掉，也就是**圆不回来**。
      //
      // 同平台才认磁盘：那种情况下保留上次的身份是对的（站点那边 reader
      // 密钥跟身份绑着，重启换回设备真实值等于拿旧密钥配新机型）。
      final savedSamePlatform =
          saved != null && saved.platform == probed.platform;
      final identity = savedSamePlatform ? saved : probed;
      initBrowserIdentity(identity);
      await _persistIdentity(identity);
      return identity;
    }
  } catch (e) {
    logLine('浏览器身份探测失败：$e');
  }
  // 探测失败也要把**跨平台**的磁盘身份丢掉。
  //
  // 上面那条 `saved ?? probed` 的分支已经在正常路径上做了同平台校验，
  // 但这条早退路径绕过了它：安卓上存的身份，在 Windows 上如果探测失败
  // （没有 WebView2 运行时之类），就会继续拿着那条安卓身份跑 ——
  // 于是「UA 说安卓、引擎是 WebView2」的撕裂又回来了，而这次连
  // 探测值都没有，纠正不了。
  //
  // 判据用「磁盘身份的平台 == 本机平台」：本机是哪个平台可以从
  // 已有信息推（`Platform.isWindows`），不依赖探测成功。
  final hostPlatform = Platform.isWindows
      ? BrowserIdentity.platformWindows
      : BrowserIdentity.platformAndroid;
  if (saved != null && saved.platform != hostPlatform) {
    logLine('磁盘上的浏览器身份属于另一个平台（${saved.platform} → $hostPlatform），已丢弃。');
    restoreIdentity(BrowserIdentity.fallback);
  }
  return currentIdentity;
}

/// 记下当前身份。换身份之后必须调，否则重启就丢了。
Future<void> persistCurrentIdentity() => _persistIdentity(currentIdentity);

Future<void> _persistIdentity(BrowserIdentity identity) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    await kIdentityCurrentKey.writeString(
      prefs,
      jsonEncode(identityToJson(identity)),
    );
  } catch (e) {
    logLine('存浏览器身份失败：$e');
  }
}

/// 记下内核基准。只在探测到真实 UA 之后调。
///
/// 和 [_persistIdentity] 分开存：那个存的是「现在假装成哪台设备」（会随
/// 换身份变），这个存的是「这台机器真实的内核是多少」（永远不变）。
/// 混在一起存，换身份就会把基准一起改掉 —— 那正是版本号单向漂移的成因。
Future<void> _persistKernelMajor() async {
  final km = kernelMajor;
  if (km == null) return;
  try {
    final prefs = await SharedPreferences.getInstance();
    await kIdentityKernelKey.writeInt(prefs, km);
  } catch (e) {
    logLine('存内核基准失败：$e');
  }
}
