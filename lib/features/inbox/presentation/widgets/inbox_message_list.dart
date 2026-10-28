/// 收件箱正文：空态 / 消息列表 + 翻页脚注。
///
/// 从 `inbox_screen.dart` 的 `_buildList` 整块搬出来。它只依赖
/// [InboxState]、偏好、和一组回调 —— 不碰页面自己的计时器、引擎、
/// 代理，所以搬出来是干净的（不是那种「两种职责交错」的切法）。
///
/// 唯一留在这里的逻辑是「滚到底怎么办」：本地还有存货就先放一屏，
/// 没有才去请求下一页（见 `onNotification` 里的注释）。
library;

import 'dart:async';

import 'package:fus_inbox/core/prefs/prefs_provider.dart';
import 'package:fus_inbox/features/inbox/domain/inbox_message.dart';
import 'package:fus_inbox/features/inbox/presentation/widgets/inbox_attachments.dart';
import 'package:fus_inbox/features/inbox/presentation/widgets/inbox_empty_state.dart';
import 'package:fus_inbox/features/inbox/presentation/widgets/message_tile.dart';
import 'package:material_ui/material_ui.dart';

/// 拼出可复制的整条短信：发送方 + 时间 + 正文。
String fullMessageText(InboxMessage m) {
  final buf = StringBuffer();
  if (m.sender.isNotEmpty) buf.writeln(m.sender);
  if (m.receivedAt.isNotEmpty) buf.writeln(m.receivedAt);
  buf.write(m.text);
  return buf.toString().trim();
}

class const InboxMessageList({
  required this.state,
  required this.theme,
  required this.prefs,
  required this.onRescan,
  required this.onChallenge,
  required this.onRestart,
  required this.onRevealMore,
  required this.onLoadMore,
  required this.onCopyCode,
  required this.onCopyAll,
  super.key,
}) extends StatelessWidget {
  final InboxState state;
  final ThemeData theme;
  final Prefs prefs;

  /// 下拉刷新 / 空态里的「重新扫描」。
  final Future<void> Function() onRescan;

  /// 空态里「我自己去过验证」—— 会带 reload（见 `_openChallenge`）。
  final VoidCallback onChallenge;

  /// 空态里「我换了 IP，把身份也重置」。
  final VoidCallback onRestart;

  /// 本地存货多放几条（同步，不请求网络）。
  final VoidCallback onRevealMore;

  /// 真去拉更早的一页。
  final Future<void> Function() onLoadMore;

  final void Function(String code) onCopyCode;
  final void Function(InboxMessage message) onCopyAll;

  @override
  Widget build(BuildContext context) {
    final shown = state.shown;
    if (state.messages.isEmpty) {
      return ColoredBox(
        color: theme.colorScheme.surface,
        child: RefreshIndicator(
          onRefresh: onRescan,
          child: ListView(
            // 可滚动，否则 RefreshIndicator 在内容不满一屏时拉不动。
            physics: const AlwaysScrollableScrollPhysics(),
            children: [
              SizedBox(height: MediaQuery.sizeOf(context).height * 0.10),
              InboxEmptyState(
                state: state,
                theme: theme,
                onRescan: onRescan,
                onChallenge: onChallenge,
                onRestart: onRestart,
              ),
            ],
          ),
        ),
      );
    }

    return ColoredBox(
      color: theme.colorScheme.surface,
      child: RefreshIndicator(
        onRefresh: onRescan,
        child: NotificationListener<ScrollNotification>(
          // 滑到底自动拉下一页。用 ScrollNotification 而不是 ScrollController，
          // 是因为这里不想再管一个 controller 的生命周期。
          onNotification: (n) {
            // 只在「滚动结束」时判断，不是每一帧都判断。
            //
            // 之前是每个 ScrollUpdateNotification 都检查，一滑到底会连发
            // 十几次 revealMore()，本地存货瞬间全放完，再连发几次网络请求
            // —— 这就是「加载逻辑很垃圾」的根源。
            // 改成只认 ScrollEndNotification：一次滑动最多触发一次。
            if (n is! ScrollEndNotification) return false;
            if (n.metrics.pixels < n.metrics.maxScrollExtent - 160) {
              return false;
            }
            if (state.loadingMore) return false;

            if (state.heldBack > 0) {
              // 本地存货一次放一屏左右，不要一把全倒出来。
              onRevealMore();
            } else {
              unawaited(onLoadMore());
            }
            return false;
          },
          // 卡片自带 8dp 间距，不再画分隔线。
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
            // 只渲染 state.shown（首屏 5 条），不是全部 24 条。
            // 末尾多一项：翻页脚注。
            itemCount: shown.length + 1,
            itemBuilder: (context, i) {
              if (i == shown.length) {
                return ListFooter(
                  state: state,
                  theme: theme,
                  onRevealMore: onRevealMore,
                  onLoadMore: onLoadMore,
                );
              }
              return MessageTile(
                message: shown[i],
                translate: prefs.translate,
                showOriginal: prefs.showOriginal,
                fontScale: prefs.fontScale,
                onCopyCode: onCopyCode,
                // 长按复制整条正文（含发送方和时间），不再「有码就只复制码」——
                // 用户长按多半是想拿全文，替他决定只给验证码是越权。
                onCopyAll: () => onCopyAll(shown[i]),
              );
            },
          ),
        ),
      ),
    );
  }
}
