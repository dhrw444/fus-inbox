/// 收件页顶栏：号码 + 地区/条数，右边四个动作。
///
/// 从 `inbox_screen.dart` 的 `build` 里搬出来。它只是把「有哪些动作」
/// 摆出来，动作本身（换身份、重载、过验证）仍归屏幕 —— 所以这里收的
/// 全是 [VoidCallback]，不认识 store / 引擎 / 代理。
library;

import 'package:fus_inbox/features/numbers/domain/available_number.dart';
import 'package:material_ui/material_ui.dart';

class const InboxAppBar({
  required this.number,
  required this.messageCount,
  required this.onChallenge,
  required this.onRotateIdentity,
  required this.onRescan,
  required this.onReload,
  super.key,
}) extends StatelessWidget implements PreferredSizeWidget {
  final AvailableNumber number;

  /// 已经拿到的条数。0 时副标题只显示地区（不用写「0 条」）。
  final int messageCount;

  /// 「自己过验证」：把站点页面放出来让用户点掉人机验证。
  final VoidCallback onChallenge;

  /// 「换浏览器身份」：换 UA + 清站点数据 + 重载。
  final VoidCallback onRotateIdentity;

  /// 「重新扫描」：把已经渲染出来的 DOM 再读一遍，不发网络请求。
  final VoidCallback onRescan;

  /// 「重新加载」：本页作废，重新打开收件页。
  final VoidCallback onReload;

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AppBar(
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(number.pretty, style: theme.textTheme.titleMedium),
          if (number.regionLabel.isNotEmpty)
            Text(
              messageCount == 0
                  ? number.regionLabel
                  : '${number.regionLabel} · $messageCount 条',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
      actions: [
        // 手动验证：自动路径过不去时才用。点开把站点页面放出来，
        // 自己在上面点掉「Verify you are human」，回来点「验证好了」。
        IconButton(
          tooltip: '自己过验证',
          onPressed: onChallenge,
          icon: const Icon(Icons.shield_outlined),
        ),
        // 换浏览器身份：站点会按 UA 判断是不是同一个浏览器，
        // 卡验证时点一下换新身份比反复重载有用。
        IconButton(
          tooltip: '换浏览器身份',
          onPressed: onRotateIdentity,
          icon: const Icon(Icons.switch_account_outlined),
        ),
        // 重新扫描：只是把页面里已经渲染出来的 DOM 再读一遍，不重新
        // 加载页面。和下面那个「重新加载」完全不同 —— 那个会丢状态。
        IconButton(
          tooltip: '重新扫描（不重新加载页面）',
          onPressed: onRescan,
          icon: const Icon(Icons.refresh),
        ),
        // 重新加载：整页重开。会丢当前滚动位置和已截获的临时状态，
        // 只在页面确实坏了的时候用。
        IconButton(
          tooltip: '重新加载页面',
          onPressed: onReload,
          icon: const Icon(Icons.restart_alt),
        ),
      ],
    );
  }
}
