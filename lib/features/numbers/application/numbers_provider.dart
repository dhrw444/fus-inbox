/// 号码目录状态。
///
/// 数据全部来自原生 HTTP 抓取（见 NumbersRepository），WebView 不参与。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fus_inbox/features/numbers/data/directory_cache.dart';
import 'package:fus_inbox/features/numbers/data/numbers_repository.dart';
import 'package:fus_inbox/features/numbers/domain/available_number.dart';

/// 目录页签（对应界面上可横向滚动的 TabBar）。
enum NumberTab(this.label) {
  all('全部'),
  fresh('最新活跃'),
  byState('按州');

  final String label;
}

/// 排序方式。
enum NumberSort(this.label) {
  recent('最近活跃'),
  firstSeen('收录时间'),
  messages('短信最多'),
  number('号码顺序');

  final String label;
}

final numbersRepositoryProvider = Provider<NumbersRepository>((ref) {
  final repo = NumbersRepository();
  ref.onDispose(repo.dispose);
  return repo;
});

class const NumberDirectoryState({
  this.all = const [],
  this.loading = false,
  this.error,
  this.tab = NumberTab.all,
  this.sort = NumberSort.recent,
  this.query = '',
  this.progress = '',
  this.status = '',
  this.lastLoadedAt,
}) {
  final List<AvailableNumber> all;
  final bool loading;
  final String? error;
  final NumberTab tab;
  final NumberSort sort;
  final String query;

  /// 加载中的进度文案，例如「已加载 48 个号（第 2 页）」。
  final String progress;

  /// 状态提示，例如「显示缓存（3 分钟前），正在取最新…」。
  ///
  /// 和 [error] 分开：error 会让界面显示成失败页，status 只是列表上方一行附注。
  final String status;

  final DateTime? lastLoadedAt;

  bool get isEmpty => all.isEmpty;

  /// 去重后的州列表（按州页签用）。
  List<String> get states {
    final set = <String>{};
    for (final n in all) {
      if (n.state.isNotEmpty) set.add(n.state);
    }
    final list = set.toList()..sort();
    return list;
  }

  /// 当前页签 + 搜索词 + 排序之后真正要显示的号码。
  ///
  /// [firstSeen] 只有 [NumberSort.firstSeen] 用得上，所以做成可选参数：
  /// 收录时间存在 FirstSeenStore 里（另一个 provider），不在这个 state 上。
  /// 不把它塞进 state 是有意的 —— 目录 state 不该反向依赖收录时间仓库，
  /// 而且收录时间会在「打开一个新号」时单独变化，塞进来就还要再维护一层
  /// 同步，容易变成两个真相。
  List<AvailableNumber> visibleFor(
    NumberTab tab, {
    Map<String, DateTime> firstSeen = const {},
  }) {
    Iterable<AvailableNumber> items = all;

    final q = query.trim().toLowerCase();
    if (q.isNotEmpty) {
      final digits = q.replaceAll(RegExp(r'[^\d]'), '');
      items = items.where((n) {
        // digits 为空时 contains('') 恒真，会把整库都放出来 —— 必须逐个守卫。
        if (digits.isNotEmpty) {
          if (n.number.contains(digits)) return true;
          if (n.areaCode.isNotEmpty && n.areaCode.contains(digits)) {
            return true;
          }
        }
        return n.state.toLowerCase().contains(q);
      });
    }

    if (tab == NumberTab.fresh) {
      items = items.where((n) => n.isFresh);
    }

    final list = items.toList();
    switch (sort) {
      case NumberSort.recent:
        list.sort((a, b) {
          final af = a.isFresh ? 0 : 1;
          final bf = b.isFresh ? 0 : 1;
          if (af != bf) return af - bf;
          final at = a.lastTextAt ?? '';
          final bt = b.lastTextAt ?? '';
          return bt.compareTo(at);
        });
      case NumberSort.firstSeen:
        // 新收录的在前。
        //
        // 从没收录过的（表里没记录）一律沉到最后，**不能当成 1970 年**：
        // 那样它们会永远卡在列表底部，而且 `?? 零点` 这类写法在
        // 升/降序切换时很容易反过来把空值顶到最前。
        //
        // 并列时按号码排一下，让结果稳定 —— List.sort 不保证稳定，
        // 只回 0 的话同一批并列项每次刷新顺序都可能变。
        list.sort((a, b) {
          final at = firstSeen[a.number];
          final bt = firstSeen[b.number];
          if (at == null && bt == null) return a.number.compareTo(b.number);
          if (at == null) return 1;
          if (bt == null) return -1;
          final byTime = bt.compareTo(at);
          return byTime != 0 ? byTime : a.number.compareTo(b.number);
        });
      case NumberSort.messages:
        list.sort((a, b) => b.messageCount.compareTo(a.messageCount));
      case NumberSort.number:
        list.sort((a, b) => a.number.compareTo(b.number));
    }
    return list;
  }

  /// 每个页签下有多少条，用于给页签加数字。
  int countFor(NumberTab tab) {
    switch (tab) {
      case NumberTab.all:
        return all.length;
      case NumberTab.fresh:
        return all.where((n) => n.isFresh).length;
      case NumberTab.byState:
        // 和其他 chip 一样显示「号码数」，不是「州数」。
        // 之前显示州数（20 个州），紧跟「全部 105」看着像对不上账。
        return all.length;
    }
  }

  NumberDirectoryState copyWith({
    List<AvailableNumber>? all,
    bool? loading,
    String? error,
    NumberTab? tab,
    NumberSort? sort,
    String? query,
    String? progress,
    String? status,
    DateTime? lastLoadedAt,
    bool clearError = false,
  }) {
    return NumberDirectoryState(
      all: all ?? this.all,
      loading: loading ?? this.loading,
      error: clearError ? null : (error ?? this.error),
      tab: tab ?? this.tab,
      sort: sort ?? this.sort,
      query: query ?? this.query,
      progress: progress ?? this.progress,
      status: status ?? this.status,
      lastLoadedAt: lastLoadedAt ?? this.lastLoadedAt,
    );
  }
}

