/// 收件箱领域模型。
///
/// 字段名与站点 `assets/live.js` 的 `messageCard(m)` 一一对应：
///   m.event_id / m.sender / m.content / m.received_at / m.copy_code /
///   m.protected / m.receiver
/// 由 WebView 内的 `assets/js/fus_inbox.js` 归一化后经 `FusInbox` 通道回传。
library;

/// 单条短信。
class const InboxMessage({
  required this.id,
  required this.text,
  this.code = '',
  this.sender = '',
  this.receivedAt = '',
  this.phone = '',
  this.isNew = false,
  this.isProtected = false,
}) {
  /// 站点的事件 id（`data-event-id` / `event_id`），去重靠它。
  final String id;

  /// 短信正文。
  final String text;

  /// 验证码。站点给了 `copy_code` 就用它，否则由正文提取。
  final String code;

  /// 发送方。
  final String sender;

  /// 收到时间（ISO 串）。
  final String receivedAt;

  /// 接收号码。
  final String phone;

  /// 本次会话中新到的。
  final bool isNew;

  /// 站点标记为「暂时不可读」。
  final bool isProtected;

  bool get hasCode => code.isNotEmpty;

  static String _s(Object? v) => v is String ? v : (v == null ? '' : '$v');

  factory InboxMessage.fromJson(Map<String, dynamic> json) {
    return InboxMessage(
      id: _s(json['id']),
      text: _s(json['text']),
      code: _s(json['code']),
      sender: _s(json['sender']),
      receivedAt: _s(json['time']),
      phone: _s(json['phone']),
      isProtected: json['protected'] == true,
    );
  }

  InboxMessage copyWith({bool? isNew}) => InboxMessage(
    id: id,
    text: text,
    code: code,
    sender: sender,
    receivedAt: receivedAt,
    phone: phone,
    isNew: isNew ?? this.isNew,
    isProtected: isProtected,
  );
}

/// 抓取状态。
enum InboxPhase() {
  /// 页面加载中 / 还没拿到内容。
  waiting,

  /// 已解析出至少一条短信。
  ready,

  /// 页面报错。
  failed,
}

/// 站点主动拒绝给消息。
///
/// 三种来自 `X-Fair-Use` 响应头（见 assets/js/fus_inbox.js 的
/// `holdFromResponse`）：
enum SiteHoldKind() {
  /// `429 + pause`：免费配额用完了。站点限制新号码，
  /// 已打开过的号码在 24 小时内还能读。
  quota,

  /// `403 + challenge`：要过人机验证。
  challenge,

  /// `503 + unavailable`：服务端临时繁忙。和配额无关，等它自己好。
  temporary,
}

/// 站点拒绝的详情。
///
/// 四个字段纯数据、无派生逻辑，天生该用主构造器。但 Dart 3.13 的
/// 「主构造器」写法（`class Foo({required this.x});` 不带类体）在本机
/// 实测报 `'x' isn't an instance field of this class`，根本编译不过 ——
/// lint 要求的写法这套 SDK 还不支持。只能保留字段声明 + ignore。
// ignore: use_primary_constructors
class const SiteHold({
  required this.kind,
  required this.title,
  required this.message,
  this.retrySeconds = 0,
  this.newInboxesOnly = false,
}) {
  final SiteHoldKind kind;

  /// 站点自己的标题（从它渲染的 DOM 里抄的），没有就是我们的译法。
  final String title;

  final String message;

  /// 站点建议多少秒后再试。0 表示它没说。
  final int retrySeconds;

  /// 拒绝**只针对没开过的新号码**，已打开过的号照读。
  ///
  /// 站点在 429 的 body 里给 `scope: "new_inboxes"`（实测：第 6 个新号
  /// 触发，同一时刻打已打开过的号仍然是 200）。这一档只有换出口 + 换
  /// 身份才解得开，所以界面要给它一个按钮；其它两档（`challenge` /
  /// `unavailable`）换出口没用，不该给。
  final bool newInboxesOnly;
}

class const InboxState({
  this.messages = const [],
  this.phase = InboxPhase.waiting,
  this.source = '',
  this.hits = 0,
  this.status = '正在打开收件页…',
  this.error,
  this.hasMore = true,
  this.loadingMore = false,
  this.visible = 5,
  this.hold,
}) {
  final List<InboxMessage> messages;
  final InboxPhase phase;

  /// 数据来源：`接口`（截获 API 响应）或 `页面`（DOM 扫描）。
  final String source;

  /// 截获的接口响应次数，用来判断挂钩有没有生效。
  final int hits;

  final String status;
  final String? error;

  /// 站点还有更早的消息可以拉。
  ///
  /// 默认 true：首屏拿到后并不知道后面还有没有，先假设有，
  /// 等 JS 明确说「到底了」才关掉——反过来会让用户永远看不到翻页入口。
  final bool hasMore;

  /// 正在拉更早的一页。用来防重复触发和显示「加载中」。
  final bool loadingMore;

  /// 当前放出多少条。
  ///
  /// 站点一次会给一整页（24 条），全摆出来既长又慢。首屏只放 5 条，
  /// 用户往下滑再把本地已有的继续放出；本地放完了才去找站点要更早的。
  /// 这样「打开就一大坨」和「一上来就翻页」都避免了。
  final int visible;

  /// 站点拒绝了本次读取。null 表示没被拒。
  ///
  /// 这不是错误：[InboxPhase.failed] 是「我们这边出问题了」，
  /// 而这是站点明确说「现在不给」，要等它自己好。
  final SiteHold? hold;

  /// 列表里实际要渲染的消息（按 [visible] 截断）。
  List<InboxMessage> get shown =>
      messages.length <= visible ? messages : messages.sublist(0, visible);

  /// 本地还有没放出来的条数。
  int get heldBack => messages.length > visible ? messages.length - visible : 0;

  InboxState copyWith({
    List<InboxMessage>? messages,
    InboxPhase? phase,
    String? source,
    int? hits,
    String? status,
    String? error,
    bool clearError = false,
    bool? hasMore,
    bool? loadingMore,
    int? visible,
    SiteHold? hold,
    bool clearHold = false,
  }) {
    return InboxState(
      messages: messages ?? this.messages,
      phase: phase ?? this.phase,
      source: source ?? this.source,
      hits: hits ?? this.hits,
      status: status ?? this.status,
      error: clearError ? null : (error ?? this.error),
      hasMore: hasMore ?? this.hasMore,
      loadingMore: loadingMore ?? this.loadingMore,
      visible: visible ?? this.visible,
      hold: clearHold ? null : (hold ?? this.hold),
    );
  }
}
