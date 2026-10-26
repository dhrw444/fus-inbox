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

    if (items.isEmpty) {
      return Center(
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
                  color: theme.colorScheme.surfaceContainerHighest.withValues(
                    alpha: 0.6,
                  ),
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
            await Clipboard.setData(ClipboardData(text: n.number));
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
