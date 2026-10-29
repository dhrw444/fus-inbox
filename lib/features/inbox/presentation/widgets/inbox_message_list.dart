/// 收件箱正文：空态 / 消息列表 + 翻页脚注。
///
/// 从 `inbox_screen.dart` 的 `_buildList` 整块搬出来。它只依赖
/// [InboxState]、偏好、和一组回调 —— 不碰页面自己的计时器、引擎、
/// 代理，所以搬出来是干净的（不是那种「两种职责交错」的切法）。
///
/// ## 这里管两件事
///
/// 1. **搜索过滤**（[query] / [codeOnly]）：只决定「哪些消息该显示」，
///    判定本身在 `domain/inbox_search.dart`（纯函数，能单独测）。
/// 2. **滚到底怎么办**：本地还有存货就先放一屏，没有才去请求下一页。
///
/// 搜索态**忽略「首屏 5 条」那个窗口** —— 那个窗口是为了首屏别一次渲染
/// 两百条卡片，而搜索的语义就是「把你匹配到的都给我看」。搜索时也不显示
/// 翻页脚注：脚注是「往下还有」，和搜索没关系。
library;

import 'dart:async';

import 'package:fus_inbox/core/prefs/prefs_provider.dart';
import 'package:fus_inbox/features/inbox/domain/inbox_message.dart';
import 'package:fus_inbox/features/inbox/domain/inbox_search.dart';
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
  required this.query,
  required this.codeOnly,
  required this.onRescan,
  required this.onReload,
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

  /// 搜索关键词（原样，未归一化）。空串 = 没在搜。
  final String query;

  /// 只看带验证码的那几条。
  final bool codeOnly;

  /// 下拉刷新 / 空态里的「重新扫描」。
  final Future<void> Function() onRescan;

  /// 真正会重新发请求的动作（reload）。见 `HoldNotice.onReload`。
  final Future<void> Function() onReload;

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
    // 搜索生效 = 有关键词，或者开了「只看验证码」。
    final filtering = query.trim().isNotEmpty || codeOnly;
    final matched = filtering
        ? filterInboxMessages(state.messages, query: query, codeOnly: codeOnly)
        : state.messages;
    // 过滤时给全部匹配（不受 visible 窗口限制），不过滤时按窗口截断。
    final shown = filtering ? matched : state.shown;

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
                onReload: onReload,
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
        child: Column(
          children: [
            // 搜索小结：条数 + 带码条数。用户搜「1234」时能立刻看出
            // 命中了几条、其中几条是真验证码。
            if (filtering)
              InboxSearchSummary(
                theme: theme,
                matchCount: matched.length,
                codeCount: matched.where((m) => m.hasCode).length,
                codeOnly: codeOnly,
                query: query,
              ),
            Expanded(
              child: matched.isEmpty && filtering
                  ? _NoMatch(theme: theme, codeOnly: codeOnly, query: query)
                  : NotificationListener<ScrollNotification>(
                      // 滑到底自动拉下一页。用 ScrollNotification 而不是
                      // ScrollController，是因为这里不想再管一个 controller
                      // 的生命周期。搜索时完全不参与（见过滤条件）。
                      onNotification: (n) {
                        if (filtering) return false;
                        // 只在「滚动结束」时判断，不是每一帧都判断。
                        //
                        // 之前是每个 ScrollUpdateNotification 都检查，一滑到底
                        // 会连发十几次 revealMore()，本地存货瞬间全放完，再连发
                        // 几次网络请求 —— 这就是「加载逻辑很垃圾」的根源。
                        // 改成只认 ScrollEndNotification：一次滑动最多触发一次。
                        if (n is! ScrollEndNotification) return false;
                        if (n.metrics.pixels <
                            n.metrics.maxScrollExtent - 160) {
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
                        // 不过滤时只渲染 state.shown（首屏 5 条），
                        // 过滤时渲染全部匹配。末尾各多一项：翻页脚注。
                        // （脚注只在不过滤时出现。）
                        itemCount: shown.length + (filtering ? 0 : 1),
                        itemBuilder: (context, i) {
                          if (!filtering && i == shown.length) {
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
                            // 长按复制整条正文（含发送方和时间），不再
                            // 「有码就只复制码」—— 用户长按多半是想拿全文，
                            // 替他决定只给验证码是越权。
                            onCopyAll: () => onCopyAll(shown[i]),
                          );
                        },
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 搜索没命中时的那一块。
///
/// 和「还没收到消息」的空态**分开**：那个说的是「等站点推过来」，
/// 这个说的是「收到了，但你要的那条不在里面」—— 该做的事完全不同
/// （一个等，一个换关键词）。
class const _NoMatch({
  required this.theme,
  required this.codeOnly,
  required this.query,
}) extends StatelessWidget {
  final ThemeData theme;
  final bool codeOnly;
  final String query;

  @override
  Widget build(BuildContext context) {
    final scheme = theme.colorScheme;
    // 「只看验证码」开着但一条都没有 —— 这是最常见的一种，单独说清楚。
    final (icon, title, hint) = codeOnly
        ? (Icons.password_outlined, '这个号还没收到带验证码的短信', '关掉「只看带验证码的」能看全部消息。')
        : (
            Icons.search_off,
            '没有匹配的消息',
            query.trim().isEmpty
                ? '换个关键词试试。'
                : '「${query.trim()}」没搜到。试试验证码的数字、'
                      '发送方名字，或者正文里的词。',
          );

    return ListView(
      // 可滚动，否则内容不满一屏时下拉刷新手势拉不动。
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        SizedBox(height: MediaQuery.sizeOf(context).height * 0.12),
        Icon(icon, size: 40, color: scheme.onSurfaceVariant),
        const SizedBox(height: 14),
        Text(
          title,
          textAlign: TextAlign.center,
          style: theme.textTheme.titleSmall,
        ),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 40),
          child: Text(
            hint,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
              height: 1.4,
            ),
          ),
        ),
      ],
    );
  }
}
