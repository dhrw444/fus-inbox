import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fus_inbox/core/proxy/identity_ledger.dart';
import 'package:fus_inbox/core/proxy/proxy_config.dart';
import 'package:fus_inbox/core/proxy/proxy_probe.dart';
import 'package:fus_inbox/core/proxy/proxy_provider.dart';

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
    final total = raw
        .split('\n')
        .where((e) => e.trim().isNotEmpty && !e.trim().startsWith('#'))
        .length;
    setState(() {
      _message = errors.isEmpty
          ? '加了 ${total - errors.length} 条'
          : '加了 ${total - errors.length} 条，${errors.length} 条格式不对';
    });
    if (errors.length < total) _input.clear();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = ref.watch(proxyProvider);
    final notifier = ref.read(proxyProvider.notifier);
    final ledger = state.ledger;
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

          _StatusCard(state: state),
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

          // 连通性检测
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

          // 添加
          TextField(
            controller: _input,
            minLines: 1,
            maxLines: 4,
            style: theme.textTheme.bodySmall,
            decoration: InputDecoration(
              hintText: 'socks5://user:pass@host:1080',
              helperText: '支持 socks5 / socks5h / http / https，一行一条',
              helperMaxLines: 2,
              isDense: true,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
              ),
              suffixIcon: IconButton(
                tooltip: '添加',
                onPressed: _add,
                icon: const Icon(Icons.add, size: 20),
              ),
            ),
          ),
          if (_message != null) ...[
            const SizedBox(height: 6),
            Text(
              _message!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
          ],

          const SizedBox(height: 10),

          if (all.isEmpty)
            Text(
              '还没配代理。直连也能用，但配额按当前 IP 算，用满 3 个号就没法换了。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            )
          else ...[
            Row(
              children: [
                Text(
                  '共 ${all.length} 条'
                  '${state.builtin.isEmpty ? '' : '（内置 ${state.builtin.length}）'}',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const Spacer(),
                if (state.excludedBuiltin.isNotEmpty)
                  TextButton(
                    onPressed: () async {
                      await notifier.restoreBuiltin();
                      if (!mounted) return;
                      setState(() => _message = '已恢复被删的内置代理');
                    },
                    child: Text('恢复内置（${state.excludedBuiltin.length}）'),
                  ),
                TextButton(
                  onPressed: () {
                    notifier.clearLedger();
                    setState(() => _message = '使用记录已清空');
                  },
                  child: const Text('清记录'),
                ),
              ],
            ),
            ...all.map(
              (p) => _ProxyRow(
                proxy: p,
                active: p.id == state.currentId,
                used: ledger.usedFor(p.id),
                probe: state.results[p.id],
                onUse: () => notifier.select(p.id),
                onRemove: () => notifier.remove(p.id),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 当前出口 + 额度状态。
class const _StatusCard({required this.state}) extends StatelessWidget {
  final ProxyState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ledger = state.ledger;
    final usedNow = ledger.usedFor(state.currentId);
    final full = usedNow >= IdentityLedger.slotsPerIdentity;
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
            '${IdentityLedger.slotsPerIdentity} 个号',
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
class const _ProxyRow({
  required this.proxy,
  required this.active,
  required this.used,
  required this.probe,
  required this.onUse,
  required this.onRemove,
}) extends StatelessWidget {
  final ProxyConfig proxy;
  final bool active;
  final int used;
  final ProxyProbeResult? probe;
  final VoidCallback onUse;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final full = used >= IdentityLedger.slotsPerIdentity;

    // 副标题：先报检测结果，再说用量。没检测过就只说用量。
    final parts = <String>[];
    if (probe != null) {
      parts.add(
        probe!.ok ? '通 ${probe!.latencyMs}ms' : '不通（${probe!.failure}）',
      );
      // 出口 IP 是配额的真单位：同一个 IP 的代理再多也只算一个出口。
      if (probe!.egressIp.isNotEmpty) parts.add('出口 ${probe!.egressIp}');
    }
    parts.add(
      full
          ? '已用满 $used 个号，下次会跳过'
          : '已用 $used / ${IdentityLedger.slotsPerIdentity}',
    );

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
