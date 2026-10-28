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

/// 拿这张通行证时用的是哪个 UA。
///
/// `cf_clearance` 是绑在 (IP, UA) 上的：同一个 App 换了身份或换了出口
/// 之后再用旧证，等于拿着上一个身份的通行证去开门 —— 比不带更像伪造。
String? _clearanceUserAgent;

/// 记住通行证。由收件页读到后调用。
void rememberClearance(String value) {
  if (value.isEmpty) return;
  _clearance = value;
  _clearanceUserAgent = currentUserAgent;
}

/// 忘掉通行证。
///
/// 换身份 / 换出口 / 清浏览数据之后应当显式调用。
/// （就算漏了也不致命：[applyBrowserHeaders] 里还有一道身份比对兜底。）
void forgetClearance() {
  _clearance = null;
  _clearanceUserAgent = null;
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
    // 用派生 getter，不要在这里拼 —— 两个平台的形状不一样：
    // 安卓存的是 `14`（真 Chrome 发 `"14.0.0"`），Windows 存的是
    // `10.0.0`（本身就是完整四段式）。无条件补 `.0.0` 会在 Windows 上
    // 拼出 `"10.0.0.0.0"`，一个不存在的版本号。
    headers.set('sec-ch-ua-platform-version', id.secChUaPlatformVersion);
  }
  if (referer != null) {
    headers.set(HttpHeaders.refererHeader, referer);
  } else if (base != null) {
    headers.set(HttpHeaders.refererHeader, '$base/numbers/');
  }

  // 有通行证就带上 —— 但**必须还是拿证时那台设备**。
  //
  // 以前这里只判 `_clearance != null`，而全仓只有 remember 没有 forget：
  // 换身份、换出口、清浏览数据之后，旧证会一直发到下一次
  // markReady → _syncClearance 把它覆盖为止；如果新会话一直没 ready
  // （比如卡在验证），旧证就被无限期发下去。
  final clearance = _clearance;
  if (clearance != null && _clearanceUserAgent == currentUserAgent) {
    // **追加，不是覆盖。**
    //
    // `set` 会把整个 Cookie 头替换掉。现在的两个调用点都是从
    // `_http.getUrl(...)` 刚拿到的**新请求**、之前没设过 cookie，所以
    // 覆盖也无害 —— 但这是靠「调用顺序恰好如此」维持的，哪天有人先往
    // 同一个请求里塞了会话 cookie 再调这里，那些 cookie 会被静默抹掉，
    // 而症状（站点认不出会话）离这里很远，很难查。
    //
    // 一句话的代价买掉这个地雷。
    final existing = headers.value(HttpHeaders.cookieHeader);
    final jar = existing == null || existing.isEmpty
        ? 'cf_clearance=$clearance'
        : '$existing; cf_clearance=$clearance';
    headers.set(HttpHeaders.cookieHeader, jar);
  }
}
