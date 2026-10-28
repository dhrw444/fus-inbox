/// 扩展色。
///
/// Material 3 的 `ColorScheme` 只有语义色（primary / surface / …），
/// 这个 App 还需要几个「这套配色自己定」的颜色，[ExtendedColor] 就是
/// 那些槽位，[ColorFamily] 是它们的明暗两值。
library;

import 'package:material_ui/material_ui.dart';

class const ExtendedColor({
  required this.seed,
  required this.value,
  required this.light,
  required this.lightHighContrast,
  required this.lightMediumContrast,
  required this.dark,
  required this.darkHighContrast,
  required this.darkMediumContrast,
}) {
  final Color seed, value;
  final ColorFamily light;
  final ColorFamily lightHighContrast;
  final ColorFamily lightMediumContrast;
  final ColorFamily dark;
  final ColorFamily darkHighContrast;
  final ColorFamily darkMediumContrast;
}

class const ColorFamily({
  required this.color,
  required this.onColor,
  required this.colorContainer,
  required this.onColorContainer,
}) {
  final Color color;
  final Color onColor;
  final Color colorContainer;
  final Color onColorContainer;
}
