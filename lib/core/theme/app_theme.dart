/// 内置配色的 `ThemeData` 装配。
///
/// 配色本身（六套 `ColorScheme`）在 `theme_schemes.dart`；这里只管
/// 「拿一套配色 + 一个字体主题，拼成 `ThemeData`」。
///
/// 系统动态配色可用时会被 `theme_provider.dart` 覆盖掉 —— 这里是**兜底**，
/// 也是用户在设置里手动选色时用的那份。
library;

import 'package:fus_inbox/core/theme/extended_color.dart';
import 'package:fus_inbox/core/theme/theme_schemes.dart';
import 'package:material_ui/material_ui.dart';

class const AppTheme(this.textTheme) {
  final TextTheme textTheme;

  ThemeData light() {
    return theme(AppColorSchemes.lightScheme());
  }

  ThemeData lightMediumContrast() {
    return theme(AppColorSchemes.lightMediumContrastScheme());
  }

  ThemeData lightHighContrast() {
    return theme(AppColorSchemes.lightHighContrastScheme());
  }

  ThemeData dark() {
    return theme(AppColorSchemes.darkScheme());
  }

  ThemeData darkMediumContrast() {
    return theme(AppColorSchemes.darkMediumContrastScheme());
  }

  ThemeData darkHighContrast() {
    return theme(AppColorSchemes.darkHighContrastScheme());
  }

  ThemeData theme(ColorScheme colorScheme) => ThemeData(
    useMaterial3: true,
    brightness: colorScheme.brightness,
    colorScheme: colorScheme,
    iconTheme: IconThemeData(color: colorScheme.onSurfaceVariant),
    textTheme: textTheme.apply(
      bodyColor: colorScheme.onSurface,
      displayColor: colorScheme.onSurface,
    ),
    scaffoldBackgroundColor: colorScheme.surface,
    canvasColor: colorScheme.surface,
  );

  List<ExtendedColor> get extendedColors => [];
}
