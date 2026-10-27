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

/// 内核基准的落盘键。
///
/// 单独存一份，是为了在原生探测失败时也能拿到基准 —— 没有它，
/// `rotateIdentity` / `mintIdentity` 又会退回「拿自己上一次的输出当基准」，
/// 继续单向下漂（见 browser_identity.dart 的 `_kernelMajor`）。
const _kKernelKey = 'fus:identity:kernel:v1';

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
  // appVersion 要**完整四段**，和 UA 里 Chrome/ 后面那截逐字相同。
  //
  // 真 Chrome 的 navigator.userAgentData.uaFullVersion 与 UA 里的版本
  // 完全一致（4 段，如 141.0.7390.122）；fullVersionList 里真实品牌的
  // version 同样是 4 段。以前这里 `take(3)` 截成三段，注释还写着
  // 「client hints 的 uaFullVersion 就是这个格式」—— 那句话是错的，
  // 产物是：navigator.userAgent 说 141.0.7390.122、userAgentData 说
  // 141.0.7390，Cloudflare/Turnstile 一交叉核对就对上，**每一页都存在**。
  final parts = RegExp(r'Chrome/([\d.]+)').firstMatch(id.userAgent);
  final appVersion = parts?.group(1) ?? '';
  // 版本取不到就别装了：一个 uaFullVersion 为空的垫片，比没有垫片更像
  // 一个被人改过的浏览器。
  if (appVersion.isEmpty) return false;
  // **一份参数喂两个通道。**
  //
  // 垫片改的是页面里 JS 读到的 navigator.userAgentData；
  // applyUserAgentMetadata 改的是引擎真正发出去的 Sec-CH-UA 请求头。
  // 两处用不同的数（或只调了其中一个）等于亲手造出一个「JS 说 A、
  // 请求头说 B」的矛盾 —— 而 Cloudflare 两边都能看到。
  final args = <String, Object?>{
    'chromeMajor': id.chromeMajor,
    'appVersion': appVersion,
    // platformVersion 必须跟着身份走。
    //
    // 原生头那边发的是 '${id.platformVersion}.0.0'（http_headers.dart），
    // 垫片以前却写死 '14.0.0'：除 Android 14 之外的每台设备，页面里
    // getHighEntropyValues(['platformVersion']) 得到 14.0.0，而 UA 说
    // Android 16、同 App 的原生头也说 16.0.0。这是 100% 触发、
    // 不需要任何竞态的一条自相矛盾。
    'platformVersion': id.platformVersion,
    'platform': 'Android',
    'model': id.model,
    'isMobile': id.isMobile,
  };
  try {
    final ok = await platformWebViewChannel
        .invokeMethod<bool>('installBrowserShim', args)
        .timeout(const Duration(seconds: 2));
    // 请求头那一路单独 try：老内核不支持这个特性是**正常**的，不该连累
    // 垫片 —— 垫片还管着 window.chrome 和 navigator.plugins，
    // 那两个比 client hints 更要紧。
    try {
      await platformWebViewChannel
          .invokeMethod<bool>('applyUserAgentMetadata', args)
          .timeout(const Duration(seconds: 2));
    } catch (e) {
      debugPrint('设 client hints 失败（老内核属正常）：$e');
    }
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
    // 探测失败时也得有基准可用。先读上次记下的，下面探测成功会用真值覆盖。
    final km = prefs.getInt(_kKernelKey);
    if (km != null) noteKernelMajor('$km');
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
        final probed = parseWebViewUserAgent(
          ua,
          model: raw['model'] as String?,
          platformVersion: raw['release'] as String?,
        );
        // 两件事的规则**不一样**，别混：
        //   身份     → 认磁盘（saved 优先），探测值只在第一次用；
        //   内核基准 → 认探测，因为磁盘那份可能已经被轮换漂过了，
        //              拿它当基准等于把漂移固化。
        noteKernelMajor(probed.chromeMajor);
        await _persistKernelMajor();
        final identity = saved ?? probed;
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

/// 记下内核基准。只在原生探测到真实 UA 之后调。
///
/// 和 [_persistIdentity] 分开存：那个存的是「现在假装成哪台设备」（会随
/// 换身份变），这个存的是「这台机器真实的内核是多少」（永远不变）。
/// 混在一起存，换身份就会把基准一起改掉 —— 那正是版本号单向漂移的成因。
Future<void> _persistKernelMajor() async {
  final km = kernelMajor;
  if (km == null) return;
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kKernelKey, km);
  } catch (e) {
    debugPrint('存内核基准失败：$e');
  }
}
