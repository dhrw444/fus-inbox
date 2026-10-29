/// 代理池的状态机：当前选中项、增删、以及身份账本上的动作。
///
/// 值状态见 `proxy_state.dart`（在这里转出去）；磁盘读写见 `proxy_store.dart`；
/// 「下一步是什么」的纯决策见 `proxy_pool_ops.dart`。
///
/// 这个文件只做**接线**：每个方法 = 调一条纯决策 + 写回 state + 落盘。
/// 不放 prefs key、不放 `jsonDecode`、不放挑选规则 —— 那些都在别的层里，
/// 改它们不该动这里。
///
/// 全部落 SharedPreferences，字段少、读写快，不需要数据库。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fus_inbox/core/proxy/identity_ledger.dart';
import 'package:fus_inbox/core/proxy/probe_session.dart';
import 'package:fus_inbox/core/proxy/proxy_config.dart';
import 'package:fus_inbox/core/proxy/proxy_pool_ops.dart';
import 'package:fus_inbox/core/proxy/proxy_probe.dart';
import 'package:fus_inbox/core/proxy/proxy_state.dart';
import 'package:fus_inbox/core/proxy/proxy_store.dart';

export 'package:fus_inbox/core/proxy/proxy_state.dart';

class ProxyNotifier() extends Notifier<ProxyState> {
  /// 无状态的存储层，随手 new 一个不花代价。
  static const _store = ProxyStore();

  /// 检测器。无状态，整个 notifier 共用一个就够。
  final ProxyProbe _probe = ProxyProbe();

  /// [_load] 跑完就 complete 一次，[ready] 等的是它。
  final Completer<void> _ready = Completer<void>();

  @override
  ProxyState build() {
    // 先给空状态，异步回填。界面不会因为读盘而卡住。
    Future<void>.microtask(_load);
    return ProxyState();
  }

  Future<void> _load() async {
    try {
      final data = await _store.read();
      state = ProxyState(
        pool: data.pool,
        builtin: data.builtin,
        excludedBuiltin: data.excludedBuiltin,
        currentId: data.currentId,
        ledger: data.ledger,
        autoRotate: data.autoRotate,
      );
    } catch (_) {
      // 读不出来就用默认值，别让启动挂在这。
    } finally {
      // 无论成败都要置位。读失败时池子确实是空的，那和「还没读」是两件事：
      // 前者该让上层去走直连（并明确告诉用户），后者必须继续等。
      state = state.copyWith(loaded: true);
      // 等待方当场醒来。只 complete 一次 —— Completer 重复 complete 会抛。
      if (!_ready.isCompleted) _ready.complete();
    }
  }

  Future<void> _persist() async {
    // 清单还没从磁盘读出来时落盘 = 拿出厂默认值覆盖用户数据。
    //
    // 这条路真的会走到：`_applyProxyPlan` 在 initState 之后约 120ms 就可能
    // `commitOpen` → `_persist`，而 `_load` 至少要过
    // `SharedPreferences.getInstance()` + 读内置资源两个 await。落下去的是
    // pool=[]、excludedBuiltin={}、currentId='' —— **用户手动加的代理在磁盘
    // 上被抹掉，删掉的内置代理全部复活**。而内存随后被 `_load` 用「它早先
    // 读到的旧值」覆盖，当场看不出任何异常，下次启动才发现数据没了。
    //
    // 等一等就好：`ready` 在 `_load` 的 finally 里必然完成（成功失败都完成），
    // 所以这里不会永久挂住。等完之后写的是内存里的当前态，这次改动不会丢。
    if (!state.loaded) {
      await ready;
    }
    // 兜底超时之后 `loaded` 仍可能是 false（读盘卡了 3 秒以上 —— 上面那句
    // `await` 到点就返回，不会一直等）。那时 `state` 里还是空池，写下去
    // 正是上面那段要防的事：**用户手动加的代理在磁盘上被抹掉**。
    //
    // 所以复查一次，没读完就不写。这次改动留在内存里，下一次状态变化
    // 会再试一遍（`_load` 只要成功过一次，`loaded` 就一直是 true）。
    if (!state.loaded) return;
    try {
      await _store.write(state);
    } catch (_) {
      // 写盘失败不回滚内存状态：用户看到的是当前这一次的选择，
      // 回滚会让他觉得「点了没反应」。下一次状态变化还会再写一次。
    }
  }

  /// 加一条。重复的（同 id）直接覆盖。
  Future<void> add(ProxyConfig config) async {
    final pool = mergeIntoPool(state.pool, [config]);
    state = state.copyWith(
      pool: pool,
      currentId: currentAfterAdd(state.currentId, [config]),
    );
    await _persist();
  }

  /// 批量添加。返回每条的错误信息（成功的不列）。
  Future<List<String>> addLines(List<String> lines) async {
    final (added, errors) = parseProxyLines(lines);
    if (added.isEmpty) return errors;
    state = state.copyWith(
      pool: mergeIntoPool(state.pool, added),
      currentId: currentAfterAdd(state.currentId, added),
    );
    await _persist();
    return errors;
  }

  Future<void> remove(String id) async {
    final r = poolAfterRemoval(
      pool: state.pool,
      builtin: state.builtin,
      excludedBuiltin: state.excludedBuiltin,
      currentId: state.currentId,
      id: id,
    );
    state = state.copyWith(
      pool: r.pool,
      builtin: r.builtin,
      excludedBuiltin: r.excludedBuiltin,
      currentId: r.currentId,
    );
    await _persist();
  }

  /// 恢复所有被删掉的内置代理。
  Future<void> restoreBuiltin() async {
    final builtin = await _store.readBuiltin();
    state = state.copyWith(builtin: builtin, excludedBuiltin: const {});
    await _persist();
  }

