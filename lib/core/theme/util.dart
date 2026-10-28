/// 字体主题。
///
/// 只负责把两种字体名拼成 `TextTheme`；具体用哪套颜色、哪套动效不在这里。
library;

import 'package:material_ui/material_ui.dart';

/// 按正文字体名和标题字体名造一套 `TextTheme`。
///
/// ## 之前这个函数是假的
///
/// 它收了两个字体名，然后**直接返回** `Typography.englishLike2021` ——
/// 一个参数都没用上。调用方 `theme_provider.dart` 认认真真传了
/// `createTextTheme('Roboto', 'Roboto')`，看着像在配字体，实际什么也没做。
///
/// 后果：这个 App 要上 Windows，而 Windows 上没有 Roboto，系统会回落到
/// 默认的 Segoe UI —— 那时 `englishLike2021` 里写死的字体族和实际渲染的
/// 字体不一致，字重、行高、字母间距全是按 Roboto 的度量算的，落到
/// Segoe UI 上会偏挤。用户看不出原因，只觉得「Windows 版字有点怪」。
///
/// 现在：以 `englishLike2021` 为**度量基准**（它是 Material 3 的排版
/// 规格，不该换），把两处字体族真的套上去。
///
/// - [bodyFontString] 套到全部正文样式
/// - [displayFontString] 套到大标题那几个（display / headline）
///
/// 两个都传空串 = 不指定字体族，交给系统默认（和旧行为一致，但那是
/// **显式选择**，不是「参数被忽略」）。
TextTheme createTextTheme(String bodyFontString, String displayFontString) {
  const base = Typography.englishLike2021;
  final body = bodyFontString.isEmpty ? null : bodyFontString;
  final display = displayFontString.isEmpty ? null : displayFontString;
  if (body == null && display == null) return base;

  // 大标题用 display 字体，其余用 body 字体。Material 3 的分工：
  // display* / headline* 是「标题」，title* / body* / label* 是「正文」。
  TextStyle? heading(TextStyle? s) => s?.copyWith(fontFamily: display ?? body);
  TextStyle? text(TextStyle? s) => s?.copyWith(fontFamily: body);

  return base.copyWith(
    displayLarge: heading(base.displayLarge),
    displayMedium: heading(base.displayMedium),
    displaySmall: heading(base.displaySmall),
    headlineLarge: heading(base.headlineLarge),
    headlineMedium: heading(base.headlineMedium),
    headlineSmall: heading(base.headlineSmall),
    titleLarge: text(base.titleLarge),
    titleMedium: text(base.titleMedium),
    titleSmall: text(base.titleSmall),
    bodyLarge: text(base.bodyLarge),
    bodyMedium: text(base.bodyMedium),
    bodySmall: text(base.bodySmall),
    labelLarge: text(base.labelLarge),
    labelMedium: text(base.labelMedium),
    labelSmall: text(base.labelSmall),
  );
}
