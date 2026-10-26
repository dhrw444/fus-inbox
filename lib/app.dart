import 'package:material_3_expressive/material_3_expressive.dart';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fus_inbox/core/constants/app_constants.dart';
import 'package:fus_inbox/core/theme/expressive_theme.dart';
import 'package:fus_inbox/core/theme/theme_provider.dart';
import 'package:fus_inbox/features/main/presentation/main_screen.dart';

/// 应用外壳：只负责主题与首页。
///
/// 号码目录与收件箱之间的跳转由 [MainScreen] 自己处理，这里不再持有任何
/// 全局导航或路由状态。
class const App({super.key}) extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeAsync = ref.watch(dynamicThemeProvider);
    final themeMode = ref.watch(themeModeProvider);

    return themeAsync.when(
      data: (theme) => MaterialApp(
        title: AppConstants.appName,
        theme: theme.lightTheme,
        darkTheme: theme.darkTheme,
        themeMode: themeMode,
        builder: (context, child) => ExpressiveTheme(child: child!),
        home: const MainScreen(),
      ),
      loading: () => MaterialApp(
        builder: (context, child) => ExpressiveTheme(child: child!),
        home: const Scaffold(
          body: Center(child: M3EProgressIndicator.circularWavy()),
        ),
      ),
      // 主题加载失败不该让用户面对一行英文堆栈。
      // 动态取色只是锦上添花，降级到内置配色就能继续用。
      error: (err, stack) => MaterialApp(
        builder: (context, child) => ExpressiveTheme(child: child!),
        home: Consumer(
          builder: (context, ref, _) => Scaffold(
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.palette_outlined, size: 40),
                    const SizedBox(height: 14),
                    const Text('主题加载失败，已降级为默认配色'),
                    const SizedBox(height: 4),
                    Text(
                      '$err',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                    const SizedBox(height: 16),
                    FilledButton.tonal(
                      onPressed: () => ref.invalidate(dynamicThemeProvider),
                      child: const Text('重新加载'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
