/// AppBar 标题位上的搜索输入框。
///
/// 收件箱和号码页各要一份，两边原来把整段 `TextField` 各写了一遍 ——
/// **除了 hint 文案以外逐字相同**：同样的 `autofocus`、
/// `textInputAction: TextInputAction.search`、同样的
/// `InputDecoration(border: InputBorder.none)`。
///
/// 这种「差一个字符串的复制」迟早会漂 —— 本仓已经漂过一次（两边的
/// 搜索按钮 tooltip 一个写「搜索验证码」一个写「搜索」，改了一边忘另一边）。
/// 收成一处之后，行为只有一份定义，两边只提供各自的 hint。
library;

import 'package:material_ui/material_ui.dart';

/// AppBar 里的搜索输入框。
///
/// [hintText] 由调用方给（两个页面的搜索维度不同：收件箱搜
/// 验证码/发送方/正文，号码页搜号码/区号/州），其余行为统一在这里。
class const AppBarSearchField({
  required this.controller,
  required this.hintText,
  required this.onChanged,
  super.key,
}) extends StatelessWidget {
  /// 由页面持有 —— 焦点、光标位置、以及「退出搜索时清空」都由页面决定。
  final TextEditingController controller;

  /// 占位提示。见类文档。
  final String hintText;

  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      // 点放大镜就把键盘顶上来，省一次点击。
      autofocus: true,
      // 让软键盘的「确认」键变成放大镜 —— 和工具栏上那个按钮同一个意思。
      textInputAction: TextInputAction.search,
      keyboardType: TextInputType.text,
      decoration: InputDecoration(hintText: hintText, border: InputBorder.none),
      onChanged: onChanged,
    );
  }
}
