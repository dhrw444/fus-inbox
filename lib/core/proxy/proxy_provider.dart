/// 代理池的持久化 + 当前选中项 + 身份账本 + 连通性检测。
///
/// 全部落 SharedPreferences，字段少、读写快，不需要数据库。
library;

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fus_inbox/core/proxy/builtin_proxies.dart';
import 'package:fus_inbox/core/proxy/identity_ledger.dart';
import 'package:fus_inbox/core/proxy/proxy_config.dart';
import 'package:fus_inbox/core/proxy/proxy_probe.dart';

const _kPool = 'fus:proxy:pool:v1';
const _kCurrent = 'fus:proxy:current:v1';
const _kLedger = 'fus:identity:ledger:v1';
const _kAutoProxy = 'fus:proxy:auto:v1';

class ProxyState {
  // 带初始化列表 + 非 this 参数（ledger 要 ?? IdentityLedger()），
  // 主构造器表达不了。
  // ignore: use_primary_constructors
  ProxyState({
    this.pool = const [],
    this.builtin = const [],
    this.excludedBuiltin = const {},
    this.currentId = '',
    IdentityLedger? ledger,
    this.autoRotate = true,
    this.probing = false,
    this.progress = 0,
    this.probeTotal = 0,
    this.results = const {},
  }) : ledger = ledger ?? IdentityLedger();

  /// 还有没有别的代理可换。
  ///
  /// 只有一条（或全被判死只剩一条）时返回 false —— 那种情况下
  /// 「自动换」只会原地打转，界面该让用户自己去换 IP。
  ///
  /// 放在 [ProxyState] 上而不是 notifier 上：notifier 的公开 API
  /// 应该只有 `state`（`avoid_public_notifier_properties`）。
  bool get canRotate {
    final usable = all.where((p) => !isUnusable(p.id));
    return usable.length > 1;
  }

  /// 这条代理是不是被检测判死了。
  bool isUnusable(String proxyId) => results[proxyId]?.ok == false;

  /// 用户手动添加的代理。
  final List<ProxyConfig> pool;

  /// 内置清单里没被删掉的代理。
  ///
  /// 和 [pool] 分开存：内置的在 APK 资源里，不能改，只能靠排除表
  /// 隐藏。界面上两者显示完全一样，都能删。
  final List<ProxyConfig> builtin;

  /// 被删掉的内置代理 key。
  final Set<String> excludedBuiltin;

  final String currentId;
  final IdentityLedger ledger;

  /// 用满额度后自动换代理 + 换身份。
  final bool autoRotate;

  /// 正在跑连通性检测。
  final bool probing;

  /// 已检测多少条。
  final int progress;

  /// 本轮总共要检测多少条。
  final int probeTotal;

  /// 检测结果，key 是代理 id。
  final Map<String, ProxyProbeResult> results;

  /// 全部代理，内置在前。
  List<ProxyConfig> get all => [...builtin, ...pool];

  ProxyConfig? get current =>
      all.where((p) => p.id == currentId).firstOrNull ?? all.firstOrNull;

  ProxyState copyWith({
    List<ProxyConfig>? pool,
    List<ProxyConfig>? builtin,
    Set<String>? excludedBuiltin,
    String? currentId,
    IdentityLedger? ledger,
    bool? autoRotate,
    bool? probing,
    int? progress,
    int? probeTotal,
    Map<String, ProxyProbeResult>? results,
  }) => ProxyState(
    pool: pool ?? this.pool,
    builtin: builtin ?? this.builtin,
    excludedBuiltin: excludedBuiltin ?? this.excludedBuiltin,
    currentId: currentId ?? this.currentId,
    ledger: ledger ?? this.ledger,
    autoRotate: autoRotate ?? this.autoRotate,
    probing: probing ?? this.probing,
    progress: progress ?? this.progress,
    probeTotal: probeTotal ?? this.probeTotal,
    results: results ?? this.results,
  );
}

class ProxyNotifier() extends Notifier<ProxyState> {
  /// 检测器。无状态，整个 notifier 共用一个就够。
  final ProxyProbe _probe = ProxyProbe();

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

  /// 换到下一条代理，并把它上面的旧绑定清掉。
  ///
  /// 「换 IP」和「换身份」必须一起做 —— 只换一样站点都还认得出是同一个人
  /// （实测：同一 IP 换身份后第 4 个号照样被拒；只换 IP 不换身份，reader
  /// 密钥还是那一对）。所以这里顺手把绑定清了，调用方接着重置浏览器。
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

    final idx = candidates.indexWhere((p) => p.id == state.currentId);
    final next = candidates[(idx + 1) % candidates.length];

    // 新出口 = 新身份。清掉这条代理上的旧绑定，下次算计划时会造新的。
    state = state.copyWith(currentId: next.id);
    state.ledger.clearProxy(next.id);
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
}

final proxyProvider = NotifierProvider<ProxyNotifier, ProxyState>(
  ProxyNotifier.new,
);
