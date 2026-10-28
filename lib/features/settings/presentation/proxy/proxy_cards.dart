/// 代理分组里的两张卡片。
///
/// 都是**拿数据渲染**，不持有状态、不碰 provider —— 拆出来之后
/// `proxy_section.dart` 只剩「编排 + 检测进度」那一件事。
library;

import 'package:fus_inbox/core/proxy/proxy_config.dart';
import 'package:fus_inbox/core/proxy/proxy_probe.dart';
import 'package:fus_inbox/core/proxy/proxy_provider.dart';
import 'package:material_ui/material_ui.dart';

/// 当前出口 + 额度状态。
class const ProxyStatusCard({required this.state, super.key})
    extends StatelessWidget {
  /// 整份代理状态（当前出口 + 账本）。
  final ProxyState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ledger = state.ledger;
    final usedNow = ledger.usedFor(state.currentId);
    final full = usedNow >= ledger.maxPerIdentity;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            state.current == null
                ? '当前：直连（没用代理）'
                : '当前：${state.current!.displayName}',
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '这个出口已看 $usedNow / '
            '${ledger.maxPerIdentity} 个号',
            style: theme.textTheme.bodySmall?.copyWith(
              color: full
                  ? theme.colorScheme.error
                  : theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// 一条代理。内置的和手动添加的长得一模一样。
class const ProxyRow({
  super.key,
  required this.proxy,
  required this.active,
  required this.used,
  required this.maxPer,
  required this.probe,
  required this.onUse,
  required this.onRemove,
}) extends StatelessWidget {
  final ProxyConfig proxy;
  final bool active;
  final int used;

  /// 一个身份能看几个号。从账本读，**不要**写死 —— 界面上写死过一版，
  /// 磁盘上存过别的值时两边立刻矛盾：界面显示「已用 1/3」而决策器每开一个
  /// 号都轮换。完整来龙去脉见 `IdentityLedger.maxPerIdentity` 的注释。
  final int maxPer;

  /// 连通性检测结果。没检测过就是 null，副标题只报用量。
  final ProxyProbeResult? probe;
  final VoidCallback onUse;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final full = used >= maxPer;

    // 副标题：先报检测结果，再说用量。没检测过就只说用量。
    final parts = <String>[];
    if (probe != null) {
      parts.add(
        probe!.ok ? '通 ${probe!.latencyMs}ms' : '不通（${probe!.failure}）',
      );
      // 出口 IP 是配额的真单位：同一个 IP 的代理再多也只算一个出口。
      if (probe!.egressIp.isNotEmpty) {
        parts.add('出口 ${probe!.egressIp}');
      } else if (probe!.egressUnknown) {
        // 以前这里是静默的：出口取不到时上面那个 if 直接跳过，界面上
        // 和「取到了但没显示」一模一样。而「配额按出口 IP 算」这条
        // 核心判断完全依赖它 —— 用户看不出这条代理到底能不能算独立额度。
        parts.add('出口未知（无法判断是否与别的代理撞 IP）');
      }
    }
    parts.add(full ? '已用满 $used 个号，下次会跳过' : '已用 $used / $maxPer');

    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      leading: Icon(
        active ? Icons.check_circle : Icons.circle_outlined,
        size: 20,
        color: active
            ? theme.colorScheme.primary
            : theme.colorScheme.onSurfaceVariant,
      ),
      title: Text(
        proxy.displayName,
        style: theme.textTheme.bodySmall?.copyWith(
          fontWeight: active ? FontWeight.w600 : null,
        ),
      ),
      subtitle: Text(
        parts.join(' · '),
        style: theme.textTheme.labelSmall?.copyWith(
          color: probe != null && !probe!.ok
              ? theme.colorScheme.error
              : (full
                    ? theme.colorScheme.error
                    : theme.colorScheme.onSurfaceVariant),
        ),
      ),
      trailing: IconButton(
        tooltip: '删掉这条',
        onPressed: onRemove,
        icon: const Icon(Icons.delete_outline, size: 18),
      ),
      onTap: onUse,
    );
  }
}
