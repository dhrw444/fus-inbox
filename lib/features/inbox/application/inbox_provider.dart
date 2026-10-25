/// 收件箱状态容器。
///
/// 由 WebView 的 `FusInbox` JS 通道喂数据，不做任何网络请求——
/// freeussms 的接口需要页面自身的 WebCrypto 签名，外部拿不到。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:freedium_mobile/features/inbox/domain/inbox_message.dart';

class InboxNotifier() extends Notifier<InboxState> {
  @override
  InboxState build() => const InboxState();

  /// 处理 JS 通道回传的一帧。
  void ingestRaw(String raw) {
    if (raw.isEmpty) return;
    late final Object? decoded;
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
      state = state.copyWith(status: payload['text']?.toString() ?? '');
      return;
    }

    final items = payload['items'];
    if (items is! List) return;

    // 按 key 去重合并：保留已有顺序，新条目排在最前。
    final existing = {for (final m in state.messages) m.key: m};
    final fresh = <InboxMessage>[];
    for (final item in items) {
      if (item is! Map) continue;
      final msg = InboxMessage.fromJson(Map<String, dynamic>.from(item));
      if (msg.key.isEmpty) continue;
      final old = existing[msg.key];
      if (old == null) {
        fresh.add(msg);
      } else {
        // 时间/正文可能后到（先渲染占位再补内容），用新值覆盖旧的。
        existing[msg.key] = InboxMessage(
          key: old.key,
          code: msg.code.isNotEmpty ? msg.code : old.code,
          text: msg.text.isNotEmpty ? msg.text : old.text,
          time: msg.time.isNotEmpty ? msg.time : old.time,
          phone: msg.phone.isNotEmpty ? msg.phone : old.phone,
          isNew: old.isNew,
        );
      }
    }

    final merged = <InboxMessage>[...fresh, ...existing.values];
    final src = payload['src']?.toString() ?? state.source;
    final hits = payload['hits'] is int
        ? payload['hits'] as int
        : int.tryParse('${payload['hits']}') ?? state.hits;

    state = InboxState(
      messages: merged,
      phase: merged.isEmpty ? InboxPhase.waiting : InboxPhase.ready,
      source: src,
      hits: hits,
      status: merged.isEmpty
          ? (payload['err'] != null
                ? '截图失败：${payload['err']}'
                : '页面已打开，等待短信…${hits > 0 ? '（已截获 $hits 个响应）' : ''}')
          : '${merged.length} 条 · 来源 $src${hits > 0 ? ' · 截获 $hits' : ''}',
      pageUrl: payload['url']?.toString() ?? state.pageUrl,
    );
  }

  void markAllSeen() {
    state = state.copyWith(
      messages: [
        for (final m in state.messages)
          InboxMessage(
            key: m.key,
            code: m.code,
            text: m.text,
            time: m.time,
            phone: m.phone,
          ),
      ],
    );
  }

  void fail(String message) {
    state = state.copyWith(
      phase: InboxPhase.failed,
      status: message,
      error: message,
    );
  }

  void reset() {
    state = const InboxState();
  }
}

final inboxProvider = NotifierProvider<InboxNotifier, InboxState>(
  InboxNotifier.new,
);
