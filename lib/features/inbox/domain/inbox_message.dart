/// 收件箱领域模型。
///
/// 数据来源是 WebView 内 `assets/js/fus_inbox.js` 通过 `FusInbox` JS 通道
/// 回传的 JSON——脚本挂钩了 freeussms 页面自身的 fetch/XHR，截获签名后的
/// inbox 响应，所以这里只负责反序列化。
library;

/// 单条短信。
class InboxMessage {
  const InboxMessage({
    required this.key,
    required this.code,
    required this.text,
    this.time = '',
    this.phone = '',
    this.isNew = false,
  });

  final String key;
  final String code;
  final String text;
  final String time;
  final String phone;
  final bool isNew;

  static String _str(Object? v) => v is String ? v : (v == null ? '' : '$v');

  factory InboxMessage.fromJson(Map<String, dynamic> json) {
    return InboxMessage(
      key: _str(json['key']),
      code: _str(json['code']),
      text: _str(json['text']),
      time: _str(json['time']),
      phone: _str(json['phone']),
      isNew: json['isNew'] == true,
    );
  }

  /// 列表渲染用的短标签，例如 “+17573242429”。
  String get shortPhone => phone.replaceAll(RegExp(r'[^\d+]'), '');
}

/// 抓取状态。
enum InboxPhase {
  /// 页面还在加载 / 还没拿到数据。
  waiting,

  /// 已解析出至少一条短信。
  ready,

  /// 页面报错。
  failed,
}

class InboxState {
  const InboxState({
    this.messages = const [],
    this.phase = InboxPhase.waiting,
    this.source = '',
    this.hits = 0,
    this.status = '正在打开收件页…',
    this.error,
    this.pageUrl,
  });

  final List<InboxMessage> messages;
  final InboxPhase phase;

  /// 数据来源：`接口`（截获 API）或 `页面`（DOM 扫描）。
  final String source;

  /// 截获的接口响应条数，用于判断挂钩是否生效。
  final int hits;

  final String status;
  final String? error;
  final String? pageUrl;

  int get newCount => messages.where((m) => m.isNew).length;

  InboxState copyWith({
    List<InboxMessage>? messages,
    InboxPhase? phase,
    String? source,
    int? hits,
    String? status,
    String? error,
    String? pageUrl,
    bool clearError = false,
  }) {
    return InboxState(
      messages: messages ?? this.messages,
      phase: phase ?? this.phase,
      source: source ?? this.source,
      hits: hits ?? this.hits,
      status: status ?? this.status,
      error: clearError ? null : (error ?? this.error),
      pageUrl: pageUrl ?? this.pageUrl,
    );
  }
}
