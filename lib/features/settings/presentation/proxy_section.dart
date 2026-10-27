import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fus_inbox/core/proxy/proxy_config.dart';
import 'package:fus_inbox/core/proxy/proxy_engine.dart';
import 'package:fus_inbox/core/proxy/proxy_provider.dart';

/// 设置页里的「代理」分组。
///
/// 站点配额记在**出口 IP** 上（实测：同一 IP 清空浏览器身份后第 4 个号
/// 照样被拒）。所以真正的杠杆是换 IP —— 换身份必须跟着换出口。
///
/// 这里让用户配一堆代理，App 按「一个代理 = 一个身份，用满 3 个号就换
/// 下一个代理 + 换身份」自己轮。
class _ProxySection extends ConsumerStatefulWidget {
  const _ProxySection();

  @override
  ConsumerState<_ProxySection> createState() => _ProxySectionState();
}

class _ProxySectionState extends ConsumerState<_ProxySection> {
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
    var added = 0;
    var failed = 0;
    // 一次可以贴多行，省得一条条加。
    for (final line in raw.split('\n')) {
      if (line.trim().isEmpty) continue;
      final ok = await ref.read(proxyProvider.notifier).addFromLine(line);
      if (ok) {
        added++;
      } else {
        failed++;
      }
    }
    if (!mounted) return;
    setState(() {
      _message = failed == 0
          ? '加了 $added 条'
          : '加了 $added 条，$failed 条格式不对';
    });
    if (added > 0) _input.clear();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = ref.watch(proxyProvider);
    final notifier = ref.read(proxyProvider.notifier);
    final ledger = state.ledger;

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

          // 当前状态
          Container(
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
                  '这个出口已看 ${ledger.usedOnCurrent} / ${IdentityLedger.slotsPerIdentity} 个号',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: ledger.usedOnCurrent >= IdentityLedger.slotsPerIdentity
                        ? theme.colorScheme.error
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),

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
            onChanged: (v) => notifier.setAutoRotate(v),
          ),

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
          const SizedBox(height: 12),

          if (state.pool.isEmpty)
            Text(
              '还没配代理。直连也能用，但配额按当前 IP 算，用满 3 个号就没法换了。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            )
          else
            ...state.pool.map(
              (p) => _ProxyRow(
                proxy: p,
                active: p.id == state.currentId,
                used: ledger.usedFor(p.id),
                onUse: () => notifier.useProxy(p.id),
                onRemove: () => notifier.remove(p.id),
              ),
            ),

          if (state.pool.isNotEmpty) ...[
            const SizedBox(height: 4),
            Row(
              children: [
                TextButton.icon(
                  onPressed: () async {
                    final r = await probeProxy(state.current);
                    if (!mounted) return;
                    setState(() => _message = r.detail);
                  },
                  icon: const Icon(Icons.speed, size: 18),
                  label: const Text('测当前出口'),
                ),
                TextButton.icon(
                  onPressed: () {
                    notifier.clearLedger();
                    setState(() => _message = '使用记录已清空');
                  },
                  icon: const Icon(Icons.restart_alt, size: 18),
                  label: const Text('清记录'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// 一条代理。
class _ProxyRow extends StatelessWidget {
  const _ProxyRow({
    required this.proxy,
    required this.active,
    required this.used,
    required this.onUse,
    required this.onRemove,
  });

  final ProxyConfig proxy;
  final bool active;
  final int used;
  final VoidCallback onUse;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final full = used >= IdentityLedger.slotsPerIdentity;
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
        full ? '已用满 $used 个号，下次会跳过' : '已用 $used / ${IdentityLedger.slotsPerIdentity}',
        style: theme.textTheme.labelSmall?.copyWith(
          color: full ? theme.colorScheme.error : theme.colorScheme.onSurfaceVariant,
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
