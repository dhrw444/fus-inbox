/// 从站点拿「挑战参数」—— 这是能**单独渲染出验证框**的前提。
///
/// ## 为什么需要它
///
/// 站点把验证框塞在自己的页面里（`reader.js` 动态 `turnstile.render`），
/// 所以露出收件页时用户看到的是**整个网站**，而不是一个干净的验证界面。
/// Han1meViewer 那边看着「只有一个验证弹窗」，是因为它拦的是**页面请求**，
/// Cloudflare 直接回了挑战页 —— 那页面本来就没有网站内容。
///
/// 本站不一样：被拦的是 API（`/sms-api/v1/*`），返回的是 JSON 不是挑战页。
/// 所以不能照搬「把被拦 URL 装进 WebView」。能做的是：
///
/// 1. `POST /sms-api/v1/session`（带自己生成的 ECDSA P-256 公钥）
/// 2. 站点回 `403 + reader_verification_required`，**body 里带着**
///    `sitekey` / `action` / `cdata` / `challenge_id`
/// 3. 拿这三个值在自己的页面里 `turnstile.render()` —— 屏幕上就只有
///    那个验证框，没有网站
///
/// 这一步只做「拿参数」。真正的渲染在 `challenge_overlay.dart` 里 ——
/// 它在**收件页自己**（站点源）上盖一层覆盖层。
///
/// ## 为什么不在这里生成密钥
///
/// 站点只校验公钥的**格式**（JWK 里 `kty/crv/x/y` 四段），不认它是谁 ——
/// 换 grant 时才会验签。这里为了「拿到挑战参数」这一件事，用一对一次性
/// 密钥就够；真正的会话密钥由页面那边的 `reader.js` 自己管（它存在
/// IndexedDB 里，不导出）。所以这里只带一个格式合法的公钥。
library;

import 'dart:convert';

/// 一次挑战的参数。全部来自站点那 403 的响应体。
class const ChallengeParams({
  required this.sitekey,
  required this.action,
  required this.cdata,
}) {
  /// Turnstile 的站点键（`0x4AAAAAA...`）。
  final String sitekey;

  /// 挑战动作名。站点只认 `reader_access`。
  final String action;

  /// 挑战数据（一长串 hex）。**必须原样回传**，它把这次挑战和后续
  /// grant 绑在一起 —— 自己编一个的话，验证通过了也换不到 grant。
  final String cdata;

  /// 三个值缺一个就没法渲染。见文件头。
  bool get complete =>
      sitekey.isNotEmpty && action.isNotEmpty && cdata.isNotEmpty;
}

/// 解析 `POST /sms-api/v1/session` 的响应体。
///
/// 成功（`reader_verification_required`）时返回参数；其它情况返回 null
/// （配额、临时繁忙、格式不对 —— 那些不该走验证界面，各有各的处理）。
ChallengeParams? parseChallengeParams(String body) {
  Object? decoded;
  try {
    decoded = jsonDecode(body);
  } catch (_) {
    return null;
  }
  if (decoded is! Map) return null;
  if (decoded['error'] != 'reader_verification_required') return null;
  final sitekey = decoded['sitekey']?.toString() ?? '';
  final action = decoded['action']?.toString() ?? '';
  final cdata = decoded['cdata']?.toString() ?? '';
  if (sitekey.isEmpty || action.isEmpty || cdata.isEmpty) return null;
  return ChallengeParams(sitekey: sitekey, action: action, cdata: cdata);
}
