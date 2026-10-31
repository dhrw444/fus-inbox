/// 收件页的两块「非正常状态」：站点拒绝、以及空/骨架。
///
/// 单独拆出来是因为这两块**纯展示 + 三个回调**，不碰任何内部状态 ——
/// 留在 `inbox_screen` 里只会让那个文件多 180 行，读的时候还要分辨
/// 「这段用到了哪些字段」。
library;

import 'package:fus_inbox/features/inbox/domain/inbox_message.dart';
import 'package:fus_inbox/features/inbox/presentation/widgets/skeleton_tile.dart';
import 'package:material_ui/material_ui.dart';

/// 站点明确说「现在不给」时显示的那一块。
///
/// 三种拒绝要的动作完全不同，所以按钮不是一个：
///
/// - `quota`     配额记在**出口 IP** 上，换身份没用（实测同一个 IP 换身份
///               第 4 个号照样被拒）。要用户换出口 IP，换完点按钮把身份
///               也清掉一起重来。
/// - `challenge` 先试自动（站点常常静默通过）；真过不去才把页面放出来
///               让人点复选框 —— 那个东西在跨域 shadow DOM 里 JS 摸不到。
/// - `temporary` 纯等待，重试就行。
///
/// 以前这块完全没有：站点 429/403/503 的响应体里没有 messages，注入脚本
/// 当作「空」跳过，界面就一直卡在骨架屏转圈 —— 用户看到的是「软件坏了」。
class const HoldNotice({
  required this.hold,
  required this.theme,
  required this.onRestart,
  required this.onChallenge,
  required this.onRescan,
  required this.onReload,
  super.key,
}) extends StatelessWidget {
  final SiteHold hold;
  final ThemeData theme;
  final VoidCallback onRestart;
  final VoidCallback onChallenge;
  final VoidCallback onRescan;

  /// 真正会**重新发请求**的动作（reload）。
  ///
  /// temporal hold 的「重试」按钮原来接的是 `onRescan`（只重扫现有 DOM）——
  /// 而 hold 本身由接口响应头产生（`holdFromResponse`），DOM 里不会有新东西，
  /// 清 hold 的空 holdup 帧只随新响应到来。**重扫永远清不掉 hold**：
  /// 用户点「重试」，界面纹丝不动。
  final VoidCallback onReload;

  @override
  Widget build(BuildContext context) {
    final scheme = theme.colorScheme;
    final (icon, tint) = switch (hold.kind) {
      SiteHoldKind.quota => (Icons.hourglass_disabled, scheme.tertiary),
      SiteHoldKind.challenge => (Icons.shield_outlined, scheme.primary),
      SiteHoldKind.temporary => (Icons.cloud_sync_outlined, scheme.secondary),
    };

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
      child: Column(
        children: [
          Icon(icon, size: 42, color: tint),
          const SizedBox(height: 14),
          Text(
            hold.title.isEmpty ? '站点暂时不给消息' : hold.title,
            textAlign: TextAlign.center,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            hold.message,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: scheme.onSurfaceVariant,
              height: 1.5,
            ),
          ),
          if (hold.retrySeconds > 0) ...[
            const SizedBox(height: 8),
            Text(
              '站点建议 ${hold.retrySeconds} 秒后再试。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
          const SizedBox(height: 18),

          // 三种拒绝各自的按钮，理由见本类开头的 doc。
          if (hold.kind == SiteHoldKind.quota) ...[
            FilledButton.tonalIcon(
              onPressed: onRestart,
              icon: const Icon(Icons.vpn_key_outlined, size: 18),
              label: const Text('换出口并重置身份'),
            ),
            const SizedBox(height: 6),
            Text(
              hold.newInboxesOnly
                  ? '新号码的免费额度用完了，已打开过的号仍能读。点上面那个会'
                        '换一条出口 IP 并清掉旧浏览器身份（密钥 / cookie / '
                        '本地存储），站点那边就是全新访客。代理池里没有别的'
                        '出口时会明说，不会假装换成了。'
                  : '配额按出口 IP 算，不按号码。点上面那个会换一条出口 IP '
                        '并清掉旧浏览器身份（密钥 / cookie / 本地存储）一起重来。',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
                height: 1.4,
              ),
            ),
          ] else if (hold.kind == SiteHoldKind.challenge) ...[
            FilledButton.tonalIcon(
              onPressed: onChallenge,
              icon: const Icon(Icons.shield_outlined, size: 18),
              label: const Text('自己过验证'),
            ),
            const SizedBox(height: 6),
            Text(
              '通常会自动通过，只有卡住不动时才需要手动点。',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
                height: 1.4,
              ),
            ),
          ] else
            FilledButton.tonalIcon(
              onPressed: onReload,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('重试'),
            ),
          const SizedBox(height: 4),
          TextButton(
            onPressed: () => Navigator.of(context).maybePop(),
            child: const Text('换个号码'),
          ),
        ],
      ),
    );
  }
}

/// 消息还没到时的两种形态：加载失败，或者骨架。
class const InboxEmptyState({
  required this.state,
  required this.theme,
  required this.onRescan,
  required this.onReload,
  required this.onChallenge,
  required this.onRestart,
  super.key,
}) extends StatelessWidget {
  final InboxState state;
  final ThemeData theme;
  final VoidCallback onRescan;
  final VoidCallback onReload;
  final VoidCallback onChallenge;
  final VoidCallback onRestart;

  @override
  Widget build(BuildContext context) {
    final failed = state.phase == InboxPhase.failed;
    final scheme = theme.colorScheme;

    // 站点主动拒绝：这不是错误，是它明确说「现在不给」。
    // 单独一块，因为它需要的动作和「加载失败」完全不同——
    // 失败是重试，配额是等或换号，验证是去过验证。
    if (state.hold != null) {
      return HoldNotice(
        hold: state.hold!,
        theme: theme,
        onRestart: onRestart,
        onChallenge: onChallenge,
        onRescan: onRescan,
        onReload: onReload,
      );
    }

    if (failed) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
        child: Column(
          children: [
            Icon(Icons.cloud_off, size: 40, color: scheme.error),
            const SizedBox(height: 14),
            Text(
              state.status,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 18),
            FilledButton.tonalIcon(
              onPressed: onRescan,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('重试'),
            ),
            const SizedBox(height: 6),
            TextButton(onPressed: onChallenge, child: const Text('自己过验证')),
          ],
        ),
      );
    }

    // 骨架：三条占位卡，形状和真实消息一致，来了就原地替换。
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 18, 16, 12),
          child: Row(
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
              Expanded(
                child: Text(
                  state.status,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
        for (var i = 0; i < 3; i++) SkeletonTile(theme: theme),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
          child: Text(
            '停在这是因为要等站点把消息推过来，通常几秒。',
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}
