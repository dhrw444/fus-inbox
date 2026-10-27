import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fus_inbox/core/constants/app_constants.dart';
import 'package:fus_inbox/core/prefs/prefs_provider.dart';
import 'package:fus_inbox/core/theme/theme_provider.dart';
import 'package:fus_inbox/core/translate/translation_provider.dart';
import 'package:fus_inbox/core/proxy/proxy_provider.dart';
import 'package:fus_inbox/features/numbers/application/numbers_provider.dart';

/// 设置页。
///
/// 视觉语言参考 Yomiru：分组标题外面不加框，每个分组包一张
/// elevation:0 + 16dp 圆角的卡片，卡内条目去掉逐条分隔线，靠留白分层。
/// 之前是裸 ListTile + Divider，和系统设置页长得一样，没有辨识度。
class const SettingsScreen({super.key}) extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prefs = ref.watch(prefsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('设置'), centerTitle: false),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 36),
        children: [
          const _GroupLabel(text: '外观'),
          _GroupCard(
            children: [
              const _ThemeModeRow(),
              const Divider(height: 1, indent: 16, endIndent: 16),
              _FontSizeRow(prefs: prefs),
            ],
          ),

          const _GroupLabel(text: '短信'),
          _GroupCard(
            children: [
              SwitchListTile(
                title: const Text('实时翻译'),
                subtitle: const Text('英文短信自动翻成中文'),
                value: prefs.translate,
                onChanged: (v) =>
                    ref.read(prefsProvider.notifier).setTranslate(v),
              ),
              const Divider(height: 1, indent: 16, endIndent: 16),
              SwitchListTile(
                title: const Text('保留原文'),
                subtitle: Text(prefs.translate ? '译文下方同时显示英文原文' : '需先打开实时翻译'),
                value: prefs.showOriginal,
                onChanged: prefs.translate
                    ? (v) => ref.read(prefsProvider.notifier).setShowOriginal(v)
                    : null,
              ),
              const Divider(height: 1, indent: 16, endIndent: 16),
              _LanguageRow(prefs: prefs),
            ],
          ),

          const _GroupLabel(text: '代理'),
          const _GroupCard(children: [_ProxySection()]),

          const _GroupLabel(text: '存储'),
          _GroupCard(
            children: [
              ListTile(
                leading: const Icon(Icons.translate),
                title: const Text('翻译缓存'),
                subtitle: Text(
                  '${ref.watch(translationStoreProvider).length} 条译文',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _clearTranslationCache(context, ref),
              ),
              const Divider(height: 1, indent: 16, endIndent: 16),
              ListTile(
                leading: const Icon(Icons.storage_outlined),
                title: const Text('号码目录缓存'),
                subtitle: Text(
                  ref.watch(numberDirectoryProvider).all.isEmpty
                      ? '暂无缓存'
                      : '${ref.watch(numberDirectoryProvider).all.length} 个号码',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _clearDirectoryCache(context, ref),
              ),
            ],
          ),

          const _GroupLabel(text: '关于'),
          _GroupCard(
            children: [
              const ListTile(
                leading: Icon(Icons.cloud_outlined),
                title: Text('数据来源'),
                subtitle: Text('freeussms.com'),
              ),
              const Divider(height: 1, indent: 16, endIndent: 16),
              const ListTile(
                leading: Icon(Icons.description_outlined),
                title: Text('许可'),
                subtitle: Text('MIT'),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Center(
            child: Text(
              'v${AppConstants.appVersion}',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _clearDirectoryCache(BuildContext context, WidgetRef ref) async {
    final n = ref.read(numberDirectoryProvider).all.length;
    await ref.read(numberDirectoryProvider.notifier).clearCache();
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text('已清除 $n 个号码的目录缓存')));
  }

  void _clearTranslationCache(BuildContext context, WidgetRef ref) {
    final n = ref.read(translationStoreProvider).length;
    ref.read(translationStoreProvider.notifier).clear();
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text('已清除 $n 条翻译缓存')));
  }
}

/// 分组标题。放在卡片外面，缩进对齐卡片内文字。
class const _GroupLabel({required this.text}) extends StatelessWidget {
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
      child: Text(
        text,
        style: theme.textTheme.labelLarge?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.3,
        ),
      ),
    );
  }
}

/// 分组卡片：无阴影、16dp 圆角、淡色底。
class const _GroupCard({required this.children}) extends StatelessWidget {
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      clipBehavior: Clip.antiAlias,
      child: Column(mainAxisSize: MainAxisSize.min, children: children),
    );
  }
}

/// 主题三选一。
class const _ThemeModeRow() extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('主题', style: theme.textTheme.titleSmall),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<ThemeMode>(
              // 三个选项挤在 1080 宽里，「跟随系统」+ 图标会被压成两行。
              // 去掉图标只留文字，并锁死单行。
              segments: const [
                ButtonSegment(
                  value: ThemeMode.system,
                  label: Text('跟随系统', maxLines: 1),
                ),
                ButtonSegment(
                  value: ThemeMode.light,
                  label: Text('浅色', maxLines: 1),
                ),
                ButtonSegment(
                  value: ThemeMode.dark,
                  label: Text('深色', maxLines: 1),
                ),
              ],
              selected: {ref.watch(themeModeProvider)},
              showSelectedIcon: false,
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

/// 字号四档 + 实时预览。
class const _FontSizeRow({required this.prefs}) extends ConsumerWidget {
  final Prefs prefs;

  static const steps = <double>[0.85, 1.0, 1.15, 1.30];
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
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('短信字号', style: theme.textTheme.titleSmall),
              const Spacer(),
              Text(
                '${(steps[idx] * 100).round()}%',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          // 实时预览：改档位立刻看到效果，不用切回短信页。
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: theme.colorScheme.surface,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              'Your code is 123456',
              style: theme.textTheme.bodyMedium?.copyWith(
                fontSize: 14 * steps[idx],
              ),
            ),
          ),
          Slider(
            value: idx.toDouble(),
            max: (steps.length - 1).toDouble(),
            divisions: steps.length - 1,
            label: labels[idx],
            // 拖动中只改内存（实时预览字号），松手才落盘。
            onChanged: (v) {
              ref
                  .read(prefsProvider.notifier)
                  .setFontScale(steps[v.round()], persist: false);
            },
            onChangeEnd: (v) {
              ref.read(prefsProvider.notifier).setFontScale(steps[v.round()]);
            },
          ),
        ],
      ),
    );
  }
}

/// 翻译目标语言。
class const _LanguageRow({required this.prefs}) extends ConsumerWidget {
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
          DropdownMenuItem(value: 'zh-CN', child: Text('简体')),
          DropdownMenuItem(value: 'zh-TW', child: Text('繁體')),
        ],
        onChanged: (v) {
          if (v == null) return;
          ref.read(prefsProvider.notifier).setTargetLang(v);
        },
      ),
    );
  }
}
