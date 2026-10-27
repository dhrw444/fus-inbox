/// 原生 HTTP 的请求头。
///
/// ## 为什么要集中管理
///
/// 之前目录页和收录时间各写一套头，且都是手写的假 client hints：
///
/// ```
/// sec-ch-ua: "Chromium";v="120", "Google Chrome";v="120"
/// ```
///
/// 而同一台设备的 WebView 用 Chrome 141 发 `Sec-CH-UA`。同一个 IP
/// 下两个「浏览器」一个报 120 一个报 141，Cloudflare 的
/// bot management 直接就能串起来。
///
/// 现在所有头的值都来自 [currentIdentity]——一份探测自真实 WebView
/// 的身份，UA 版本和 hints 版本永远相等。
library;

import 'dart:io';

import 'package:fus_inbox/core/webview/browser_identity.dart';

/// 站点发的 Cloudflare 通行证。
///
/// 存下来的意义：收件箱 WebView 过完验证后，`cf_clearance` 落在
/// WebView 的 cookie 库里。但号码目录和收录时间走的是原生
/// `dart:io` HttpClient，**不共享 WebView 的 cookie 库**——
/// 不把通行证搬过来，这两条链路每次都要单独被挑战。
///
/// 这也是「老是风控」的一半原因：同一个 App 里，
/// 一条链路带着通行证、另一条裸奔，站点的 bot score 会很难看。
String? _clearance;

/// 记住通行证。由收件页读到后调用。
void rememberClearance(String value) {
  if (value.isNotEmpty) _clearance = value;
}

/// 给一个请求装上一整套真实 Chrome 会发的头。
///
/// [base] 站点根（用来推 `sec-fetch-site`），[referer] 上一页地址。
/// 参数可省，省了就按「直接导航」发。
void applyBrowserHeaders(
  HttpHeaders headers, {
  String? base,
  String? referer,
  bool sameSite = true,
}) {
  final id = currentIdentity;

  headers
    ..set(HttpHeaders.userAgentHeader, id.userAgent)
    ..set(
      HttpHeaders.acceptHeader,
      'text/html,application/xhtml+xml,application/xml;q=0.9,'
      'image/avif,image/webp,image/apng,*/*;q=0.8',
    )
    ..set(HttpHeaders.acceptLanguageHeader, 'en-US,en;q=0.9')
    // 客户端提示必须和 UA 同步。这三行是 Cloudflare 判定
    // 「真浏览器还是拼凑」的核心依据，一个都不能少、不能错。
    ..set('sec-ch-ua', id.secChUa)
    ..set('sec-ch-ua-mobile', id.isMobile ? '?1' : '?0')
    ..set('sec-ch-ua-platform', id.secChUaPlatform)
    ..set('sec-fetch-dest', 'document')
    ..set('sec-fetch-mode', 'navigate')
    ..set('sec-fetch-site', sameSite ? 'same-origin' : 'none')
    ..set('sec-fetch-user', '?1')
    ..set('upgrade-insecure-requests', '1');

  // 机型和平台版本是可选的（Chrome 只在部分请求里发），
  // 但既然拿得到真实值就发——少发反而让「这串 UA 和 hints 对得上」
  // 少了一层佐证。
  if (id.model.isNotEmpty) {
    headers.set('sec-ch-ua-model', id.secChUaModel);
  }
  if (id.platformVersion.isNotEmpty) {
    headers.set('sec-ch-ua-platform-version', '"${id.platformVersion}.0.0"');
  }
  if (referer != null) {
    headers.set(HttpHeaders.refererHeader, referer);
  } else if (base != null) {
    headers.set(HttpHeaders.refererHeader, '$base/numbers/');
  }

  // 有通行证就带上。没有不发——发个空的 cf_clearance 反而是
  // 明确的「我试过但没拿到」信号。
  final clearance = _clearance;
  if (clearance != null) {
    headers.set(HttpHeaders.cookieHeader, 'cf_clearance=$clearance');
  }
}
