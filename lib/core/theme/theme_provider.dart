/// 主题：动态取色 + 深浅色模式。
///
/// 全部手写 provider，不用 `@Riverpod` 注解 —— 项目已移除 build_runner，
/// 没有 `.g.dart` 可用，注解会直接编译失败。
library;

import 'package:dynamic_color/dynamic_color.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fus_inbox/core/theme/app_theme.dart';
import 'package:fus_inbox/core/theme/android_color_schemes.dart';
import 'package:fus_inbox/core/theme/dynamic_color_scheme.dart';
import 'package:fus_inbox/core/theme/util.dart';

const _kThemeMode = 'theme_mode';

/// 一对主题。
class const AppThemeProvider({
  required this.lightTheme,
  required this.darkTheme,
}) {
  final ThemeData lightTheme;
  final ThemeData darkTheme;
}

/// 测试接缝：允许测试替换动态取色的来源。
///
/// 保持手写 [Provider]——函数类型的 provider 不被 riverpod_generator 支持。
final dynamicCorePaletteLoaderProvider = Provider(
  (ref) => DynamicColorPlugin.getCorePalette,
);

final androidColorSchemeLoaderProvider = Provider(
  (ref) => loadAndroidColorSchemes,
);

/// 构建主题：优先用 Android 系统取色，其次动态调色板，最后回落到内置配色。
///
/// 三层降级是有意的：取色在部分 ROM 上会抛异常，绝不能因此白屏。
final dynamicThemeProvider = FutureProvider<AppThemeProvider>((ref) async {
  final textTheme = createTextTheme('Roboto', 'Roboto');
  final appTheme = AppTheme(textTheme);

  final loadAndroidSchemes = ref.watch(androidColorSchemeLoaderProvider);
  final loadDynamicCorePalette = ref.watch(dynamicCorePaletteLoaderProvider);

  final androidSchemes = await loadAndroidSchemes();
  if (androidSchemes != null) {
    return AppThemeProvider(
      lightTheme: appTheme.theme(androidSchemes.light),
      darkTheme: appTheme.theme(androidSchemes.dark),
    );
  }

  ColorScheme? lightColorScheme;
  ColorScheme? darkColorScheme;

  final lightDynamic = await () async {
    try {
      return await loadDynamicCorePalette();
    } catch (e) {
      debugPrint('取色失败，回落到内置配色: $e');
      return null;
    }
  }();

  if (lightDynamic != null) {
    lightColorScheme = colorSchemeFromPlatformPalette(
      lightDynamic,
      brightness: Brightness.light,
    );
    darkColorScheme = colorSchemeFromPlatformPalette(
      lightDynamic,
      brightness: Brightness.dark,
    );
  } else {
    lightColorScheme = appTheme.light().colorScheme;
    darkColorScheme = appTheme.dark().colorScheme;
  }

  return AppThemeProvider(
    lightTheme: appTheme.theme(lightColorScheme),
    darkTheme: appTheme.theme(darkColorScheme),
  );
});

/// 深浅色模式，落盘保存。
class ThemeModeNotifier() extends Notifier<ThemeMode> {
  bool _restored = false;

  @override
  ThemeMode build() {
    _restore();
    return ThemeMode.system;
  }

  Future<void> _restore() async {
    if (_restored) return;
    _restored = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final m = _parse(prefs.getString(_kThemeMode));
      if (m != null && m != state) state = m;
    } catch (_) {
      // 读不到就跟随系统，不影响启动。
    }
  }

  static ThemeMode? _parse(String? v) => switch (v) {
    'light' => ThemeMode.light,
    'dark' => ThemeMode.dark,
    'system' => ThemeMode.system,
    _ => null,
  };

  static String _name(ThemeMode m) => switch (m) {
    ThemeMode.light => 'light',
    ThemeMode.dark => 'dark',
    ThemeMode.system => 'system',
  };

  /// 切换并落盘。
  Future<void> set(ThemeMode m) async {
    state = m;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kThemeMode, _name(m));
    } catch (_) {
      // 落盘失败不影响本次会话内的切换。
    }
  }
}

final themeModeProvider = NotifierProvider<ThemeModeNotifier, ThemeMode>(
  ThemeModeNotifier.new,
);
