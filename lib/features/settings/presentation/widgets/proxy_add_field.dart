/// 代理「添加」框：一行一条的粘贴区 + 上一次动作的结果。
///
/// 从 `proxy_section.dart` 搬出来。输入框和结果提示必须挨着 ——
/// 提示说的是「加了 3 条，1 条格式不对」，放在别处用户不知道说的是谁。
library;

import 'package:material_ui/material_ui.dart';

/// 粘贴区 + 结果提示的成对展示。归 [ProxySection] 编排，自己不碰 provider。
class const ProxyAddField({
  required this.controller,
  required this.message,
  required this.onAdd,
  super.key,
}) extends StatelessWidget {
  /// 粘贴区。归 Section 持有 —— 加成功后要清空它。
  final TextEditingController controller;

  /// 上一次动作的结果（加了几条 / 已恢复内置 / 已清空）。null = 不显示。
  final String? message;

  /// 点右边加号（或按键盘回车）时调。
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: controller,
          minLines: 1,
          maxLines: 4,
          style: theme.textTheme.bodySmall,
          decoration: InputDecoration(
            hintText: 'socks5://user:pass@host:1080',
            helperText: '支持 socks5 / socks5h / http / https，一行一条',
            helperMaxLines: 2,
            isDense: true,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
            suffixIcon: IconButton(
              tooltip: '添加',
              onPressed: onAdd,
              icon: const Icon(Icons.add, size: 20),
            ),
          ),
        ),
        if (message != null) ...[
          const SizedBox(height: 6),
          Text(
            message!,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.primary,
            ),
          ),
        ],
      ],
    );
  }
}
