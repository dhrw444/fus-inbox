import 'package:dynamic_color/dynamic_color.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:fus_inbox/core/theme/app_theme.dart';
import 'package:fus_inbox/core/theme/android_color_schemes.dart';
import 'package:fus_inbox/core/theme/dynamic_color_scheme.dart';
import 'package:fus_inbox/core/theme/util.dart';

part 'theme_provider.g.dart';

class AppThemeProvider({required this.lightTheme, required this.darkTheme}) {
  final ThemeData lightTheme;
  final ThemeData darkTheme;
}

/// 外观跟随系统。
///
/// 应用内没有主题设置入口，所以不需要持久化偏好；系统深色模式变化时
/// [MaterialApp] 会自行重建。
@Riverpod(keepAlive: true)
ThemeMode themeMode(Ref ref) => ThemeMode.system;

@Riverpod(keepAlive: true)
AppThemeProvider theme(Ref ref) {
  final textTheme = createTextTheme("Roboto", "Roboto");

  final appTheme = AppTheme(textTheme);

  return AppThemeProvider(
    lightTheme: appTheme.light(),
    darkTheme: appTheme.dark(),
  );
}

/// Test seam for [DynamicColorPlugin.getCorePalette].
/// Kept as a manual provider: function-typed providers are not supported
/// by `riverpod_generator`.
final dynamicCorePaletteLoaderProvider = Provider(
  (ref) => DynamicColorPlugin.getCorePalette,
);

final androidColorSchemeLoaderProvider = Provider(
  (ref) => loadAndroidColorSchemes,
);

@Riverpod(keepAlive: true)
Future<AppThemeProvider> dynamicTheme(Ref ref) async {
  final textTheme = createTextTheme("Roboto", "Roboto");
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
      debugPrint('Failed to load dynamic colors: $e');
      return null;
    }
  }();
  if (lightDynamic != null) {
    lightColorScheme = colorSchemeFromPlatformPalette(
      lightDynamic,
      brightness: .light,
    );
    darkColorScheme = colorSchemeFromPlatformPalette(
      lightDynamic,
      brightness: .dark,
    );
  } else {
    lightColorScheme = appTheme.light().colorScheme;
    darkColorScheme = appTheme.dark().colorScheme;
  }

  return AppThemeProvider(
    lightTheme: appTheme.theme(lightColorScheme),
    darkTheme: appTheme.theme(darkColorScheme),
  );
}
