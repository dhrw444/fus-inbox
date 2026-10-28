/// 设置页「存储」分组：清翻译缓存、清号码目录缓存。
///
/// 两个条目长得像「进二级页」，实际是**会真删东西**的动作，所以都用
/// 删除图标 + error 色，和本页其余可点项一眼分得开；动作本身也留在
/// 这个文件里，不散回屏幕。
library;

import 'package:fus_inbox/features/settings/presentation/widgets/destructive_confirm.dart';
import 'package:fus_inbox/core/translate/translation_provider.dart';
import 'package:fus_inbox/features/numbers/application/numbers_provider.dart';
import 'package:fus_inbox/features/settings/presentation/widgets/settings_group.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

/// 存储分组：两个「点了就删」的条目，删前各带当前条数。
class const StorageSection({super.key}) extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final dir = ref.watch(numberDirectoryProvider);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SettingsGroupLabel(text: '存储'),
        SettingsGroupCard(
          children: [
            ListTile(
              leading: const Icon(Icons.translate),
              title: const Text('翻译缓存'),
              subtitle: Text(
                '${ref.watch(translationStoreProvider).length} 条译文',
              ),
              // 这里以前是 chevron_right —— 那个图标的意思是「点进去还有
              // 一页」，实际却是点一下就清空，没有二级页。换成删除图标，
              // 并上 error 色：本页其余可点项都是进二级页，只有这两处是
              // 会真的删东西的动作，外观上必须能一眼区分。
              trailing: Icon(Icons.delete_outline, color: scheme.error),
              onTap: () => _clearTranslationCache(context, ref),
            ),
            const Divider(height: 1, indent: 16, endIndent: 16),
            ListTile(
              leading: const Icon(Icons.storage_outlined),
              title: const Text('号码目录缓存'),
              // watch 整个 state 一次，别在同一个 build 里 watch 两遍。
              subtitle: Text(
                dir.all.isEmpty ? '暂无缓存' : '${dir.all.length} 个号码',
              ),
              trailing: Icon(Icons.delete_outline, color: scheme.error),
              onTap: () => _clearDirectoryCache(context, ref),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _clearDirectoryCache(BuildContext context, WidgetRef ref) async {
    final n = ref.read(numberDirectoryProvider).all.length;
    if (n == 0) return;
    final yes = await confirmDestructive(
      context,
      title: '清空号码目录缓存？',
      message:
          '下次进号码页要重新从站点拉一遍目录（$n 个号），'
          '拉的时候会慢一些。',
      confirmLabel: '清空',
    );
    if (!yes || !context.mounted) return;
    await ref.read(numberDirectoryProvider.notifier).clearCache();
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text('已清除 $n 个号码的目录缓存')));
  }

  Future<void> _clearTranslationCache(
    BuildContext context,
    WidgetRef ref,
  ) async {
    final n = ref.read(translationStoreProvider).length;
    if (n == 0) return;
    final yes = await confirmDestructive(
      context,
      title: '清空翻译缓存？',
      message: '已翻好的 $n 条译文会被丢掉，再打开那些短信时要重新翻译一遍。',
      confirmLabel: '清空',
    );
    // await 回来之后 context 可能已经失效（用户切走了）。
    // 不加这个守卫 analyzer 会报 use_build_context_synchronously，
    // 而且下面 `ScaffoldMessenger.of(context)` 在失效 context 上确实会炸。
    if (!yes || !context.mounted) return;
    ref.read(translationStoreProvider.notifier).clear();
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text('已清除 $n 条翻译缓存')));
  }
}
