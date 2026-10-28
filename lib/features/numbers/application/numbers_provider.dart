/// 号码目录的**加载流程**：缓存、出口、拉取、进度、错误。
///
/// 值状态（筛选 / 计数 / `copyWith`）见 `number_directory_state.dart`；
/// 排序规则见 `domain/number_sort.dart` —— 两个都在这里转出去，引用方
/// （目录页、设置页、筛选栏）只认这一个入口，免得动一串 import。
///
/// 这个文件只管「状态怎么从网络和磁盘变出来」：什么时候读缓存、什么时候
/// 备出口、失败时怎么不把好数据洗掉。数据全部来自原生 HTTP 抓取
/// （见 NumbersRepository），WebView 不参与。
library;

import 'dart:async';

import 'package:fus_inbox/core/log.dart';
import 'package:fus_inbox/core/prefs/prefs_provider.dart';
import 'package:fus_inbox/core/proxy/proxy_engine_provider.dart';
import 'package:fus_inbox/core/proxy/proxy_provider.dart';
import 'package:fus_inbox/features/numbers/application/number_directory_state.dart';
import 'package:fus_inbox/features/numbers/data/directory_cache.dart';
import 'package:fus_inbox/features/numbers/data/numbers_repository.dart';
import 'package:fus_inbox/features/numbers/domain/number_sort.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

export 'package:fus_inbox/features/numbers/application/number_directory_state.dart';
export 'package:fus_inbox/features/numbers/domain/number_sort.dart'
    show NumberSort;

final numbersRepositoryProvider = Provider<NumbersRepository>((ref) {
  final repo = NumbersRepository(
    // 目录页的出口由用户偏好决定：
    //   关（默认）→ 'DIRECT'，走真实 IP
    //   开        → 当前那条出口（本地桥 / 直通 HTTP 代理）
    //
    // 每次请求都读一遍，不能把指令在构造时抓成常量 —— 代理会轮换，
    // 桥也会重建，端口每次都不一样。
    //
    // 注意这里返回 'DIRECT' 和返回 null 是**两件事**：
    // DIRECT 是用户明确选了直连；null 是「选了走代理但代理不可用」，
    // 那种情况 _findProxy 会抛异常让请求失败，不会静默退回直连。
    egress: () {
      if (!ref.read(prefsProvider).directoryViaProxy) return 'DIRECT';
      return ref.read(proxyEngineProvider).nativeEgressDirective;
    },
  );
  ref.onDispose(repo.dispose);
  return repo;
});

/// 目录页的 notifier：状态迁移 + 两条入口（缓存恢复、网络加载）。
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

  /// 备好目录要用的出口。**只在用户选了「目录走代理」时才需要。**
  ///
  /// 返回 `null` = 出口就绪；返回一句话 = 为什么没有。
  ///
  /// ## 只搭车，不换车
  ///
  /// 出口就是收件页那条 —— 同一条 `ProxyEngine`、同一个节点。所以
  /// **引擎已经有活动出口时这里直接返回，一个字都不改**。
  ///
  /// 这条早返回不是优化，是正确性：如果引擎此刻正给收件页用着节点 B，
  /// 而这里按「当前节点」重设一遍，就会把收件页的桥当场拆掉。
  /// 目录只是搭个顺风车，没有资格换车。
  ///
  /// 只有一种情况需要动手：用户一直待在号码页、从没开过号，引擎还没有
  /// 活动出口（`nativeEgressDirective` 返回 null，每条目录请求都会抛
  /// 「出口没起来」）。这时才用当前节点把它拉起来 —— 而收件页开号时
  /// 本来就会自己 `apply` 一次计划里的节点，所以不影响它。
  Future<String?> _ensureEgress() async {
    if (!ref.read(prefsProvider).directoryViaProxy) return null;

    final engine = ref.read(proxyEngineProvider);
    if (engine.active != null) return null;

    final proxyState = ref.read(proxyProvider);
    // 清单还没从磁盘读完时 pool 是空的 —— 那不是「没配代理」，
    // 是「还不知道有没有」。跟收件页那个坑是同一个。
    if (!proxyState.loaded) return '代理清单还没读完';

    final proxy = proxyState.current;
    if (proxy == null) {
      return '一条代理都没配（去设置里加一条，或关掉「号码目录走代理」）';
    }

    final result = await engine.apply(proxy);
    if (result.ok || proxy.isDirectProxy) return null;
    return result.detail;
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
      // 只有选了「目录走代理」才需要先备好出口 —— 直连不需要准备。
      // 不能在 fetchAll 里做这件事：那里已经开始分页并发了。
      if (ref.read(prefsProvider).directoryViaProxy) {
        final why = await _ensureEgress();
        if (why != null) {
          state = state.copyWith(
            loading: false,
            error: state.all.isEmpty ? '目录代理不可用：$why' : null,
            progress: '',
            status: state.all.isEmpty ? '' : '代理不可用，先看缓存',
          );
          return;
        }
      }

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
      // 写回缓存：下次启动就能秒开。失败只是下次慢一点，不拦流程。
      unawaited(saveDirectoryCache(list));
      logLine('目录加载完成：${list.length} 个号，${state.states.length} 个州');
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
