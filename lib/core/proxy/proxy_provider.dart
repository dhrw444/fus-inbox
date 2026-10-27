/// 代理池的持久化 + 当前选中项 + 身份账本 + 连通性检测。
///
/// 全部落 SharedPreferences，字段少、读写快，不需要数据库。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fus_inbox/core/proxy/builtin_proxies.dart';
import 'package:fus_inbox/core/proxy/identity_ledger.dart';
import 'package:fus_inbox/core/proxy/proxy_config.dart';
import 'package:fus_inbox/core/proxy/proxy_probe.dart';
import 'package:fus_inbox/core/proxy/proxy_state.dart';

export 'package:fus_inbox/core/proxy/proxy_state.dart';

const _kPool = 'fus:proxy:pool:v1';
const _kCurrent = 'fus:proxy:current:v1';
const _kLedger = 'fus:identity:ledger:v1';
const _kAutoProxy = 'fus:proxy:auto:v1';

class ProxyNotifier() extends Notifier<ProxyState> {
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
      final p = await SharedPreferences.getInstance();
      final poolRaw = p.getString(_kPool) ?? '[]';
      final list = <ProxyConfig>[];
      final decoded = jsonDecode(poolRaw);
      if (decoded is List) {
        for (final item in decoded) {
          if (item is Map) {
            final cfg = ProxyConfig.fromJson(item.cast<String, Object?>());
            if (cfg != null) list.add(cfg);
          }
        }
      }
      final excludedRaw =
          p.getStringList(BuiltinProxies.excludedPrefsKey) ?? const <String>[];
      final excluded = excludedRaw.toSet();

      final ledgerRaw = p.getString(_kLedger);
      final ledger = ledgerRaw == null
          ? IdentityLedger()
          : IdentityLedger.fromJson(jsonDecode(ledgerRaw));
      final current = p.getString(_kCurrent) ?? '';
      final auto = p.getBool(_kAutoProxy) ?? true;

      final builtin = await const BuiltinProxies().load(excluded: excluded);
      final all = [...builtin, ...list];

