/// 号码列表顶部的筛选栏：页签 chip + 当前搜索词的清除 chip。
///
/// 从 `numbers_screen.dart` 搬出来。排序和搜索输入都不在这里 ——
/// 前者在顶栏菜单、后者在顶栏展开的输入框，这一栏只负责「页签怎么选」。
library;

import 'package:fus_inbox/features/numbers/application/numbers_provider.dart';
import 'package:material_ui/material_ui.dart';

class const NumberFilterBar({
  required this.dir,
  required this.onTab,
  required this.onClearQuery,
  super.key,
}) extends StatelessWidget {
  final NumberDirectoryState dir;
  final void Function(NumberTab) onTab;
  final VoidCallback onClearQuery;

  @override
  Widget build(BuildContext context) {
    // 用 Wrap 而不是横向 ListView：固定高度 + 横向滚动在窄屏或大字号下
    // 会把最后一个 chip 切掉一半，而且没有任何「还能滑」的提示。
    // Wrap 会在放不下时自动换行，永远不会切。
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      child: Wrap(
        spacing: 8,
        runSpacing: 2,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          for (final t in NumberTab.values)
            FilterChip(
              selected: dir.tab == t,
              onSelected: (_) => onTab(t),
              showCheckmark: false,
              label: Text('${t.label} ${dir.countFor(t)}'),
            ),
          if (dir.query.trim().isNotEmpty)
            ActionChip(
              avatar: const Icon(Icons.close, size: 16),
              label: Text('清除「${dir.query.trim()}」'),
              onPressed: onClearQuery,
            ),
        ],
      ),
    );
  }
}
