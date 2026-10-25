/// 收件箱状态。
///
/// 每个号一个 store，随页面生灭，不用全局 provider——同时开两个号不会串数据。
/// 数据来自 WebView 内注入脚本经 `FusInbox` 通道回传的 JSON。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:freedium_mobile/features/inbox/domain/inbox_message.dart';

class InboxStore({this.onChanged}) {
  final VoidCallback? onChanged;

  InboxState _state = const InboxState();
  InboxState get state => _state;

  /// 已经见过的消息 id。首屏之后新出现的才算「新」。
  final Set<String> _seen = {};
  bool _firstBatchDone = false;

  void _emit(InboxState next) {
    _state = next;
    onChanged?.call();
  }

  /// 处理一帧 JS 通道消息。
  void ingestRaw(String raw) {
    if (raw.isEmpty) return;
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (e) {
      debugPrint('FusInbox: 非法 JSON — $e');
      return;
    }
    if (decoded is! Map) return;
    ingest(Map<String, dynamic>.from(decoded));
  }

  void ingest(Map<String, dynamic> payload) {
    final type = payload['type'];

    if (type == 'status') {
      _emit(_state.copyWith(status: payload['text']?.toString() ?? ''));
      return;
    }
    // 号码目录走原生 HTTP，这里忽略。
    if (type == 'catalog') return;

    final items = payload['items'];
    if (items is! List) return;

    // 逐条归一化 + 按 id 去重（同 id 后到的覆盖先到的，正文可能分批抵达）。
    final byId = <String, InboxMessage>{};
    final order = <String>[];
    for (final m in _state.messages) {
      byId[m.id] = m;
      order.add(m.id);
    }

    var added = 0;
    for (final raw in items) {
      if (raw is! Map) continue;
      final msg = InboxMessage.fromJson(Map<String, dynamic>.from(raw));
      if (msg.id.isEmpty || (msg.text.isEmpty && !msg.hasCode)) continue;
      final old = byId[msg.id];
      if (old == null) {
        order.insert(0, msg.id);
        added++;
      }
      byId[msg.id] = InboxMessage(
        id: msg.id,
        text: msg.text.isNotEmpty ? msg.text : (old?.text ?? ''),
        code: msg.hasCode ? msg.code : (old?.code ?? ''),
        sender: msg.sender.isNotEmpty ? msg.sender : (old?.sender ?? ''),
        receivedAt: msg.receivedAt.isNotEmpty
            ? msg.receivedAt
            : (old?.receivedAt ?? ''),
        phone: msg.phone.isNotEmpty ? msg.phone : (old?.phone ?? ''),
        isProtected: msg.isProtected,
      );
    }

    final merged = <InboxMessage>[];
    for (final id in order) {
      final m = byId[id];
      if (m == null) continue;
      // 首屏已存在的算旧；之后新出现的标「新」。
      final isNew = _firstBatchDone && !_seen.contains(m.id);
      merged.add(m.copyWith(isNew: isNew));
    }
    if (!_firstBatchDone) _firstBatchDone = true;
    for (final m in merged) {
      _seen.add(m.id);
    }

    final src = payload['src']?.toString() ?? _state.source;
    final hits = payload['hits'] is int
        ? payload['hits'] as int
        : int.tryParse('${payload['hits']}') ?? _state.hits;
    final err = payload['err']?.toString();

    String status;
    if (merged.isEmpty) {
      status = err != null
          ? '抓取出错：$err'
          : '收件页已打开，等新短信…${hits > 0 ? '（已截获 $hits 次响应）' : ''}';
    } else {
      final codes = merged.where((m) => m.hasCode).length;
      status =
          '${merged.length} 条短信'
          '${codes > 0 ? ' · $codes 条带验证码' : ''}'
          '${src.isNotEmpty ? ' · 来自$src' : ''}';
    }

    _emit(
      InboxState(
        messages: merged,
        phase: merged.isEmpty
            ? (_state.phase == InboxPhase.failed
                  ? InboxPhase.failed
                  : InboxPhase.waiting)
            : InboxPhase.ready,
        source: src,
        hits: hits,
        status: status,
        error: err,
      ),
    );
  }

  void note(String text) => _emit(_state.copyWith(status: text));

  void fail(String message) => _emit(
    _state.copyWith(phase: InboxPhase.failed, error: message, status: message),
  );

  void reset() {
    _seen.clear();
    _firstBatchDone = false;
    _emit(const InboxState());
  }
}
