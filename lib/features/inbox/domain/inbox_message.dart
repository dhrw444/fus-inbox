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
  this.clearanceSeen = false,
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

  /// 站点发过 `cf_clearance` —— Cloudflare 验证确实通过了。
  ///
  /// 这是唯一可信的「已过验证」信号：DOM 长得像不像收件箱、
  /// 挑战容器有没有消失，都不算数（导航栏和广告都能命中）。
  /// 只有站点自己发下的通行证才算。
  final bool clearanceSeen;

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
    bool clearStatus = false,
    bool clearSource = false,
    bool? hasMore,
    bool? loadingMore,
    int? visible,
    bool? clearanceSeen,
  }) {
    return InboxState(
      messages: messages ?? this.messages,
      phase: phase ?? this.phase,
      source: clearSource ? '' : (source ?? this.source),
      hits: hits ?? this.hits,
      status: clearStatus ? '' : (status ?? this.status),
      error: clearError ? null : (error ?? this.error),
      hasMore: hasMore ?? this.hasMore,
      loadingMore: loadingMore ?? this.loadingMore,
      visible: visible ?? this.visible,
      clearanceSeen: clearanceSeen ?? this.clearanceSeen,
    );
  }
}
