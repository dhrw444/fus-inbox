/// 设置页「短信」分组：翻译开关、保留原文、目标语言、引擎。
///
/// 四个都在同一组里，而且互相有联动（关掉翻译时「保留原文」就不能点）
/// —— 联动条件集中在这一个文件里，改的时候不会漏。
library;

import 'package:fus_inbox/core/prefs/prefs_provider.dart';
import 'package:fus_inbox/features/settings/presentation/widgets/settings_group.dart';
import 'package:fus_inbox/features/settings/presentation/widgets/settings_rows.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

/// 短信分组。prefs 由 SettingsScreen 统一 watch 传下来，写走 notifier。
class const SmsSection({required this.prefs, super.key})
    extends ConsumerWidget {
  final Prefs prefs;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(prefsProvider.notifier);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SettingsGroupLabel(text: '短信'),
        SettingsGroupCard(
          children: [
            SwitchListTile(
              title: const Text('实时翻译'),
              subtitle: const Text('英文短信自动翻成中文'),
              value: prefs.translate,
              onChanged: notifier.setTranslate,
            ),
            const Divider(height: 1, indent: 16, endIndent: 16),
            SwitchListTile(
              title: const Text('保留原文'),
              subtitle: Text(prefs.translate ? '译文下方同时显示英文原文' : '需先打开实时翻译'),
              value: prefs.showOriginal,
              // 关掉翻译时置灰：这时候「保留原文」没有任何意义，
              // 亮着会让用户以为点了有用。
              onChanged: prefs.translate ? notifier.setShowOriginal : null,
            ),
            const Divider(height: 1, indent: 16, endIndent: 16),
            LanguageRow(prefs: prefs),
            const Divider(height: 1, indent: 16, endIndent: 16),
            EngineRow(prefs: prefs),
          ],
        ),
      ],
    );
  }
}
