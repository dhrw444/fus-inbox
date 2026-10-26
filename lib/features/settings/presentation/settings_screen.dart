/// 设置页：主题深浅色 + 翻译开关 + 关于信息。
///
/// 全部用原生 Material 3 组件，没有第三方设置库——这里只有四五个开关，
/// 引入一个库反而多一层要维护的抽象。
library;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fus_inbox/core/prefs/prefs_provider.dart';
import 'package:fus_inbox/core/theme/theme_provider.dart';

class const SettingsScreen({super.key}) extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(themeModeProvider);
    final prefs = ref.watch(prefsProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          _SectionTitle('外观'),
          // 三个选项直接摊开，比下拉菜单少一次点击，也一眼能看出当前选的是哪个。
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: SegmentedButton<ThemeMode>(
              segments: const [
                ButtonSegment(
                  value: ThemeMode.system,
                  icon: Icon(Icons.brightness_auto_outlined),
                  label: Text('跟随系统'),
                ),
                ButtonSegment(
                  value: ThemeMode.light,
                  icon: Icon(Icons.light_mode_outlined),
                  label: Text('浅色'),
                ),
                ButtonSegment(
                  value: ThemeMode.dark,
                  icon: Icon(Icons.dark_mode_outlined),
                  label: Text('深色'),
                ),
              ],
              selected: {mode},
              showSelectedIcon: false,
              onSelectionChanged: (picked) {
                ref.read(themeModeProvider.notifier).set(picked.first);
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              mode == ThemeMode.system
                  ? '跟随系统的深浅色设置自动切换'
                  : (mode == ThemeMode.dark ? '始终使用深色界面' : '始终使用浅色界面'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),

          const Divider(height: 24),
          _SectionTitle('短信'),
          SwitchListTile(
            value: prefs.translate,
            onChanged: (v) => ref.read(prefsProvider.notifier).setTranslate(v),
            secondary: const Icon(Icons.translate),
            title: const Text('实时翻译正文'),
            subtitle: const Text('把英文短信自动翻成中文，原文仍可查看'),
          ),
          SwitchListTile(
            value: prefs.showOriginal,
            onChanged: prefs.translate
                ? (v) => ref.read(prefsProvider.notifier).setShowOriginal(v)
                : null,
            secondary: const Icon(Icons.notes),
            title: const Text('译文下方保留原文'),
            subtitle: Text(prefs.translate ? '方便核对措辞，但每条会高一些' : '需先打开实时翻译'),
          ),

          const Divider(height: 24),
          _SectionTitle('关于'),
          const ListTile(
            leading: Icon(Icons.info_outline),
            title: Text('SMS 收件箱'),
            subtitle: Text('查看公共美国号码池的最新短信'),
          ),
          ListTile(
            leading: const Icon(Icons.cloud_outlined),
            title: const Text('数据来源'),
            subtitle: const Text('freeussms.com'),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Text(
              '号码目录直接抓取站点公开页面，不需要登录。'
              '短信正文由站点的浏览器会话拉取，所以会在后台启动一个隐藏的浏览器引擎。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 分组小标题。
class const _SectionTitle(this.text) extends StatelessWidget {
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
      child: Text(
        text,
        style: theme.textTheme.titleSmall?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
