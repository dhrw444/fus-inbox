/// 代理池的持久化 + 当前选中项 + 身份账本。
///
/// 全部落 SharedPreferences，字段少、读写快，不需要数据库。
library;

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fus_inbox/core/proxy/identity_ledger.dart';
import 'package:fus_inbox/core/proxy/proxy_config.dart';

const _kPool = 'fus:proxy:pool:v1';
const _kCurrent = 'fus:proxy:current:v1';
const _kLedger = 'fus:identity:ledger:v1';
const _kAutoProxy = 'fus:proxy:auto:v1';

class ProxyState {
  const ProxyState({
    this.pool = const [],
    this.currentId = '',
    this.ledger = const IdentityLedger(),
    this.autoRotate = true,
  });

  final List<ProxyConfig> pool;
  final String currentId;
  final IdentityLedger ledger;

  /// 用满额度后自动换代理 + 换身份。
  final bool autoRotate;

  ProxyConfig? get current =>
      pool.where((p) => p.id == currentId).firstOrNull ?? pool.firstOrNull;

  ProxyState copyWith({
    List<ProxyConfig>? pool,
    String? currentId,
    IdentityLedger? ledger,
    bool? autoRotate,
  }) => ProxyState(
    pool: pool ?? this.pool,
    currentId: currentId ?? this.currentId,
    ledger: ledger ?? this.ledger,
    autoRotate: autoRotate ?? this.autoRotate,
  );
}

class ProxyNotifier extends Notifier<ProxyState> {
  @override
  ProxyState build() {
    // 先给空状态，异步回填。界面不会因为读盘而卡住。
    Future<void>.microtask(_load);
    return const ProxyState();
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
      final ledgerRaw = p.getString(_kLedger);
      final ledger = ledgerRaw == null
          ? IdentityLedger()
          : IdentityLedger.fromJson(jsonDecode(ledgerRaw));
      final current = p.getString(_kCurrent) ?? '';
      final auto = p.getBool(_kAutoProxy) ?? true;
      state = ProxyState(
        pool: list,
        currentId: current.isNotEmpty && list.any((e) => e.id == current)
            ? current
            : (list.firstOrNull?.id ?? ''),
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

  /// 从一行文本解析并加入。返回错误信息，null 表示成功。
  Future<String?> addFromLine(String raw, {String label = ''}) async {
    final cfg = parseProxyLine(raw, label: label);
    if (cfg == null) return '格式不对。例：socks5://user:pass@1.2.3.4:1080';
    await add(cfg);
    return null;
  }

  Future<void> remove(String id) async {
    final next = state.pool.where((e) => e.id != id).toList();
    state = state.copyWith(
      pool: next,
      currentId: state.currentId == id
          ? (next.firstOrNull?.id ?? '')
          : state.currentId,
    );
    await _persist();
  }

  Future<void> select(String id) async {
    if (!state.pool.any((e) => e.id == id)) return;
    state = state.copyWith(currentId: id);
    await _persist();
  }

  Future<void> setAutoRotate(bool value) async {
    state = state.copyWith(autoRotate: value);
    await _persist();
  }

  /// 记下这次打开用了哪个代理、哪个号。
  Future<void> commitOpen(String proxyId, String numberId, IdentityBinding binding) async {
    state.ledger.commit(proxyId, numberId, binding);
    await _persist();
  }

  /// 手动换身份：清掉当前代理上的绑定，下次打开会造新的。
  Future<void> resetCurrentIdentity() async {
    state.ledger.clearProxy(state.currentId);
    await _persist();
  }

  Future<void> clearLedger() async {
    state.ledger.clearAll();
    await _persist();
  }
}

final proxyProvider = NotifierProvider<ProxyNotifier, ProxyState>(
  ProxyNotifier.new,
);
