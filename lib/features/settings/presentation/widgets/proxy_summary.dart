/// 代理清单头上那一行：条数统计 + 「恢复内置」+「清记录」。
///
/// 三个元素是同一条信息的两半：这一池子有多大、里面有多少是我删掉的、
/// 账本记得多满。拆出来是因为它们跟下面的列表无关 —— 列表收起来时
/// 这一行照样要露着。
library;

import 'package:material_ui/material_ui.dart';

/// 统计行 + 两个动作。纯展示，动作回调归 [ProxySection] 编排。
class const ProxySummaryRow({
  required this.total,
  required this.builtinCount,
  required this.excludedBuiltin,
  required this.onRestoreBuiltin,
  required this.onClearLedger,
  super.key,
}) extends StatelessWidget {
  /// 当前可用（内置 + 手加 - 被排除）的条数。
  final int total;

  /// 内置清单的条数。0 时统计里不带括号。
  final int builtinCount;

  /// 用户删掉的内置条数。为 0 时不显示「恢复内置」。
  final int excludedBuiltin;

  final VoidCallback onRestoreBuiltin;
  final VoidCallback onClearLedger;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Text(
          '共 $total 条${builtinCount == 0 ? '' : '（内置 $builtinCount）'}',
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const Spacer(),
        if (excludedBuiltin > 0)
          TextButton(
            onPressed: onRestoreBuiltin,
            child: Text('恢复内置（$excludedBuiltin）'),
          ),
        TextButton(onPressed: onClearLedger, child: const Text('清记录')),
      ],
    );
  }
}
