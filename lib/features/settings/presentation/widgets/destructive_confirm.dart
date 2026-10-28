/// 破坏性操作前的二次确认。
///
/// ## 为什么值得单独一个文件
///
/// 设置页有五个动作是**点一下就生效、而且不可撤销**的：
///
/// | 动作 | 后果 |
/// |---|---|
/// | 清空使用记录 | 所有代理的用量归零 → 直接改变配额轮换判定 |
/// | 删掉一条代理 | 手动加的不可恢复 |
/// | 清空翻译缓存 | 所有译文要重新请求 |
/// | 清空号码目录缓存 | 要重新拉一遍目录 |
///
/// 它们原先各自「一个 Snackbar 事后通知」。而 Snackbar 报的是**结果**，
/// 不是**后果** —— 用户按下去之前没有任何刹车。误触成本又高：
/// 清记录的后果（配额判定变了）离按钮很远，事后根本联想不到。
///
/// 所以统一走这一个框：说清「要动什么、动了会怎样」，再给一个
/// 明确的确认词。**放在一处**是因为五个地方的措辞和按钮色应该一样 ——
/// 各写各的迟早会漂。
library;

import 'package:material_ui/material_ui.dart';

/// 弹一个二次确认框。返回 true 表示用户真的确认了。
///
/// [title] 是一句话问句（「清空使用记录？」），[message] 说清后果
/// （不是复述标题），[confirmLabel] 是动词短语（「清空」）。
///
/// 取消是默认方向：`barrierDismissible` 保持 true、取消按钮在左、
/// 确认按钮用 error 色 —— 让人下意识按到的是取消。
Future<bool> confirmDestructive(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
}) async {
  final scheme = Theme.of(context).colorScheme;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          style: TextButton.styleFrom(foregroundColor: scheme.error),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  // 点遮罩关掉时 `ok` 是 null —— 当成取消。
  return ok ?? false;
}
