/// 号码目录主界面。
///
/// 一屏解决「找一个能用的号」：顶部搜索框（号码 / 区号 / 州），
/// 下面筛选芯片 + 排序，再下面是号码卡片列表。
/// 数据来自原生 HTTP 抓取，这一页完全不碰 WebView。
library;

import 'dart:async';

import 'package:fus_inbox/features/inbox/presentation/inbox_screen.dart';
import 'package:fus_inbox/features/numbers/application/numbers_provider.dart';
import 'package:fus_inbox/features/numbers/domain/available_number.dart';
import 'package:fus_inbox/features/numbers/application/first_seen_store.dart';
import 'package:fus_inbox/features/numbers/presentation/widgets/directory_states.dart';
import 'package:fus_inbox/features/numbers/presentation/widgets/filter_bar.dart';
import 'package:fus_inbox/features/numbers/presentation/widgets/number_lists.dart';
import 'package:fus_inbox/features/numbers/presentation/widgets/numbers_app_bar.dart';
import 'package:fus_inbox/features/saved/application/saved_provider.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

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

  /// 页面即将从树里拿掉：停掉收录时间补齐。
  ///
  /// **必须放在 `deactivate` 而不是 `dispose`** —— `State.dispose` 阶段
  /// 已经不能再用 `ref`（Riverpod 会抛「ref used after dispose」），
  /// 我第一版就写在 `dispose` 里，那会让切走号码页时直接崩/卡住。
  ///
  /// `FirstSeenFiller.cancel()` 原来只被 `ref.onDispose` 调到，而
  /// `firstSeenFillerProvider` 是**全 App 一个** Provider、不随页面销毁 ——
  /// 于是注释写的「用户切走就停」从来没实现过：进号码页之后立刻点开
  /// 某个号，补齐任务会在后台继续打完整轮，和收件页叠在一起撞风控。
  @override
  void deactivate() {
    ref.read(firstSeenFillerProvider).cancel();
    super.deactivate();
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
  /// 模型里存的是纯数字，但用户拿去注册时要的是 E.164 形式；
  /// 不带 + 粘进输入框会被某些站点当成国内号码。
  Future<void> _copyNumber(AvailableNumber n) async {
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

    final items = dir.visibleFor(dir.tab, firstSeen: firstSeen);
    final query = dir.query.trim();

    return Scaffold(
      appBar: NumbersAppBar(
        searching: _searching,
        controller: _searchController,
        sort: dir.sort,
        loading: dir.loading,
        onQuery: notifier.setQuery,
        onOpenSearch: () => setState(() => _searching = true),
        onCloseSearch: () {
          _searchController.clear();
          notifier.clearQuery();
          setState(() => _searching = false);
        },
        onSort: notifier.setSort,
        onRefresh: _refresh,
      ),
      body: Column(
        children: [
          NumberFilterBar(
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

  /// 列表区：先判三种「没列表可看」的状态，再选布局。
  ///
  /// 判空和「加载中」的顺序不能换 —— 目录还在加载时 `all` 就是空的，
  /// 先判空会让用户看到「这个筛选下没有号码」，而事实上只是网络没回来。
  Widget _body(
    NumberDirectoryState dir,
    List<AvailableNumber> items,
    Set<String> saved,
    Map<String, DateTime> firstSeen,
    String query,
    ThemeData theme,
  ) {
    if (dir.error != null && dir.all.isEmpty) {
      return DirectoryError(
        message: dir.error!,
        theme: theme,
        onRetry: _refresh,
      );
    }
    if (dir.all.isEmpty && dir.loading) {
      return DirectoryLoading(progress: dir.progress, theme: theme);
    }
    if (items.isEmpty) {
      return DirectoryEmpty(query: query, theme: theme);
    }

    // 按州页用分组布局，其余用平铺。
    if (dir.tab == NumberTab.byState) {
      return StateGroupedNumberList(
        items: items,
        saved: saved,
        firstSeen: firstSeen,
        onRefresh: _refresh,
        onTap: _openInbox,
        onCopy: _copyNumber,
        onToggleSave: _toggleSave,
      );
    }

    return NumberList(
      items: items,
      saved: saved,
      firstSeen: firstSeen,
      onRefresh: _refresh,
      onTap: _openInbox,
      onCopy: _copyNumber,
      onToggleSave: _toggleSave,
    );
  }

  /// 收藏开关。列表那边只给 id，provider 怎么存不关它的事。
  void _toggleSave(String id) =>
      ref.read(savedNumbersProvider.notifier).toggle(id);
}
