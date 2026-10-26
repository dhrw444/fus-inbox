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
      error: (err, stack) => MaterialApp(
        builder: (context, child) => ExpressiveTheme(child: child!),
        home: Scaffold(body: Center(child: Text('Error: $err'))),
      ),
    );
  }
}