  Future<void> select(String id) async {
    if (!state.all.any((e) => e.id == id)) return;
    state = state.copyWith(currentId: id);
    await _persist();
  }

  Future<void> setAutoRotate(bool value) async {
    state = state.copyWith(autoRotate: value);
    await _persist();
  }

  /// 记下这次打开用了哪个代理、哪个号。
  Future<void> commitOpen(
    String proxyId,
    String numberId,
    IdentityBinding binding,
  ) async {
    state.ledger.commit(proxyId, numberId, binding);
    // 记完账顺手把 currentId 对齐到这次真正用的出口。
    //
    // 不这么做的话，plan() 里「满了 → 换代理」的分支每次都会重新
    // 执行一遍：currentId 还停在那条已经满的代理上，于是每次打开
    // 新号都判一次「满了」，都造一个新身份，都写进同一条记录的
    // openedNumbers —— 号数在涨，但用的还是同一个出口，站点那边
    // 早就拒了，本地账本却一路显示「已用 N 个」。
    //
    // `proxyId` 为空 = 这次走的是直连。**不能拿空串去覆盖用户选的那条**：
    // 冷启动首开（或池子读失败）时 `commitOpen('')` 会把 currentId 写成
    // 空串并落盘，设置页于是拿 `ProxyState.current` 的兜底（`all.firstOrNull`）
    // 把「直连」那笔账挂到**另一条代理**名下，显示「这个出口已看 1/3 个号」。
    if (proxyId.isNotEmpty && state.currentId != proxyId) {
      state = state.copyWith(currentId: proxyId);
    }
    await _persist();
  }

  /// 手动换身份：清掉当前代理上的绑定，下次打开会造新的。
  Future<void> resetCurrentIdentity() async {
    state.ledger.clearProxy(state.currentId);
    await _persist();
  }

  /// 换到下一条**还能用的**代理。挑选规则在 `proxy_pool_ops.dart`
  /// （[pickRotation]），这里只负责写回 + 清绑定 + 落盘。
  ///
  /// **不**无条件清目标出口的绑定 —— 那个判断在 [pickRotation] 里。
  /// 返回换到的那条，池子空时返回 null。
  Future<ProxyConfig?> rotateToNext() async {
    final choice = pickRotation(
      all: state.all,
      results: state.results,
      ledger: state.ledger,
      currentId: state.currentId,
    );
    if (choice == null) return null;

    state = state.copyWith(currentId: choice.next.id);
    if (choice.clearBinding) {
      state.ledger.clearProxy(choice.next.id);
    }
    await _persist();
    return choice.next;
  }

  Future<void> clearLedger() async {
    state.ledger.clearAll();
    await _persist();
  }

  /// 对全部代理跑一遍连通性检测。
  ///
  /// 真的走 SOCKS5 握手 + 到达站点 + 读回出口 IP，不是只看端口开没开。
  /// 内置清单里**当时**实测：端口开着的一大截、真能用的少一截，
  /// 光探端口会把差的那部分当成好的。
  Future<void> probeAll({int concurrency = 24}) async {
    if (state.probing) return;
    final targets = state.all;
    if (targets.isEmpty) return;

    state = state.copyWith(
      probing: true,
      progress: 0,
      probeTotal: targets.length,
      results: const {},
    );

    // 进度怎么写回 state、怎么收尾，全在 [runProbeSession] —— 以前这里
    // 自己实现了一遍 queue + worker + 快照，于是同一个逻辑有了两处：
    // `proxy_probe.dart` 里那份是死代码（零调用），两边的并发参数
    // （24 / `clamp(1,64)`）和异常汇总语义已经不一样了 —— provider 把异常
    // 压成 `'${e.runtimeType}'`，probe 那份交给调用方处理。改一处忘另一处
    // 就漂。
    try {
      await runProbeSession(
        probe: _probe,
        targets: targets,
        concurrency: concurrency,
        apply: (progress, probeTotal, results) {
          state = state.copyWith(
            progress: progress,
            probeTotal: probeTotal,
            // 每一轮都给一份不可变快照：界面直接 watch 这个 map，
            // 原地改的话 Riverpod 看不到变化。
            results: results,
          );
        },
      );
    } finally {
      // 被打断（异常、provider 被销毁）也不能把 `probing` 卡在 true ——
      // 卡住之后「全部检测」按钮永远是禁用的，用户以为在测。
      state = state.copyWith(probing: false);
    }
  }

  /// 等到磁盘上的代理清单读完（`state.loaded == true`）。
  ///
  /// [build] 是同步的，池子在 microtask 里才回填。调用方在 build 之后立刻
  /// 读 `state.pool` 会看到空列表，那和「用户没配代理」长得一样。收件页
  /// 拿这个空池算出的计划是直连 —— 等于拿真实 IP 去开号。
  ///
  /// 所以开号之前必须 `await` 这个。已经读完时立刻返回。
  ///
  /// 实现是 `Completer`，不是轮询：`_load` 结束时 [complete] 被叫一次，
  /// 等待方全部当场醒来。早先那版写的是 16ms 轮询，最坏要空转 187 次。
  ///
  /// 兜底超时：读盘卡住时不能让用户干等。到点返回时 `loaded` 可能仍是
  /// false，**调用方必须自己检查**（收件页检查了，见 `_startUp`）——
  /// 这里不抛异常，因为卡住的原因不明，硬失败会让用户连页面都打不开。
  Future<void> get ready =>
      _ready.future.timeout(const Duration(seconds: 3), onTimeout: () {});
}

final proxyProvider = NotifierProvider<ProxyNotifier, ProxyState>(
  ProxyNotifier.new,
);
