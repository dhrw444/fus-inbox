/// Material 3 Expressive 的过渡动画包装。
///
/// 只做一件事：给页面切换套上这套过渡。单独一个文件是因为它是唯一依赖
/// `material_3_expressive` 的地方，那三家包要换只动这里。
library;

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

class const ExpressiveTheme({required this.child, super.key})
    extends StatelessWidget {
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final material = Theme.of(context);
    // M3E 的主题投影会丢掉几个固定角色色，所以只拿它覆盖字体，
    // 配色仍然用系统给的那套完整 scheme。
    return Theme(
      data: material.copyWith(
        textTheme: M3ETypography.material3().baseline
            .withColor(material.colorScheme.onSurface)
            .toTextTheme(),
      ),
      // 兼容桥：仓库里还有依赖在用 package:flutter/material.dart。
      // ignore: deprecated_member_use
      child: MaterialUiCompatibilityBridge(child: child),
    );
  }
}
