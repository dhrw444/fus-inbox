import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fus_inbox/core/prefs/prefs_provider.dart';
import 'package:fus_inbox/core/theme/theme_provider.dart';
import 'package:fus_inbox/core/translate/translation_provider.dart';

/// 设置页。
///
/// 分组方式照 freedium 原项目的设置页：小标题 + 列表项，一组组往下排。
/// 只保留对短信 App 有意义的项——原项目的镜像源、弹窗拦截都是阅读器专用，
/// 搬过来只会让人困惑。
class const SettingsScreen({super.key}) extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prefs = ref.watch(prefsProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('设置'), centerTitle: false),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          const _SectionHeader('外观'),
          _ThemeModeTile(prefs: prefs),
          _FontSizeTile(prefs: prefs),
          const Divider(height: 24),

          const _SectionHeader('短信'),
          SwitchListTile(
            title: const Text('实时翻译'),
            subtitle: const Text('把英文短信自动翻成中文，译文显示在原文位置'),
            value: prefs.translate,
            onChanged: (v) => ref.read(prefsProvider.notifier).setTranslate(v),
          ),
          SwitchListTile(
            title: const Text('译文下方保留原文'),
            subtitle: const Text('打开后卡片会更高，但能对照原文'),
            value: prefs.showOriginal,
            onChanged: prefs.translate
                ? (v) => ref.read(prefsProvider.notifier).setShowOriginal(v)
                : null,
          ),
          _LanguageTile(prefs: prefs),
          const Divider(height: 24),

          const _SectionHeader('存储'),
          ListTile(
            leading: const Icon(Icons.cleaning_services_outlined),
            title: const Text('清除翻译缓存'),
            subtitle: Text(
              '已缓存 ${ref.watch(translationStoreProvider).length} 条译文',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _clearTranslationCache(context, ref),
          ),
          const Divider(height: 24),

          const _SectionHeader('关于'),
          const ListTile(
            leading: Icon(Icons.info_outline),
            title: Text('数据来源'),
            subtitle: Text('freeussms.com 的公开号码与短信'),
          ),
          const ListTile(
            leading: Icon(Icons.code),
            title: Text('架构'),
            subtitle: Text('原生 HTTP 抓号码目录，WebView 只做后台取数引擎'),
          ),
          const ListTile(
            leading: Icon(Icons.description_outlined),
            title: Text('许可'),
            subtitle: Text('MIT'),
          ),
          const SizedBox(height: 12),
          Center(
            child: Text(
              'v0.1.0',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _clearTranslationCache(
    BuildContext context,
    WidgetRef ref,
  ) async {
    final n = ref.read(translationStoreProvider).length;
    ref.read(translationStoreProvider.notifier).clear();
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text('已清除 $n 条翻译缓存')));
  }
}

/// 分组小标题。缩进和列表项文字对齐，字号比正文小一号。
class const _SectionHeader({required this.title}) extends StatelessWidget {
  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 6),
      child: Text(
        title,
        style: theme.textTheme.labelMedium?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}

/// 主题模式：跟随系统 / 浅色 / 深色。
///
/// 用 SegmentedButton 而不是下拉框：只有三个选项，摊开比点两次更快。
class const _ThemeModeTile({required this.prefs}) extends ConsumerWidget {
  final Prefs prefs;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('主题'),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<ThemeMode>(
              segments: const [
                ButtonSegment(
                  value: ThemeMode.system,
                  label: Text('跟随系统'),
                  icon: Icon(Icons.brightness_auto, size: 18),
                ),
                ButtonSegment(
                  value: ThemeMode.light,
                  label: Text('浅色'),
                  icon: Icon(Icons.light_mode, size: 18),
                ),
                ButtonSegment(
                  value: ThemeMode.dark,
                  label: Text('深色'),
                  icon: Icon(Icons.dark_mode, size: 18),
                ),
              ],
              selected: {ref.watch(themeModeProvider)},
              onSelectionChanged: (picked) {
                ref.read(themeModeProvider.notifier).set(picked.first);
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// 字号：四档，0.85 ~ 1.30 倍。
///
/// 不用连续滑块——短信正文的阅读舒适区很窄，给固定几档比让用户拖更实际。
class const _FontSizeTile({required this.prefs}) extends ConsumerWidget {
  final Prefs prefs;

  /// 档位倍率。
  static const steps = <double>[0.85, 1.0, 1.15, 1.30];

  /// 与 [steps] 一一对应的档名。
  static const labels = <String>['小', '标准', '大', '特大'];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);

    // 把当前缩放吸附到最近的档位，避免老数据落在两档之间。
    var idx = 1;
    var best = 9.9;
    for (var i = 0; i < steps.length; i++) {
      final d = (steps[i] - prefs.fontScale).abs();
      if (d < best) {
        best = d;
        idx = i;
      }
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text('短信字号'),
              const Spacer(),
              Text(
                '${(steps[idx] * 100).round()}%',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          // 实时预览：改档位立刻能看到效果，不用切回去看短信。
          Text(
            '验证码 123456',
            style: theme.textTheme.bodyMedium?.copyWith(
              fontSize: 15 * steps[idx],
            ),
          ),
          Slider(
            value: idx.toDouble(),
            max: (steps.length - 1).toDouble(),
            divisions: steps.length - 1,
            label: labels[idx],
            onChanged: (v) {
              ref.read(prefsProvider.notifier).setFontScale(steps[v.round()]);
            },
          ),
        ],
      ),
    );
  }
}

/// 翻译目标语言。
///
/// 只给两个：简体中文是默认，繁体给习惯繁体的人。再加英文会变成
/// 「把英文翻成英文」，没有意义。
class const _LanguageTile({required this.prefs}) extends ConsumerWidget {
  final Prefs prefs;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListTile(
      leading: const Icon(Icons.translate),
      title: const Text('翻译成'),
      trailing: DropdownButton<String>(
        value: prefs.targetLang,
        underline: const SizedBox.shrink(),
        items: const [
          DropdownMenuItem(value: 'zh-CN', child: Text('简体中文')),
          DropdownMenuItem(value: 'zh-TW', child: Text('繁體中文')),
        ],
        onChanged: (v) {
          if (v == null) return;
          ref.read(prefsProvider.notifier).setTargetLang(v);
        },
      ),
    );
  }
}
