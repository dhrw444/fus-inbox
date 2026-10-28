/// 收件页顶栏：号码 + 地区/条数，右边四个动作；搜索时标题位置变输入框。
///
/// 从 `inbox_screen.dart` 的 `build` 里搬出来。它只是把「有哪些动作」摆出来，
/// 动作本身（换身份、重载、过验证、搜索）仍归屏幕 —— 所以这里收的全是
/// [VoidCallback] 和一个 [TextEditingController]，不认识 store / 引擎 / 代理。
///
/// 搜索态和号码页（`numbers_app_bar.dart`）是**同一套交互**：点搜索键、
/// 标题变输入框、动作栏只剩「关闭」。用户在两个页面之间不该学两遍。
library;

import 'package:fus_inbox/features/numbers/domain/available_number.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fus_inbox/core/widgets/app_bar_search_field.dart';

class const InboxAppBar({
  required this.number,
  required this.messageCount,
  required this.searching,
  required this.controller,
  required this.codeOnly,
  required this.onQuery,
  required this.onOpenSearch,
  required this.onCloseSearch,
  required this.onToggleCodeOnly,
  required this.onChallenge,
  required this.onRotateIdentity,
  required this.onRescan,
  required this.onReload,
  super.key,
}) extends StatelessWidget implements PreferredSizeWidget {
  final AvailableNumber number;

  /// 已经拿到的条数。0 时副标题只显示地区（不用写「0 条」）。
  final int messageCount;

  /// 搜索框展开了没有。展开时标题位置变输入框。
  final bool searching;

  /// 搜索输入框的控制器。归页面持有（页面还要在关闭时清它）。
  final TextEditingController controller;

  /// 只显示带验证码的那几条（搜索态里才露出来）。
  final bool codeOnly;

  final void Function(String query) onQuery;
  final VoidCallback onOpenSearch;
  final VoidCallback onCloseSearch;
  final VoidCallback onToggleCodeOnly;

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
      title: searching
          ? AppBarSearchField(
              controller: controller,
              hintText: '验证码 / 发送方 / 正文',
              onChanged: onQuery,
            )
          : Column(
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
      actions: searching
          ? [
              // 「只看带验证码的」：这是「我到底收到过哪些验证码」最直接的
              // 入口 —— 不用先想关键词。
              IconButton(
                tooltip: codeOnly ? '显示全部消息' : '只看带验证码的',
                isSelected: codeOnly,
                onPressed: onToggleCodeOnly,
                icon: const Icon(Icons.password_outlined),
                selectedIcon: const Icon(Icons.password),
              ),
              IconButton(
                tooltip: '关闭搜索',
                onPressed: onCloseSearch,
                icon: const Icon(Icons.close),
              ),
            ]
          : [
              IconButton(
                tooltip: '搜索',
                onPressed: onOpenSearch,
                icon: const Icon(Icons.search),
              ),
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
