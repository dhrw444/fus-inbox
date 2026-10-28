/// 设置页「代理」分组的壳：目录要不要走代理 + 代理清单本体。
///
/// 拆出来是为了让 `settings_screen.dart` 不认识 `ProxySection` ——
/// 那个开关和下面的代理清单是同一件事的两半（走不走这条出口），
/// 摆在一起，加一项代理相关的设置不会漏掉另一半。
library;

import 'package:fus_inbox/core/prefs/prefs_provider.dart';
import 'package:fus_inbox/features/settings/presentation/proxy_section.dart';
import 'package:fus_inbox/features/settings/presentation/widgets/settings_group.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

/// 「代理」分组入口：一个总开关 + 代理清单。
class const ProxySettingsSection({super.key}) extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prefs = ref.watch(prefsProvider);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SettingsGroupLabel(text: '代理'),
        SettingsGroupCard(
          children: [
            SwitchListTile(
              title: const Text('号码目录走代理'),
              subtitle: const Text(
                '关：目录用真实 IP。目录是公开列表，不消耗开号额度，'
                '也不占用代理。\n'
                '开：与收件页共用当前出口。代理不可用时目录会报错，'
                '不会退回直连。',
              ),
              isThreeLine: true,
              value: prefs.directoryViaProxy,
              onChanged: (v) =>
                  ref.read(prefsProvider.notifier).setDirectoryViaProxy(v),
            ),
            const Divider(height: 1, indent: 16, endIndent: 16),
            const ProxySection(),
          ],
        ),
      ],
    );
  }
}
