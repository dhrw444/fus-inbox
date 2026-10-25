/// 号码目录主界面。
///
/// 一屏解决「找一个能用的号」：顶部搜索框（号码 / 区号 / 州），
/// 下面筛选芯片 + 排序，再下面是号码卡片列表。
/// 数据来自原生 HTTP 抓取，这一页完全不碰 WebView。
library;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:freedium_mobile/features/inbox/presentation/inbox_screen.dart';
import 'package:freedium_mobile/features/numbers/application/numbers_provider.dart';
import 'package:freedium_mobile/features/numbers/domain/available_number.dart';
import 'package:freedium_mobile/features/numbers/presentation/widgets/number_card.dart';
import 'package:freedium_mobile/features/saved/application/saved_provider.dart';

class const NumbersScreen({super.key}) extends ConsumerStatefulWidget {
  @override
  ConsumerState<NumbersScreen> createState() => _NumbersScreenState();
}

class _NumbersScreenState() extends ConsumerState<NumbersScreen> {
  final _searchController = TextEditingController();
  bool _searching = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(numberDirectoryProvider.notifier).load();
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _openInbox(AvailableNumber n) {
    Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => InboxScreen(number: n)));
  }

  @override
  Widget build(BuildContext context) {
    final dir = ref.watch(numberDirectoryProvider);
    final notifier = ref.read(numberDirectoryProvider.notifier);
    final saved = ref.watch(savedNumbersProvider);
    final theme = Theme.of(context);

    final items = dir.visibleFor(dir.tab);
    final query = dir.query.trim();

    return Scaffold(
      appBar: AppBar(
        title: _searching
            ? TextField(
                controller: _searchController,
                autofocus: true,
                textInputAction: TextInputAction.search,
                keyboardType: TextInputType.text,
                decoration: const InputDecoration(
                  hintText: '号码 / 区号 / 州，例如 419、Ohio',
                  border: InputBorder.none,
                ),
                onChanged: notifier.setQuery,
              )
            : const Text('接码号码'),
        actions: [
          if (_searching)
            IconButton(
              tooltip: '关闭搜索',
              onPressed: () {
                _searchController.clear();
                notifier.clearQuery();
                setState(() => _searching = false);
              },
              icon: const Icon(Icons.close),
            )
          else ...[
            IconButton(
              tooltip: '搜索',
              onPressed: () => setState(() => _searching = true),
              icon: const Icon(Icons.search),
            ),
            PopupMenuButton<NumberSort>(
              tooltip: '排序',
              initialValue: dir.sort,
              onSelected: notifier.setSort,
              itemBuilder: (context) => [
                for (final s in NumberSort.values)
                  PopupMenuItem<NumberSort>(value: s, child: Text(s.label)),
              ],
              icon: const Icon(Icons.sort),
            ),
            IconButton(
              tooltip: '刷新目录',
              onPressed: dir.loading ? null : () => notifier.load(force: true),
              icon: const Icon(Icons.refresh),
            ),
          ],
        ],
      ),
      body: Column(
        children: [
          _FilterBar(
            dir: dir,
            onTab: notifier.setTab,
            onClearQuery: () {
              _searchController.clear();
              notifier.clearQuery();
            },
          ),
          if (dir.loading)
            LinearProgressIndicator(minHeight: 2, semanticsLabel: dir.progress),
          Expanded(child: _body(dir, items, saved, query, theme)),
        ],
      ),
    );
  }

  Widget _body(
    NumberDirectoryState dir,
    List<AvailableNumber> items,
    Set<String> saved,
    String query,
    ThemeData theme,
  ) {
    if (dir.error != null && dir.all.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.cloud_off,
                size: 40,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(height: 14),
              Text(dir.error!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton.tonal(
                onPressed: () => ref
                    .read(numberDirectoryProvider.notifier)
                    .load(force: true),
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }

    if (dir.all.isEmpty && dir.loading) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(
              dir.progress.isEmpty ? '正在拉取号码目录…' : dir.progress,
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      );
    }

    if (items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Text(
            query.isEmpty ? '这个筛选下没有号码。' : '没有匹配「$query」的号码。',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      );
    }

    if (dir.tab == NumberTab.byState) {
      return _stateGrouped(items, saved, theme);
    }

    return RefreshIndicator(
      onRefresh: () =>
          ref.read(numberDirectoryProvider.notifier).load(force: true),
      child: ListView.separated(
        itemCount: items.length,
        separatorBuilder: (context, i) => const Divider(height: 1, indent: 36),
        itemBuilder: (context, i) => NumberCard(
          number: items[i],
          saved: saved.contains(items[i].id),
          onTap: () => _openInbox(items[i]),
          onToggleSave: () =>
              ref.read(savedNumbersProvider.notifier).toggle(items[i].id),
        ),
      ),
    );
  }

  /// 按州分组：州名做小标题，方便按地区挑号。
  Widget _stateGrouped(
    List<AvailableNumber> items,
    Set<String> saved,
    ThemeData theme,
  ) {
    final groups = <String, List<AvailableNumber>>{};
    for (final n in items) {
      final key = n.state.isEmpty ? '其他' : n.state;
      groups.putIfAbsent(key, () => []).add(n);
    }
    final keys = groups.keys.toList()..sort();

    return RefreshIndicator(
      onRefresh: () =>
          ref.read(numberDirectoryProvider.notifier).load(force: true),
      child: ListView.builder(
        itemCount: keys.length,
        itemBuilder: (context, i) {
          final key = keys[i];
          final list = groups[key]!;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
                child: Row(
                  children: [
                    Text(
                      key,
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: theme.colorScheme.primary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '${list.length}',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              for (final n in list)
                NumberCard(
                  number: n,
                  saved: saved.contains(n.id),
                  onTap: () => _openInbox(n),
                  onToggleSave: () =>
                      ref.read(savedNumbersProvider.notifier).toggle(n.id),
                ),
              const Divider(height: 1),
            ],
          );
        },
      ),
    );
  }
}

/// 筛选芯片行。
class const _FilterBar({
  required this.dir,
  required this.onTab,
  required this.onClearQuery,
}) extends StatelessWidget {
  final NumberDirectoryState dir;
  final void Function(NumberTab) onTab;
  final VoidCallback onClearQuery;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 52,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: [
          for (final t in NumberTab.values) ...[
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: FilterChip(
                selected: dir.tab == t,
                onSelected: (_) => onTab(t),
                showCheckmark: false,
                label: Text('${t.label} ${dir.countFor(t)}'),
              ),
            ),
            const SizedBox(width: 8),
          ],
          if (dir.query.trim().isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: ActionChip(
                avatar: const Icon(Icons.close, size: 16),
                label: Text('清除「${dir.query.trim()}」'),
                onPressed: onClearQuery,
              ),
            ),
        ],
      ),
    );
  }
}
