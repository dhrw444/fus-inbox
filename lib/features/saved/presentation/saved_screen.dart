/// 收藏页：只看存下来的号。
library;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fus_inbox/features/inbox/presentation/inbox_screen.dart';
import 'package:fus_inbox/features/numbers/application/numbers_provider.dart';
import 'package:fus_inbox/features/numbers/domain/available_number.dart';
import 'package:fus_inbox/features/numbers/presentation/widgets/number_card.dart';
import 'package:fus_inbox/features/saved/application/saved_provider.dart';

class const SavedScreen({super.key}) extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final saved = ref.watch(savedNumbersProvider);
    final dir = ref.watch(numberDirectoryProvider);
    final theme = Theme.of(context);

    final items = dir.all.where((n) => saved.contains(n.id)).toList();

    if (items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.star_border,
                size: 40,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(height: 14),
              Text(
                saved.isEmpty
                    ? '还没收藏号码。\n在号码列表点右侧的星标就存下来了。'
                    : '收藏的号码不在当前目录里，刷新一下试试。',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return ListView.separated(
      itemCount: items.length,
      separatorBuilder: (context, i) => const Divider(height: 1, indent: 36),
      itemBuilder: (context, i) {
        final AvailableNumber n = items[i];
        return NumberCard(
          number: n,
          saved: true,
          onToggleSave: () =>
              ref.read(savedNumbersProvider.notifier).toggle(n.id),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => InboxScreen(number: n)),
          ),
        );
      },
    );
  }
}
