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
  List<AvailableNumber> visibleFor(NumberTab tab) {
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

  /// 两次全量抓取之间的最短间隔。
  ///
  /// 拉取号码目录。
  ///
  /// 只在「已经在加载中」或「已有数据且非强制」时提前返回——
  /// 曾经加过 90 秒冷却期来省请求，那是把风控问题转嫁成限制用户。
  /// 用户点刷新是明确的意图，不该被 App 拦住；真遇到站点限流，
  /// 让请求失败并报出来，比假装按钮坏了要好。
  ///
  /// [force] 为 true 时无视「已有数据」，但仍然复用缓存做即时显示。
  Future<void> load({bool force = false}) async {
    if (state.loading) return;
    if (!force && state.all.isNotEmpty) return;

    // 1) 先上缓存：冷启动时不必干等网络。缓存只负责「立刻有东西看」，
    //    后面照常去站点取最新，不替代刷新。
    if (state.all.isEmpty) {
      final cached = await loadDirectoryCache();
      // 注意：Notifier 没有 mounted 概念（那是 State 的）。
      // 用它编译不过；这里也不需要——真要有并发，下面的 loading 重入
      // 检查已经挡住第二次 load 了。
      if (cached != null && state.all.isEmpty) {
        state = state.copyWith(
          all: cached.numbers,
          // 缓存命中时不算「加载中」，否则还会盖一层转圈。
          // 用一条状态文案告诉用户手上是旧数据。
          status: '显示缓存（${_ageLabel(cached.savedAt)}），正在取最新…',
        );
      }
    }

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
          state = state.copyWith(
            all: soFar,
            loading: false,
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
