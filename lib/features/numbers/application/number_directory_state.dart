/// 目录页的**值状态**：一次加载的全部可见字段，加上「哪些号该显示」的纯逻辑。
///
/// ## 为什么从 `numbers_provider.dart` 拆出来
///
/// 和 `proxy_state.dart` 那次同因：不可变值类 + 派生 getter，逻辑只有
/// 筛选、计数、`copyWith`，而 notifier 那边装的是网络、缓存、出口。
/// 挤在一起时改 `copyWith` 要翻过一百多行加载流程。
///
/// 拆出来还有一个实际好处：**这里不 import flutter_riverpod**，
/// 于是 `visibleFor` 的筛选规则（搜索词怎么匹配号码 / 区号 / 州名）
/// 能在纯 Dart 环境下跑，和 `domain/number_sort.dart` 一样。
///
/// 排序规则在 `domain/number_sort.dart`，本文件只负责「筛出哪些、按什么
/// 排序、显示多少」这三步里前两步。
library;

import 'package:fus_inbox/features/numbers/domain/available_number.dart';
import 'package:fus_inbox/features/numbers/domain/number_sort.dart';

/// 目录页签（对应界面上可横向滚动的 TabBar）。
enum NumberTab(this.label) {
  all('全部'),
  fresh('最新活跃'),
  byState('按州');

  final String label;
}

/// 目录页的一次快照（数据 + 筛选条件 + 提示文案）。
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

  /// 失败文案。非空且 [all] 为空时界面显示成失败页。
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
        // 用 `searchBlob` 而不是裸的 `state` —— 它里面带了
        // `stateZh(state)`（中文州名）。原来只比英文原文，于是搜
        // 「俄亥俄」一条都搜不到，界面还说「这个筛选下没有号码」。
        return n.searchBlob.contains(q);
      });
    }

    if (tab == NumberTab.fresh) {
      items = items.where((n) => n.isFresh);
    }

    // 排序规则在 `domain/number_sort.dart`，纯 Dart、可离线测。
    // 每个比较器都兜到 `number` 上，保证是全序 —— 分页并发抓回来的
    // 入参顺序每次都可能不同，不回 0 才不会让列表顺序在刷新之间漂移。
    return sortNumbers(items.toList(), sort, firstSeen: firstSeen);
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
