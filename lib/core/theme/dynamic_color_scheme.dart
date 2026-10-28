/// 把系统给的调色板转成 `ColorScheme`。
///
/// 纯函数，不碰平台通道 —— 取色在 `android_color_schemes.dart`，
/// 这里只管「拿到一组颜色之后怎么排」。
library;

import 'package:material_color_utilities/material_color_utilities.dart';
import 'package:material_ui/material_ui.dart';

ColorScheme colorSchemeFromPlatformPalette(
  // dynamic_color 目前仍然返回这个已废弃的调色板容器，只能先收着。
  // ignore: deprecated_member_use
  CorePalette palette, {
  required Brightness brightness,
}) {
  // 不能改成「重新播种」（拿 sourceColorHct 重生成一套）：那会顶掉
  // Android 自己算出来的中性色和强调色，直接喂它给的 palette 才是原样。
  final scheme = DynamicScheme(
    sourceColorHct: Hct.fromInt(palette.primary.get(40)),
    variant: Variant.tonalSpot,
    isDark: brightness == Brightness.dark,
    primaryPalette: palette.primary,
    secondaryPalette: palette.secondary,
    tertiaryPalette: palette.tertiary,
    neutralPalette: palette.neutral,
    neutralVariantPalette: palette.neutralVariant,
    errorPalette: palette.error,
  );

  return _colorSchemeFromRoles(brightness, scheme.getArgb);
}

/// 从 Android 原生给的「角色名 → 颜色值」映射造一套 `ColorScheme`。
///
/// [colors] 的键是 Material 角色的 snake_case 名（`primary`、`on_surface`
/// ……），由 `android_color_schemes.dart` 从 Kotlin 侧读回来。
///
/// 缺角色时**抛** `FormatException` 而不是回落默认值：这个函数的调用方
/// 已经在 `theme_provider.dart` 里包了一层 try —— 那里据此判断「系统
/// 配色不可用」并降级到下一层。在这里悄悄补一个编出来的颜色，反而会让
/// 界面配色半真半假，比明确失败更难查。
ColorScheme colorSchemeFromAndroidRoles(
  Map<String, int> colors, {
  required Brightness brightness,
}) => _colorSchemeFromRoles(brightness, (role) {
  final value = colors[role.name];
  if (value == null) {
    throw FormatException('系统配色缺少角色 ${role.name}');
  }
  return value;
});

/// 两条来源（动态调色板 / Android 原生角色）共用的那一步：逐个角色取值。
///
/// [resolve] 把「哪个角色」变成「一个 ARGB 整数」——两个来源的实现方式
/// 完全不同（一个从调色板算，一个查表），但**要填的槽位是同一份**。
/// 所以列在这里一次，两边不会漏掉某个角色。
ColorScheme _colorSchemeFromRoles(
  Brightness brightness,
  int Function(DynamicColor) resolve,
) {
  Color color(DynamicColor role) => Color(resolve(role));
  return ColorScheme(
    brightness: brightness,
    primary: color(MaterialDynamicColors.primary),
    onPrimary: color(MaterialDynamicColors.onPrimary),
    primaryContainer: color(MaterialDynamicColors.primaryContainer),
    onPrimaryContainer: color(MaterialDynamicColors.onPrimaryContainer),
    primaryFixed: color(MaterialDynamicColors.primaryFixed),
    primaryFixedDim: color(MaterialDynamicColors.primaryFixedDim),
    onPrimaryFixed: color(MaterialDynamicColors.onPrimaryFixed),
    onPrimaryFixedVariant: color(MaterialDynamicColors.onPrimaryFixedVariant),
    secondary: color(MaterialDynamicColors.secondary),
    onSecondary: color(MaterialDynamicColors.onSecondary),
    secondaryContainer: color(MaterialDynamicColors.secondaryContainer),
    onSecondaryContainer: color(MaterialDynamicColors.onSecondaryContainer),
    secondaryFixed: color(MaterialDynamicColors.secondaryFixed),
    secondaryFixedDim: color(MaterialDynamicColors.secondaryFixedDim),
    onSecondaryFixed: color(MaterialDynamicColors.onSecondaryFixed),
    onSecondaryFixedVariant: color(
      MaterialDynamicColors.onSecondaryFixedVariant,
    ),
    tertiary: color(MaterialDynamicColors.tertiary),
    onTertiary: color(MaterialDynamicColors.onTertiary),
    tertiaryContainer: color(MaterialDynamicColors.tertiaryContainer),
    onTertiaryContainer: color(MaterialDynamicColors.onTertiaryContainer),
    tertiaryFixed: color(MaterialDynamicColors.tertiaryFixed),
    tertiaryFixedDim: color(MaterialDynamicColors.tertiaryFixedDim),
    onTertiaryFixed: color(MaterialDynamicColors.onTertiaryFixed),
    onTertiaryFixedVariant: color(MaterialDynamicColors.onTertiaryFixedVariant),
    error: color(MaterialDynamicColors.error),
    onError: color(MaterialDynamicColors.onError),
    errorContainer: color(MaterialDynamicColors.errorContainer),
    onErrorContainer: color(MaterialDynamicColors.onErrorContainer),
    surface: color(MaterialDynamicColors.surface),
    onSurface: color(MaterialDynamicColors.onSurface),
    surfaceDim: color(MaterialDynamicColors.surfaceDim),
    surfaceBright: color(MaterialDynamicColors.surfaceBright),
    surfaceContainerLowest: color(MaterialDynamicColors.surfaceContainerLowest),
    surfaceContainerLow: color(MaterialDynamicColors.surfaceContainerLow),
    surfaceContainer: color(MaterialDynamicColors.surfaceContainer),
    surfaceContainerHigh: color(MaterialDynamicColors.surfaceContainerHigh),
    surfaceContainerHighest: color(
      MaterialDynamicColors.surfaceContainerHighest,
    ),
    onSurfaceVariant: color(MaterialDynamicColors.onSurfaceVariant),
    outline: color(MaterialDynamicColors.outline),
    outlineVariant: color(MaterialDynamicColors.outlineVariant),
    inverseSurface: color(MaterialDynamicColors.inverseSurface),
    onInverseSurface: color(MaterialDynamicColors.inverseOnSurface),
    inversePrimary: color(MaterialDynamicColors.inversePrimary),
    shadow: color(MaterialDynamicColors.shadow),
    scrim: color(MaterialDynamicColors.scrim),
    surfaceTint: color(MaterialDynamicColors.surfaceTint),
  );
}
