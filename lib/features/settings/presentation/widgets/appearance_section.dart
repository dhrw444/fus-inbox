/// 设置页「外观」分组：主题三选一 + 正文字号。
///
/// 分组内容从 `settings_screen.dart` 搬出来，那一页现在只剩
/// 「按顺序摆分组」—— 加一项设置不用再翻一百行找位置。
library;

import 'package:fus_inbox/core/prefs/prefs_provider.dart';
import 'package:fus_inbox/features/settings/presentation/widgets/settings_group.dart';
import 'package:fus_inbox/features/settings/presentation/widgets/settings_rows.dart';
import 'package:material_ui/material_ui.dart';

/// 外观分组：两行都从 [prefs] 读，写走各自 row 里的 provider。
class const AppearanceSection({required this.prefs, super.key})
    extends StatelessWidget {
  /// 由 SettingsScreen 统一 watch 后传下来的偏好。
  final Prefs prefs;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SettingsGroupLabel(text: '外观'),
        SettingsGroupCard(
          children: [
            const ThemeModeRow(),
            const Divider(height: 1, indent: 16, endIndent: 16),
            FontSizeRow(prefs: prefs),
          ],
        ),
      ],
    );
  }
}
