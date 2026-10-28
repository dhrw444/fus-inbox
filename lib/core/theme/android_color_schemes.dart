/// 从 Android 系统取的动态配色。
///
/// 系统给了 `corePalette` 就拿它生成一整套 `ColorScheme`；取不到（老系统、
/// 非 Android、或者通道超时）就回落到内置配色 —— 取色失败不该让界面没颜色。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:fus_inbox/core/log.dart';
import 'package:fus_inbox/core/theme/dynamic_color_scheme.dart';
import 'package:material_ui/material_ui.dart';

Future<({ColorScheme light, ColorScheme dark})?>
loadAndroidColorSchemes() async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return null;

  try {
    final palettes = await const MethodChannel('fusinbox/theme')
        .invokeMapMethod<String, dynamic>('getColorSchemes');
    if (palettes == null) return null;

    ColorScheme read(String mode, Brightness brightness) {
      final raw = palettes[mode];
      if (raw is! Map<Object?, Object?>) {
        throw FormatException('Missing Android $mode color scheme');
      }
      return colorSchemeFromAndroidRoles(
        Map<String, int>.from(raw),
        brightness: brightness,
      );
    }

    return (light: read('light', .light), dark: read('dark', .dark));
  } catch (error) {
    logLine('Could not load Android color roles: $error');
    return null;
  }
}
