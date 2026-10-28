/// 骨架卡：给「消息还没到」一个形状，而不是空白转圈。
///
/// 形状和真实消息一致（一行头部 + 两行正文），来了消息就原地替换 ——
/// 所以它不该有任何动效，闪来闪去只会让人以为还在加载。
library;

import 'package:material_ui/material_ui.dart';

class const SkeletonTile({required this.theme, super.key})
    extends StatelessWidget {
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    final base = theme.colorScheme.onSurface.withValues(alpha: 0.07);
    Widget bar(double w, double h) => Container(
      width: w,
      height: h,
      decoration: BoxDecoration(
        color: base,
        borderRadius: BorderRadius.circular(h / 2),
      ),
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: bar(110, 11)),
              bar(52, 10),
            ],
          ),
          const SizedBox(height: 12),
          bar(double.infinity, 11),
          const SizedBox(height: 7),
          bar(220, 11),
        ],
      ),
    );
  }
}
