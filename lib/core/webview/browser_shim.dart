/// 浏览器能力垫片的装配。
///
/// ## 它做什么
///
/// 把 `assets/js/browser_shim.js` 装到页面上，补掉各家 WebView 内核都
/// 缺的那三样「真 Chrome 一定有」的东西（`navigator.userAgentData`、
/// `window.chrome`、`navigator.plugins`）。Cloudflare Turnstile 会先查
/// 它们，缺一个就会把 UA 写得多像都判成伪装。
///
/// ## 为什么单独一个文件
///
/// 原来这段逻辑在 `native_capabilities.dart` 里，靠原生通道把身份传进
/// Kotlin 拼字符串。加 Windows 之后那条路走不通了（没有 Kotlin），而且
/// **两端必须是同一份伪装** —— 否则「Android 上是 Chrome、Windows 上是
/// WebView2」本身就是个能被串联的特征。
///
/// 所以改成：脚本是**一份静态资源**，身份值以 `window.__fusSeed` 的形式
/// 拼在它前面。装配只做两件事 —— 读资源、拼兜底值。
///
/// ## 兜底值为什么只是兜底
///
/// 脚本里所有身份值都**从当下那串 UA 现推**，`__fusSeed` 只在整个 UA
/// 解不出来时才用。原因是注入只能加不能删（脚本开头有 `__fusShimmed`
/// 守卫，先装的那份永远赢），烧死版本号会停在上一次的身份上，而且每换
/// 一次身份就多累积一层矛盾。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/services.dart' show rootBundle;

import 'package:fus_inbox/core/log.dart';
import 'package:fus_inbox/core/webview/browser_identity.dart';
import 'package:fus_inbox/core/webview/platform_channel.dart';

const _kShimAsset = 'assets/js/browser_shim.js';

/// 垫片源码。读一次就缓存 —— 每个号都要装一次，不该每次都读资源。
String? _source;

Future<String> browserShimSource() async {
  final cached = _source;
  if (cached != null) return cached;
  final text = await rootBundle.loadString(_kShimAsset);
  _source = text;
  return text;
}

/// 组装最终注入的脚本：兜底值 + 垫片本体。
///
/// 返回空串表示**装不了**（UA 里没有 Chrome 版本号）—— 调用方应当把它
/// 当成「这次不装」，而不是硬塞一个残缺的垫片进去：一个
/// `uaFullVersion` 为空的垫片比没有垫片更像被人改过的浏览器。
Future<String> buildBrowserShim() async {
  final id = currentIdentity;

  // appVersion 要**完整四段**，和 UA 里 `Chrome/` 后面那截逐字相同。
  //
  // 真 Chrome 的 `navigator.userAgentData.uaFullVersion` 与 UA 里的版本
  // 完全一致（4 段，如 141.0.7390.122）。以前这里 `take(3)` 截成三段，
  // 产物是「UA 说 141.0.7390.122、userAgentData 说 141.0.7390」——
  // Cloudflare 一交叉核对就对上，而且是每一页都存在。
  final parts = RegExp(r'Chrome/([\d.]+)').firstMatch(id.userAgent);
  final appVersion = parts?.group(1) ?? '';
  if (appVersion.isEmpty) return '';

  final seed = <String, Object?>{
    'full': appVersion,
    'major': id.chromeMajor,
    'plat': id.platform,
    'mobile': id.isMobile,
    // 平台版本走 `platformVersionHint` —— 和原生请求头**同一个收口点**。
    //
    // 这里以前自己拼 `'${id.platformVersion}.0.0'`，于是我把 http_headers
    // 那边改成按平台分支之后，垫片没跟着改：Windows 的 platformVersion
    // 本身就是 `10.0.0`，再补一次 `.0.0` 就产出五段的 `10.0.0.0.0`。
    // 而真 Chrome 在 Windows 上只有四段。
    'pv': id.platformVersionHint,
    'mdl': id.model,
  };

  final body = await browserShimSource();
  return 'window.__fusSeed=${jsonEncode(seed)};\n$body';
}

/// 原生请求头那一路：`Sec-CH-UA`。
///
/// ## 为什么和垫片是一对
///
/// 垫片改的是页面里 **JS 读到的** `navigator.userAgentData`；这个方法改的
/// 是引擎真正**发出去**的请求头。两处必须同源 —— 只调其中一个，等于亲手
/// 造出一个「JS 说 A、请求头说 B」的矛盾，而 Cloudflare 两边都能看到。
///
/// 参数和 [buildBrowserShim] 一样从 [currentIdentity] 现推，所以不会漂。
///
/// ## 失败不是错误
///
/// 老内核没有 `USER_AGENT_METADATA` 这个特性，返回 false 属正常 ——
/// 那种情况只能靠「身份不偏离内核」兜底（见 `browser_identity.dart` 里
/// 的基准逻辑）。所以这里只记一笔，不往上抛。
///
/// Windows 直接返回：WebView2 按自己的 UA 生成 client hints，
/// 而我们的 UA 本来就是从它那儿解析出来的，两边天然一致。
Future<void> applyClientHints() async {
  if (!Platform.isAndroid) return;

  final id = currentIdentity;
  final parts = RegExp(r'Chrome/([\d.]+)').firstMatch(id.userAgent);
  final appVersion = parts?.group(1) ?? '';
  if (appVersion.isEmpty) return;

  try {
    await platformChannel
        .invokeMethod<bool>('applyUserAgentMetadata', <String, Object?>{
          'chromeMajor': id.chromeMajor,
          'appVersion': appVersion,
          'platformVersion': id.platformVersion,
          'platform': id.platform,
          'model': id.model,
          'isMobile': id.isMobile,
        })
        .timeout(const Duration(seconds: 2));
  } catch (e) {
    logLine('设 client hints 失败（老内核属正常）：$e');
  }
}
