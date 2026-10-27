/// 收件箱状态。
///
/// 每个号一个 store，随页面生灭，不用全局 provider——同时开两个号不会串数据。
/// 数据来自 WebView 内注入脚本经 `FusInbox` 通道回传的 JSON。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:fus_inbox/core/time/site_time.dart';
import 'package:fus_inbox/features/inbox/domain/inbox_message.dart';

class InboxStore({this.onChanged}) {
  /// 列表保留的最大条数。
  ///
  /// 必须容得下翻页拉回来的历史：列表是新→旧排列，裁剪时砍掉的是尾部
  /// （最老的）。若这里等于一页的量，翻页拿到的消息会立刻被裁掉，
  /// 功能看着有、实际永远是空。
  static const _maxMessages = 240;

  /// 页面销毁时置空：引擎可能比页面活得久，回传不该再触发已卸载页面的刷新。
  VoidCallback? onChanged;

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

    // 站点拒绝给消息。这条要在 messages 分支之前处理：
    // 被拒时站点根本不会发 messages，只发这个。
    if (type == 'holdup') {
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
      return;
    }

    // 翻页结果：只更新「还有没有更早的」，消息本身随 messages 帧一起到。
    if (type == 'moreDone') {
      final exhausted = payload['exhausted'] == true;
      _emit(_state.copyWith(hasMore: !exhausted, loadingMore: false));
      return;
    }
    if (type == 'moreEnd') {
      _emit(_state.copyWith(hasMore: false, loadingMore: false));
      return;
    }
    if (type == 'moreFail') {
      // 失败不等于没有更多：保留 hasMore，用户还能再试一次。
      //
      // 但要**说出来**。以前这里只把 loadingMore 关掉：转圈消失、
      // 按钮回来，界面和「什么都没发生」长得一模一样，用户只会以为
      // 是自己没点到。JS 侧三条失败路径（no_cursor / no_id / 抛异常）
      // 全汇到这里，此前都没有下文。
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
      return;
    }

    final items = payload['items'];
    if (items is! List) return;

    // 逐条归一化 + 按 id 去重（同 id 后到的覆盖先到的，正文可能分批抵达）。
    final byId = <String, InboxMessage>{};
    final order = <String>[];
    for (final m in _state.messages) {
      byId[m.id] = m;
      order.add(m.id);
    }

    for (final raw in items) {
      if (raw is! Map) continue;
      final msg = InboxMessage.fromJson(Map<String, dynamic>.from(raw));
      if (msg.id.isEmpty || (msg.text.isEmpty && !msg.hasCode)) continue;
      final old = byId[msg.id];
      if (old == null) {
        // 站点给的是「新→旧」，原序追加；最后的 sort 负责排序，
        // 这里再 insert(0) 只会把整批翻转。
        order.add(msg.id);
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

    // 站点给的是「新→旧」，我们逐条收进 byId。统一按时间降序收尾，
    // 而不是靠插入位置——insert(0) 会把整批翻成「旧→新」，最新的沉到最底。
    // 同 id 的新帧带更完整正文时也留在原位，不会跳到头部。
    final merged = <InboxMessage>[];
    for (final id in order) {
      final m = byId[id];
      if (m == null) continue;
      // 首屏已存在的算旧；之后新出现的标「新」。
      final isNew = _firstBatchDone && !_seen.contains(m.id);
      merged.add(m.copyWith(isNew: isNew));
    }
    merged.sort((a, b) {
      final at = parseSiteTime(a.receivedAt);
      final bt = parseSiteTime(b.receivedAt);
      // 时间戳可能缺失（protected 消息就没有时间）。缺失的排在后面，
      // 两个都缺失时保持原序——比较器必须给出一致的偏序，
      // 否则 List.sort 的结果不稳定，顺序会随点数漂移。
      if (at == null && bt == null) return 0;
      if (at == null) return 1;
      if (bt == null) return -1;
      return bt.compareTo(at);
    });
    if (!_firstBatchDone) _firstBatchDone = true;
    // 站点自己也有条数上限（live.js 的 messageSize），这里同样裁一下，
    // 否则收件页开着跑一整天，列表和无界增长的 _seen 一起吃掉内存。
    if (merged.length > _maxMessages) {
      merged.removeRange(_maxMessages, merged.length);
    }
    // _seen 必须跟着裁剪，否则它会永远膨胀——之前注释说「一起裁」，
    // 但实际只裁了 merged，_seen 只增不减，开一整天就是稳定泄漏。
    if (_seen.length > _maxMessages * 2) {
      final keep = {for (final m in merged) m.id};
      _seen.removeWhere((id) => !keep.contains(id));
    }
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
        // 这里必须显式带上翻页状态：直接 new 一个 InboxState 会把它重置成
        // 默认值（hasMore=true），导致用户刚拉到底又被允许继续拉。
        hasMore: _state.hasMore,
        loadingMore: _state.loadingMore,
        // 同上：不带上就会每来一帧就被重置回 5 条，
        // 用户刚滑出来的内容会自己缩回去。
        visible: _state.visible,
        // 拿到消息 = 站点又开始给了。hold 必须在这里清掉，
        // 否则界面会一直挂着「站点暂时不给消息」，就算下面已经有内容。
        hold: merged.isEmpty ? _state.hold : null,
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
    onChanged?.call();
  }

  void fail(String message) => _emit(
    _state.copyWith(phase: InboxPhase.failed, error: message, status: message),
  );

  void reset() {
    _seen.clear();
    _firstBatchDone = false;
    _emit(const InboxState());
  }

  /// 页面销毁时调用：此后任何回传都只更新状态，不再回调界面。
  void detach() => onChanged = null;
}
