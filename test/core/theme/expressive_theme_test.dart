/// Expressive 主题包装不能改掉任何颜色。
///
/// 那一层只该加过渡动画。它要是顺手改了一个语义色，整个 App 的配色就
/// 跟着歪，而这种偏差在界面上很难一眼看出来 —— 所以逐色比对。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:fus_inbox/core/theme/app_theme.dart';
import 'package:fus_inbox/core/theme/expressive_theme.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  for (final brightness in Brightness.values) {
    testWidgets('preserves native roles in expressive ${brightness.name}', (
      tester,
    ) async {
      late ColorScheme material;
      late M3EColorScheme expressive;
      final scheme = ColorScheme.fromSeed(
        seedColor: const Color(0xff006c4c),
        brightness: brightness,
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme(Typography.englishLike2021).theme(scheme),
          builder: (context, child) => ExpressiveTheme(child: child!),
          home: Builder(
            builder: (context) {
              material = Theme.of(context).colorScheme;
              expressive = M3ETheme.of(context).colorScheme;
              return const Scaffold();
            },
          ),
        ),
      );

      expect(material, scheme);
      for (final converted in [material, expressive.toColorScheme()]) {
        expect(converted.brightness, brightness);
        expect(converted.primary, scheme.primary);
        expect(converted.onPrimary, scheme.onPrimary);
        expect(converted.primaryContainer, scheme.primaryContainer);
        expect(converted.onPrimaryContainer, scheme.onPrimaryContainer);
        expect(converted.surface, scheme.surface);
        expect(converted.onSurface, scheme.onSurface);
        expect(converted.surfaceContainerLow, scheme.surfaceContainerLow);
        expect(converted.surfaceContainerHigh, scheme.surfaceContainerHigh);
        expect(converted.inverseSurface, scheme.inverseSurface);
        expect(converted.onInverseSurface, scheme.onInverseSurface);
        expect(converted.error, scheme.error);
      }
    });
  }
}
