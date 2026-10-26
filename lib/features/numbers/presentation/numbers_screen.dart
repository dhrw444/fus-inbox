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
      unawaited(_boot());
    });
  }

  /// 启动：先拉目录，目录到手后把还缺收录时间的号补齐。
  ///
  /// 只补缓存里没有的：已经有时间的号码直接跳过，不会重复请求。
  /// 首次启动会补一批（串行 + 间隔，不并发轰站点），之后就只剩新号。
  Future<void> _boot() async {
    final notifier = ref.read(numberDirectoryProvider.notifier);

    // 先读缓存：命中就立刻有列表可点，不用等网络。
    // （load() 内部也会读，但那是在它自己的 await 链里，
    //   这里先读一次是为了让「第一帧就有内容」尽早发生。）
    await notifier.hydrateFromCache();
    if (!mounted) return;

    // 缓存到位后立刻开始补收录时间，和网络刷新并行。
    //
    // 之前是 `await load()` 之后才补 —— 而 load 要跑完 5 页（约 2 秒，
    // 改之前是 10 秒），等于把补齐硬生生推迟到那之后。
    // 现在两件事同时跑：网络在后台拿新数据，补齐用的是缓存里已有的号，
    // 两者互不阻塞。
    unawaited(_fillFirstSeen());

    // 网络刷新放到最后，不 await。
    unawaited(notifier.load(force: true));
  }

  /// 补齐收录时间。已有缓存的不再请求。
  Future<void> _fillFirstSeen() async {
    final numbers = [
      for (final n in ref.read(numberDirectoryProvider).all) n.number,
    ];
    if (numbers.isEmpty) return;

    final store = ref.read(firstSeenStoreProvider.notifier);

    // 先对齐：只保留当前目录里还在的号。
    await store.retainOnly(numbers.toSet());
    if (!mounted) return;

    // 再补齐：缺的那些逐个抓，一条一条上屏。
    await ref.read(firstSeenFillerProvider).fillMissing(store, numbers);
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
    Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => InboxScreen(number: n)));
  }

  /// 复制号码到剪贴板，带 + 前缀（+14783902317）。
  ///
  /// 站点和模型里存的是纯数字，但用户拿去注册时要的是 E.164 形式。
  /// 不带 + 粘进输入框会被某些站点当成国内号码。
  Future<void> _copyNumber(AvailableNumber n) async {
    // 带 + 号：号码在模型里是纯数字（14783902317），
    // 但用户拿去注册时要的是 E.164 形式 +14783902317。
    await Clipboard.setData(ClipboardData(text: '+${n.number}'));
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
          // 缓存/刷新附注。只在有内容时显示一行，不占列表位置。
          if (dir.status.isNotEmpty && dir.all.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 2, 16, 6),
              child: Row(
                children: [
                  Icon(
                    Icons.bolt,
                    size: 13,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      dir.status,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          Expanded(child: _body(dir, items, saved, firstSeen, query, theme)),
        ],
      ),
    );
  }

  Widget _body(
    NumberDirectoryState dir,
    List<AvailableNumber> items,
    Set<String> saved,
    Map<String, DateTime> firstSeen,
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
      return _stateGrouped(items, saved, firstSeen, theme);
    }

    return RefreshIndicator(
      onRefresh: _refresh,
      // 卡片自带 8dp 外边距，列表不再画分隔线——两者一起用会出现
      // 「卡片 + 细线」的双重边界，看着很脏。
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 20),
        itemCount: items.length,
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
    Map<String, DateTime> firstSeen,
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
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 20),
        itemCount: keys.length,
        itemBuilder: (context, i) {
          final key = keys[i];
          final list = groups[key]!;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 州名标题：和设置页的分组标题同一套样式（主色 + 加粗，
              // 左边留一点缩进对齐卡片内文字），右边跟一个号码数。
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
                child: Row(
                  children: [
                    Text(
                      key,
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: theme.colorScheme.primary,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.3,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '${list.length} 个',
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
              const SizedBox(height: 8),
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