      state = ProxyState(
        pool: list,
        builtin: builtin,
        excludedBuiltin: excluded,
        currentId: current.isNotEmpty && all.any((e) => e.id == current)
            ? current
            : (all.firstOrNull?.id ?? ''),
        ledger: ledger,
        autoRotate: auto,
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
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(
        _kPool,
        jsonEncode(state.pool.map((e) => e.toJson()).toList()),
      );
      await p.setString(_kCurrent, state.currentId);
      await p.setString(_kLedger, jsonEncode(state.ledger.toJson()));
      await p.setBool(_kAutoProxy, state.autoRotate);
      await p.setStringList(
        BuiltinProxies.excludedPrefsKey,
        state.excludedBuiltin.toList(),
      );
    } catch (_) {}
  }

  /// 加一条。重复的（同 id）直接覆盖。
  Future<void> add(ProxyConfig config) async {
    final next = [...state.pool.where((e) => e.id != config.id), config];
    state = state.copyWith(
      pool: next,
      currentId: state.currentId.isEmpty ? config.id : state.currentId,
    );
    await _persist();
  }

  /// 批量添加。返回每条的错误信息（成功的不列）。
  Future<List<String>> addLines(List<String> lines) async {
    final errors = <String>[];
    final added = <ProxyConfig>[];
    for (final raw in lines) {
      final trimmed = raw.trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
      final cfg = parseProxyLine(trimmed);
      if (cfg == null) {
        errors.add(trimmed);
      } else {
        added.add(cfg);
      }
    }
    if (added.isEmpty) return errors;
    final ids = added.map((e) => e.id).toSet();
    final next = [...state.pool.where((e) => !ids.contains(e.id)), ...added];
    state = state.copyWith(
      pool: next,
      currentId: state.currentId.isEmpty ? added.first.id : state.currentId,
    );
    await _persist();
    return errors;
  }

  Future<void> remove(String id) async {
    final isBuiltin = state.builtin.any((e) => e.id == id);
    final nextPool = state.pool.where((e) => e.id != id).toList();
    final nextBuiltin = state.builtin.where((e) => e.id != id).toList();
    final nextExcluded = isBuiltin
        ? {...state.excludedBuiltin, id}
        : state.excludedBuiltin;

    final all = [...nextBuiltin, ...nextPool];
    state = state.copyWith(
      pool: nextPool,
      builtin: nextBuiltin,
      excludedBuiltin: nextExcluded,
      currentId: state.currentId == id
          ? (all.firstOrNull?.id ?? '')
          : state.currentId,
    );
    await _persist();
  }

  /// 恢复所有被删掉的内置代理。
  Future<void> restoreBuiltin() async {
    final builtin = await const BuiltinProxies().load();
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
    if (state.currentId != proxyId) {
      state = state.copyWith(currentId: proxyId);
    }
    await _persist();
  }

  /// 手动换身份：清掉当前代理上的绑定，下次打开会造新的。
  Future<void> resetCurrentIdentity() async {
    state.ledger.clearProxy(state.currentId);
    await _persist();
  }

  /// 换到下一条**还能用的**代理。
  ///
  /// 挑选规则和 [IdentityLedger.plan] 完全一致（都走
  /// [IdentityLedger.nextUsableProxy]）—— 之前这里是纯 `(idx + 1)`，
  /// 于是「站点报限额时自动换」这条最需要跳过的路径，恰恰会落回一条
  /// 用满的出口上，白烧一次轮转。
  ///
  /// **不**再无条件清目标出口的绑定。目标出口上如果已经有一台设备
  /// （绑过、还有余额），清掉它等于让同一个 IP 换台机器，比不动更扎眼；
  /// 调用方会读到残留的绑定并沿用那个身份。只有目标出口是干净的、或者
  /// 已经用满时，才清掉让调用方造新身份。
  ///
  /// 判死的代理会跳过，除非全部都被判死。返回换到的那条，池子空时返回 null。
  Future<ProxyConfig?> rotateToNext() async {
    final all = state.all;
    if (all.isEmpty) return null;

    final unusable = state.results.entries
        .where((e) => !e.value.ok)
        .map((e) => e.key)
        .toSet();
    final usable = all.where((p) => !unusable.contains(p.id)).toList();
    final candidates = usable.isNotEmpty ? usable : all;

    final next =
        state.ledger.nextUsableProxy(candidates, state.currentId) ??
        candidates.first;

    state = state.copyWith(currentId: next.id);

    // 只在「这条出口上没有可沿用的身份」时清。
    // 用满的也要清 —— 那个身份已经没额度了，留着只会让下一次 plan
    // 又把它当成「还有余额」然后原地打转。
    final bound = state.ledger.forProxy(next.id);
    if (bound == null || bound.used >= state.ledger.maxPerIdentity) {
      state.ledger.clearProxy(next.id);
    }
    await _persist();
    return next;
  }

  Future<void> clearLedger() async {
    state.ledger.clearAll();
    await _persist();
  }

  /// 对全部代理跑一遍连通性检测。
  ///
  /// 真的走 SOCKS5 握手 + 到达站点 + 读回出口 IP，不是只看端口开没开。
  /// 内置清单里实测 616 条端口开着、只有 589 条真能用 —— 差 27 条，
  /// 光探端口会把这 27 条当成好的。
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

    final results = <String, ProxyProbeResult>{};
    var done = 0;
    final queue = [...targets];

    Future<void> worker() async {
      while (queue.isNotEmpty) {
        final cfg = queue.removeAt(0);
        ProxyProbeResult r;
        try {
          r = await _probe.probeOne(cfg);
        } catch (e) {
          r = ProxyProbeResult.dead(cfg, '${e.runtimeType}');
        }
        results[cfg.id] = r;
        done++;
        state = state.copyWith(
          progress: done,
          results: Map<String, ProxyProbeResult>.unmodifiable(results),
        );
      }
    }

    await Future.wait(List.generate(concurrency, (_) => worker()));
    state = state.copyWith(probing: false);
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
