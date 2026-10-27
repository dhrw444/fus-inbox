/// 收藏页：只看存下来的号。
///
/// 视觉和号码列表一致：卡片式、12dp 侧边距、8dp 卡片间距。
library;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fus_inbox/features/inbox/presentation/inbox_screen.dart';
import 'package:fus_inbox/features/numbers/application/numbers_provider.dart';
import 'package:fus_inbox/features/numbers/domain/first_seen.dart';
import 'package:fus_inbox/features/numbers/presentation/widgets/number_card.dart';
import 'package:fus_inbox/features/saved/application/saved_provider.dart';

class const SavedScreen({super.key}) extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final saved = ref.watch(savedNumbersProvider);
    final dir = ref.watch(numberDirectoryProvider);
    final firstSeen = ref.watch(firstSeenStoreProvider);
    final theme = Theme.of(context);

    final items = dir.all.where((n) => saved.contains(n.id)).toList();

    // 目录还在加载时 all 就是空的。这一支必须先判 —— 否则用户看到的是
    // 「收藏的号码不在当前目录里」，读起来就是「我的收藏丢了」，
    // 而事实上只是网络还没回来。
    if (items.isEmpty && dir.loading) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(height: 16),
              Text(
                dir.status.isEmpty ? '正在取号码目录…' : dir.status,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (items.isEmpty) {
      // 「下拉刷新一下试试」以前是句空话：这个文件里没有任何
      // RefreshIndicator，用户照着做只会以为是自己手势不对。
      // 现在这句话真能照做了。
      //
      // 要套 LayoutBuilder + ConstrainedBox 是因为空态内容撑不满一屏，
      // 没有这条 ListView 就滚不动，RefreshIndicator 也就触发不了。
      return RefreshIndicator(
        onRefresh: () =>
            ref.read(numberDirectoryProvider.notifier).load(force: true),
        child: LayoutBuilder(
          builder: (context, constraints) => ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            children: [
              ConstrainedBox(
                constraints: BoxConstraints(minHeight: constraints.maxHeight),
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 64,
                          height: 64,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: theme.colorScheme.surfaceContainerHighest
                                .withValues(alpha: 0.6),
                          ),
                          child: Icon(
                            Icons.star_border_rounded,
                            size: 30,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 18),
                        Text(
                          saved.isEmpty ? '还没有收藏的号码' : '收藏的号码不在当前目录里',
                          style: theme.textTheme.titleSmall,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          saved.isEmpty ? '在号码列表点右侧的星标就存下来了' : '下拉刷新一下试试',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 20),
      itemCount: items.length,
      itemBuilder: (context, i) {
        final n = items[i];
        return NumberCard(
          number: n,
          saved: true,
          firstSeen: firstSeen[n.number],
          onToggleSave: () =>
              ref.read(savedNumbersProvider.notifier).toggle(n.id),
          onCopy: () async {
            // 带 + 前缀，和号码列表的复制行为保持一致。
            await Clipboard.setData(ClipboardData(text: '+${n.number}'));
            if (!context.mounted) return;
            ScaffoldMessenger.of(context)
              ..clearSnackBars()
              ..showSnackBar(
                SnackBar(
                  content: Text('已复制 ${n.pretty}'),
                  duration: const Duration(milliseconds: 1200),
                ),
              );
          },
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => InboxScreen(number: n)),
          ),
        );
      },
    );
  }
}
