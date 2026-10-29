/// 收件箱状态。
///
/// 每个号一个 store，随页面生灭，不用全局 provider——同时开两个号不会串数据。
/// 数据来自 WebView 内注入脚本经 `FusInbox` 通道回传的 JSON。
///
/// ## 这个文件只管「状态怎么变」
///
/// 一帧原始 JSON 怎么变成一份排好序、去过重、裁过枝的列表，全在
/// `inbox_merge.dart`（纯函数，不碰字段，可以单独喂数据跑）。这里只负责
/// 「哪一帧是什么类型」的分派，和 emit / reset / note / fail 这些状态操作。
///
/// 分派必须**先于**列表合并：`holdup` / `moreDone` / `moreFail` 三类帧
/// 都不带 items，走不到合并那一步。之前这些分支和合并逻辑挤在同一个
/// 90 行的 `ingest()` 里，改一个分支得先把整段在心里跑一遍。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:fus_inbox/core/log.dart';
import 'package:fus_inbox/features/inbox/application/inbox_merge.dart';
import 'package:fus_inbox/features/inbox/domain/inbox_message.dart';

export 'package:fus_inbox/features/inbox/application/inbox_merge.dart'
    show kInboxMaxMessages;

class InboxStore({this.onChanged}) {
  /// 页面销毁时置空：引擎可能比页面活得久，回传不该再触发已卸载页面的刷新。
  VoidCallback? onChanged;

  InboxState _state = const InboxState();
  InboxState get state => _state;

  /// 已经见过的消息 id。首屏之后新出现的才算「新」。
  Set<String> _seen = {};
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
      logLine('FusInbox: 非法 JSON — $e');
      return;
    }
    if (decoded is! Map) return;
    ingest(Map<String, dynamic>.from(decoded));
  }

  void ingest(Map<String, dynamic> payload) {
    switch (payload['type']) {
      case 'status':
        _emit(_state.copyWith(status: payload['text']?.toString() ?? ''));
        return;
      // 号码目录走原生 HTTP，这里忽略。
      case 'catalog':
        return;
      case 'holdup':
        _ingestHold(payload);
        return;
      case 'moreDone':
        _emit(
          _state.copyWith(
            hasMore: payload['exhausted'] != true,
            loadingMore: false,
          ),
        );
        return;
      case 'moreEnd':
        _emit(_state.copyWith(hasMore: false, loadingMore: false));
        return;
      case 'moreFail':
        _ingestMoreFail(payload);
        return;
    }

    final items = payload['items'];
    if (items is! List) return;
    _ingestItems(items, payload);
  }

  /// 站点拒绝给消息。这条要在 messages 分支之前处理：
  /// 被拒时站点根本不会发 messages，只发这个。
  void _ingestHold(Map<String, dynamic> payload) {
    final kind = payload['kind']?.toString() ?? '';
    if (kind.isEmpty) {
      // 解除：站点又开始给消息了。
      _emit(_state.copyWith(clearHold: true, clearError: true));
      return;
    }
    final retry = payload['retry'];
    _emit(
      _state.copyWith(
        hold: SiteHold(
          kind: switch (kind) {
            'pause' => SiteHoldKind.quota,
            'challenge' => SiteHoldKind.challenge,
            _ => SiteHoldKind.temporary,
          },
          title: payload['title']?.toString() ?? '',
          message: payload['message']?.toString() ?? '',
          retrySeconds: retry is int ? retry : int.tryParse('$retry') ?? 0,
        ),
        phase: InboxPhase.waiting,
        clearError: true,
      ),
    );
  }

  /// 翻页失败。
  ///
  /// 失败不等于没有更多：保留 hasMore，用户还能再试一次。
  ///
  /// 但要**说出来**。以前这里只把 loadingMore 关掉：转圈消失、按钮回来，
  /// 界面和「什么都没发生」长得一模一样，用户只会以为是自己没点到。
  /// JS 侧三条失败路径（no_cursor / no_id / 抛异常）全汇到这里，
  /// 此前都没有下文。
  void _ingestMoreFail(Map<String, dynamic> payload) {
    final reason = '${payload['reason'] ?? payload['err'] ?? ''}';
    _emit(
      _state.copyWith(
        loadingMore: false,
        status: switch (reason) {
          'no_cursor' => '站点没给翻页游标，稍后再试',
          'no_id' => '拿不到号码标识，翻页停在这里',
          _ => '翻页失败，稍后再试',
        },
      ),
    );
  }

  void _ingestItems(List<Object?> items, Map<String, dynamic> payload) {
    final merged = mergeInboxFrame(
      current: _state.messages,
      items: items,
      seen: _seen,
      firstBatchDone: _firstBatchDone,
    );
    _seen = merged.seen;
    _firstBatchDone = true;
    final messages = merged.messages;

    final src = payload['src']?.toString() ?? _state.source;
    final hits = payload['hits'] is int
        ? payload['hits'] as int
        : int.tryParse('${payload['hits']}') ?? _state.hits;
    final err = payload['err']?.toString();

    _emit(
      InboxState(
        messages: messages,
        phase: messages.isEmpty
            ? (_state.phase == InboxPhase.failed
                  ? InboxPhase.failed
                  : InboxPhase.waiting)
            : InboxPhase.ready,
        source: src,
        hits: hits,
        status: inboxStatusLine(
          merged: messages,
          source: src,
          hits: hits,
          err: err,
        ),
        error: err,
        // 这里必须显式带上翻页状态：直接 new 一个 InboxState 会把它重置成
        // 默认值（hasMore=true），导致用户刚拉到底又被允许继续拉。
        hasMore: _state.hasMore,
        loadingMore: _state.loadingMore,
        // 同上：不带上就会每来一帧就被重置回 5 条，
        // 用户刚滑出来的内容会自己缩回去。
        visible: _state.visible,
        // 拿到消息 = 站点又开始给了。hold 必须在这里清掉，
        // 否则界面会一直挂着「站点暂时不给消息」，就算下面已经有内容。
        hold: messages.isEmpty ? _state.hold : null,
      ),
    );
  }

  void note(String text) => _emit(_state.copyWith(status: text));

  /// 标记是否正在拉更早的一页。
  ///
  /// [done] 为 true 时清掉 loading 标记（请求结束，无论成功失败）。
  /// 单独开一个方法是因为界面上要立刻显示「加载中」，不能等 JS 回话。
  void markLoadingMore({bool done = false}) =>
      _emit(_state.copyWith(loadingMore: !done));

  /// 本地多放出 [step] 条。
  void revealMore({int step = 20}) {
    if (_state.heldBack <= 0) return;
    _emit(_state.copyWith(visible: _state.visible + step));
  }

  void fail(String message) => _emit(
    _state.copyWith(phase: InboxPhase.failed, error: message, status: message),
  );

  void reset() {
    _seen = {};
    _firstBatchDone = false;
    _emit(const InboxState());
  }

  /// 页面销毁时调用：此后任何回传都只更新状态，不再回调界面。
  void detach() => onChanged = null;
}
