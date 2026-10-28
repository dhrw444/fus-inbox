/// 收件页的两个附件：用户手动过验证时的底栏、列表底部的加载态。
///
/// 都是**纯展示 + 回调**，不碰内部状态。拆出来的理由和
/// `inbox_empty_state.dart` 一样：让 `inbox_screen` 只剩编排。
library;

import 'package:fus_inbox/features/inbox/domain/inbox_message.dart';
import 'package:material_ui/material_ui.dart';

/// 用户点「自己过验证」之后贴底的那一条。
class const ChallengeBar({
  required this.theme,
  required this.onClose,
  required this.onConfirm,
  super.key,
}) extends StatelessWidget {
  final ThemeData theme;
  final VoidCallback onClose;
  final VoidCallback onConfirm;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Material(
        color: theme.colorScheme.surfaceContainerHigh,
        elevation: 4,
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '在上面点掉「Verify you are human」。过完点「验证好了」，'
                    '不想过点「收起」。',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                // 两个按钮必须分开 —— 之前这里只有一个，而且被改名成
                // 「收起」。结果提示让用户「过完点右边」，右边却是「收起」：
                // 明明过完了，按下去等于告诉 App「我没过」，语义正好相反。
                // 这两个动作的后果也不一样：「验证好了」要重扫要消息，
                // 「收起」只是先退出来、状态继续盯着。
                TextButton(onPressed: onClose, child: const Text('收起')),
                const SizedBox(width: 4),
                FilledButton(onPressed: onConfirm, child: const Text('验证好了')),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 消息列表的底部。
///
/// 四种形态：正在翻页 / 本地还有存货 / 到底了 / 可以再翻。
class const ListFooter({
  required this.state,
  required this.theme,
  required this.onRevealMore,
  required this.onLoadMore,
  super.key,
}) extends StatelessWidget {
  final InboxState state;
  final ThemeData theme;
  final VoidCallback onRevealMore;
  final VoidCallback onLoadMore;

  @override
  Widget build(BuildContext context) {
    final scheme = theme.colorScheme;

    if (state.loadingMore) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 20),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              width: 13,
              height: 13,
              child: CircularProgressIndicator(
                strokeWidth: 1.8,
                color: scheme.primary,
              ),
            ),
            const SizedBox(width: 9),
            Text(
              '正在加载更早的消息…',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    }

    // 本地还有存货：明确告诉用户还剩多少，点一下放开。
    if (state.heldBack > 0) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: Center(
          child: TextButton(
            onPressed: onRevealMore,
            child: Text('还有 ${state.heldBack} 条，显示更多'),
          ),
        ),
      );
    }

    if (!state.hasMore) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 20),
        child: Center(
          child: Text(
            '没有更早的消息了',
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Center(
        child: TextButton(onPressed: onLoadMore, child: const Text('加载更早的消息')),
      ),
    );
  }
}
