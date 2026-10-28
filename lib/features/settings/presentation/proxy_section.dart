/// 设置页的「代理」分组：出口状态、代理清单、连通性检测。
///
/// 拆成独立文件是因为它是设置页里唯一需要自己 rolling 状态的部分
/// （检测进度、每条的结果），和上面那些纯开关不是一回事。
///
/// 这一层现在只剩**编排**：状态卡 + 两个开关 + 添加框 + 统计行 + 列表，
/// 四块都在 `widgets/` 下（`proxy_add_field` / `proxy_summary` /
/// `proxy_list`，状态卡在 `proxy/proxy_cards.dart`）。
library;

import 'package:fus_inbox/core/proxy/proxy_provider.dart';
import 'package:fus_inbox/features/settings/presentation/proxy/proxy_cards.dart';
import 'package:fus_inbox/features/settings/presentation/widgets/proxy_add_field.dart';
import 'package:fus_inbox/features/settings/presentation/widgets/proxy_list.dart';
import 'package:fus_inbox/features/settings/presentation/widgets/proxy_summary.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

/// 设置页里的「代理」分组。
///
/// 站点配额记在**出口 IP** 上（实测：同一 IP 清空浏览器身份后第 4 个号
/// 照样被拒）。所以真正的杠杆是换 IP —— 换身份必须跟着换出口。
///
/// 这里让用户配一堆代理，App 按「一个代理 = 一个身份，用满 3 个号就换
/// 下一个代理 + 换身份」自己轮。
///
/// 内置清单和手动添加的**显示完全一样、都能删**。内置的只是记进排除
/// 表，APK 里的资源文件不动。
class const ProxySection({super.key}) extends ConsumerStatefulWidget {
  @override
  ConsumerState<ProxySection> createState() => _ProxySectionState();
}

class _ProxySectionState() extends ConsumerState<ProxySection> {
  final TextEditingController _input = TextEditingController();

  /// 添加框下面那行结果提示。三种动作（加 / 恢复内置 / 清记录）共用。
  String? _message;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    final raw = _input.text.trim();
    if (raw.isEmpty) return;
    final errors = await ref
        .read(proxyProvider.notifier)
        .addLines(raw.split('\n'));
    if (!mounted) return;
    // 这里自己再数一遍「有效行」（非空、非 # 注释）—— 它和 parseProxyLines
    // 内部的过滤**用途不同**：那边决定「哪些行尝试入库」，这边决定「提示里
    // 说总共几条、几条格式不对」。合并成一处会让提示口径跟着入库逻辑漂。
    final total = raw
        .split('\n')
        .where((e) => e.trim().isNotEmpty && !e.trim().startsWith('#'))
        .length;
    setState(() {
      _message = errors.isEmpty
          ? '加了 ${total - errors.length} 条'
          : '加了 ${total - errors.length} 条，${errors.length} 条格式不对';
    });
    // 有错的留着不清 —— 用户要看着那几行改。全加成功了才清空。
    if (errors.length < total) _input.clear();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = ref.watch(proxyProvider);
    final notifier = ref.read(proxyProvider.notifier);
    final all = state.all;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '一个代理绑一个身份，一个身份看 3 个号。满了自动换下一个代理，'
            '并换掉浏览器身份。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 10),

          ProxyStatusCard(state: state),
          const SizedBox(height: 8),

          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: Text('用满就自动换', style: theme.textTheme.bodyMedium),
            subtitle: Text(
              '关掉就只在手动点「下一个」时换',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            value: state.autoRotate,
            onChanged: notifier.setAutoRotate,
          ),

          // 连通性检测：真连一遍而不是只探端口（见 probeAll 的注释）。
          Row(
            children: [
              FilledButton.tonalIcon(
                onPressed: state.probing ? null : notifier.probeAll,
                icon: const Icon(Icons.network_check, size: 18),
                label: Text(
                  state.probing
                      ? '检测中 ${state.progress}/${state.probeTotal}'
                      : '全部检测',
                ),
              ),
              const SizedBox(width: 8),
              if (state.probing)
                Expanded(
                  child: LinearProgressIndicator(
                    value: state.probeTotal == 0
                        ? null
                        : state.progress / state.probeTotal,
                    minHeight: 3,
                  ),
                ),
            ],
          ),
          if (state.probing)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                '真连一遍：SOCKS5 握手 + 到达站点 + 读出口 IP。'
                '慢的网络要等一会。',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),

          const SizedBox(height: 12),

          ProxyAddField(controller: _input, message: _message, onAdd: _add),

          const SizedBox(height: 10),

          if (all.isEmpty)
            Text(
              '还没配代理。直连也能用，但配额按当前 IP 算，用满 3 个号就没法换了。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            )
          else ...[
            ProxySummaryRow(
              total: all.length,
              builtinCount: state.builtin.length,
              excludedBuiltin: state.excludedBuiltin.length,
              onRestoreBuiltin: () async {
                await notifier.restoreBuiltin();
                if (!mounted) return;
                setState(() => _message = '已恢复被删的内置代理');
              },
              onClearLedger: () {
                notifier.clearLedger();
                setState(() => _message = '使用记录已清空');
              },
            ),
            ProxyList(
              all: all,
              state: state,
              onUse: notifier.select,
              onRemove: notifier.remove,
            ),
          ],
        ],
      ),
    );
  }
}