class NumberDirectoryNotifier() extends Notifier<NumberDirectoryState> {
  @override
  NumberDirectoryState build() => const NumberDirectoryState();

  /// 只把磁盘缓存读进 state，不发任何网络请求。
  ///
  /// 拆出来是为了让启动顺序可控：先 hydrate（第一帧就有列表），
  /// 再并行跑 load 和收录时间补齐。之前塞在 load 内部，导致
  /// 补齐必须等 load 整个跑完才能开始。
  Future<void> hydrateFromCache() async {
    if (state.all.isNotEmpty) return;
    final cached = await loadDirectoryCache();
    if (cached == null || state.all.isNotEmpty) return;
    state = state.copyWith(
      all: cached.numbers,
      status: '显示缓存（${_ageLabel(cached.savedAt)}），正在取最新…',
    );
  }

  /// 拉取号码目录。
  ///
  /// 只在「已经在加载中」或「已有数据且非强制」时提前返回——
  /// 曾经加过 90 秒冷却期来省请求，那是把风控问题转嫁成限制用户。
  /// 用户点刷新是明确的意图，不该被 App 拦住；真遇到站点限流，
  /// 让请求失败并报出来，比假装按钮坏了要好。
  Future<void> load({bool force = false}) async {
    if (state.loading) return;
    if (!force && state.all.isNotEmpty) return;

    // 先上缓存（如果调用方还没 hydrate 过）。
    await hydrateFromCache();

    state = state.copyWith(
      loading: true,
      clearError: true,
      progress: '正在拉取号码目录…',
    );

    try {
      final repo = ref.read(numbersRepositoryProvider);
      final list = await repo.fetchAll(
        onProgress: (loaded, page) {
          state = state.copyWith(progress: '已加载 $loaded 个号（第 $page 页）');
        },
        // 每页先上屏：第一页通常 1 秒内回来，不必等 5 页全抓完。
        onPage: (soFar) {
          // 注意不能把 loading 置 false：fetchAll 还在跑，
          // 置 false 会让顶部的进度条中途消失，看着像加载完了又没完。
          state = state.copyWith(
            all: soFar,
            progress: '已加载 ${soFar.length} 个号，继续拉取中…',
          );
        },
      );
      if (list.isEmpty) {
        // 空结果不要覆盖缓存：站点偶尔返回空页，别把好数据洗掉。
        state = state.copyWith(
          loading: false,
          error: state.all.isEmpty ? '目录是空的——站点结构可能变了' : null,
          progress: '',
        );
        return;
      }
      state = state.copyWith(
        all: list,
        loading: false,
        progress: '',
        status: '',
        lastLoadedAt: DateTime.now(),
        clearError: true,
      );
      // 2) 写回缓存：下次启动就能秒开。
      unawaited(saveDirectoryCache(list));
      debugPrint('目录加载完成：${list.length} 个号，${state.states.length} 个州');
    } catch (e) {
      // 有缓存时不要把错误糊到界面上——用户看着列表能用，
      // 弹个「目录拉取失败」只会让人以为坏了。
      final msg = state.all.isEmpty ? '目录拉取失败：$e' : null;
      state = state.copyWith(
        loading: false,
        error: msg,
        progress: '',
        status: state.all.isEmpty ? '' : '最新数据没取到，先看缓存',
      );
    }
  }

  /// 「3 分钟前」这类相对时间，只用于缓存提示。
  static String _ageLabel(DateTime at) {
    final d = DateTime.now().difference(at);
    if (d.inMinutes < 1) return '刚刚';
    if (d.inMinutes < 60) return '${d.inMinutes} 分钟前';
    if (d.inHours < 24) return '${d.inHours} 小时前';
    return '${d.inDays} 天前';
  }

  /// 清缓存。设置页用。
  Future<void> clearCache() async {
    await clearDirectoryCache();
    state = state.copyWith(all: const [], status: '缓存已清除');
  }

  void setTab(NumberTab tab) => state = state.copyWith(tab: tab);
  void setSort(NumberSort sort) => state = state.copyWith(sort: sort);
  void setQuery(String q) => state = state.copyWith(query: q);
  void clearQuery() => state = state.copyWith(query: '');
}

final numberDirectoryProvider =
    NotifierProvider<NumberDirectoryNotifier, NumberDirectoryState>(
      NumberDirectoryNotifier.new,
    );
