/// 设置页的两种容器：分组标题、分组卡片。
///
/// 全页所有设置项都套在这两个里，所以单独放一个文件 ——
/// 想调分组间距/圆角时只有这一处要看。
library;

import 'package:material_ui/material_ui.dart';

/// 分组标题：主色小字，压在卡片外面。
class const SettingsGroupLabel({required this.text, super.key})
    extends StatelessWidget {
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
      child: Text(
        text,
        style: theme.textTheme.labelLarge?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.3,
        ),
      ),
    );
  }
}

/// 分组卡片：无阴影、16dp 圆角、淡色底。
class const SettingsGroupCard({required this.children, super.key})
    extends StatelessWidget {
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      clipBehavior: Clip.antiAlias,
      child: Column(mainAxisSize: MainAxisSize.min, children: children),
    );
  }
}
