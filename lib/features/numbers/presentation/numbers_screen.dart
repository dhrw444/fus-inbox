/// 号码目录主界面。
///
/// 一屏解决「找一个能用的号」：顶部搜索框（号码 / 区号 / 州），
/// 下面筛选芯片 + 排序，再下面是号码卡片列表。
/// 数据来自原生 HTTP 抓取，这一页完全不碰 WebView。
library;

import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fus_inbox/features/inbox/presentation/inbox_screen.dart';
import 'package:fus_inbox/features/numbers/application/numbers_provider.dart';
import 'package:fus_inbox/features/numbers/domain/available_number.dart';
import 'package:fus_inbox/features/numbers/domain/first_seen.dart';
import 'package:fus_inbox/features/numbers/domain/state_names.dart';
import 'package:fus_inbox/features/numbers/presentation/widgets/number_card.dart';
import 'package:fus_inbox/features/saved/application/saved_provider.dart';

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

  /// 下拉刷新 / 点刷新键的统一入口。
  ///
  /// `load` 只在「已经在加载中」时返回 false。那个情况下不该弹提示——
  /// 界面上本来就有进度条在转，再弹一条纯属噪音。
  Future<void> _refresh() async {
    await ref.read(numberDirectoryProvider.notifier).load(force: true);
  }

  void _openInbox(AvailableNumber n) {
    // 顺手抓一次这个号的收录时间。
    //
    // 站点只把这个字段放在详情页，列表页没有，所以只能按需抓、抓完缓存。
    // 放在这里而不是 build 里，是因为打开收件箱意味着用户对这个号感兴趣，
    // 一次额外请求是值得的；而在列表上预抓百来个号就是风控源头。
    unawaited(_learnFirstSeen(n.number));
    Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => InboxScreen(number: n)));
  }

  /// 抓收录时间并写进缓存。已有缓存就直接跳过。
  Future<void> _learnFirstSeen(String number) async {
    final store = ref.read(firstSeenStoreProvider.notifier);
    if (store.has(number)) return;
    final at = await fetchFirstSeen(number);
    if (at == null || !mounted) return;
    await store.put(number, at);
  }

  /// 复制号码到剪贴板。给的是 E.164 纯数字，方便直接粘进注册框。
  Future<void> _copyNumber(AvailableNumber n) async {
    await Clipboard.setData(ClipboardData(text: n.number));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text('已复制 ${n.pretty}'),
          duration: const Duration(milliseconds: 1200),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final dir = ref.watch(numberDirectoryProvider);
    final notifier = ref.read(numberDirectoryProvider.notifier);
    final saved = ref.watch(savedNumbersProvider);
    // 收录时间缓存。抓到一个号就会刷新一次，列表里那条随即带上时间。
    final firstSeen = ref.watch(firstSeenStoreProvider);
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
              onPressed: dir.loading ? null : _refresh,
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
              FilledButton.tonal(onPressed: _refresh, child: const Text('重试')),
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
      onRefresh: _refresh,
      child: ListView.separated(
        itemCount: items.length,
        separatorBuilder: (context, i) => const Divider(height: 1, indent: 36),
        itemBuilder: (context, i) => NumberCard(
          number: items[i],
          saved: saved.contains(items[i].id),
          firstSeen: firstSeen[items[i].number],
          onTap: () => _openInbox(items[i]),
          onCopy: () => _copyNumber(items[i]),
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
      // 分组标题直接用中文州名，否则「按州」页里全是 Georgia / Florida。
      final zh = stateZh(n.state);
      final key = zh.isEmpty ? '其他' : zh;
      groups.putIfAbsent(key, () => []).add(n);
    }
    final keys = groups.keys.toList()..sort();

    return RefreshIndicator(
      onRefresh: _refresh,
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
                  firstSeen: firstSeen[n.number],
                  onTap: () => _openInbox(n),
                  onCopy: () => _copyNumber(n),
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
    // 用 Wrap 而不是横向 ListView：固定高度 + 横向滚动在窄屏或大字号下
    // 会把最后一个 chip 切掉一半，而且没有任何「还能滑」的提示。
    // Wrap 会在放不下时自动换行，永远不会切。
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      child: Wrap(
        spacing: 8,
        runSpacing: 2,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          for (final t in NumberTab.values)
            FilterChip(
              selected: dir.tab == t,
              onSelected: (_) => onTab(t),
              showCheckmark: false,
              label: Text('${t.label} ${dir.countFor(t)}'),
            ),
          if (dir.query.trim().isNotEmpty)
            ActionChip(
              avatar: const Icon(Icons.close, size: 16),
              label: Text('清除「${dir.query.trim()}」'),
              onPressed: onClearQuery,
            ),
        ],
      ),
    );
  }
}
