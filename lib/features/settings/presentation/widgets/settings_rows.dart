/// 设置页的四个内容行：主题、字号、翻译引擎、目标语言。
///
/// 每行都是「读偏好 + 写偏好」，不持有任何本地状态 —— 这也是它们能
/// 排成一列的原因。混进 `settings_screen` 会让那个文件一半是编排、
/// 一半是具体控件。
library;

import 'package:fus_inbox/core/prefs/prefs_provider.dart';
import 'package:fus_inbox/core/theme/theme_provider.dart';
import 'package:fus_inbox/core/translate/translator.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

/// 主题三选一：跟随系统 / 浅色 / 深色。
class const ThemeModeRow({super.key}) extends ConsumerWidget {
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
              // 三个选项挤在窄屏里，「跟随系统」+ 图标会被压成两行。
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
class const FontSizeRow({required this.prefs, super.key})
    extends ConsumerWidget {
  final Prefs prefs;

  static const steps = <double>[0.85, 1.0, 1.15, 1.30];
  static const labels = <String>['小', '标准', '大', '特大'];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);

    // 把当前缩放吸附到最近的档位，避免老数据落在两档之间。
    var idx = 1;
    var best = double.infinity;
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

/// 翻译引擎。
///
/// 这里选的是「首选」，不是「唯一」：选中那家连不上时会自动换下一家，
/// 所以文案写「优先」而不是「使用」。默认微软：谷歌在国内网络基本
/// 连不通，而首选不通时第一条短信要白等满超时。
class const EngineRow({required this.prefs, super.key}) extends ConsumerWidget {
  final Prefs prefs;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListTile(
      leading: const Icon(Icons.cloud_outlined),
      title: const Text('翻译引擎'),
      subtitle: const Text('首选引擎；连不上会自动换另一家'),
      trailing: DropdownButton<TranslateEngine>(
        value: prefs.engine,
        underline: const SizedBox.shrink(),
        items: [
          for (final e in TranslateEngine.values)
            DropdownMenuItem(value: e, child: Text(e.label)),
        ],
        onChanged: (v) {
          if (v == null) return;
          ref.read(prefsProvider.notifier).setEngine(v);
        },
      ),
    );
  }
}

/// 翻译目标语言。
class const LanguageRow({required this.prefs, super.key})
    extends ConsumerWidget {
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
