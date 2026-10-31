/// 代理池的磁盘读写：SharedPreferences 的 key **全在这一个文件里**。
///
/// ## 为什么从 `proxy_provider.dart` 拆出来
///
/// 那边（`ProxyNotifier`）回答「状态怎么变」，这里回答「状态怎么存下来」。
/// 原先四个 key 的拼写、内置清单的读取、以及 `jsonDecode` 的防御性解析全
/// 散在 notifier 的 `_load` / `_persist` 里，加起来一百多行，夹在十几个
/// 状态转移方法中间。改一个 key 要在一堆 `copyWith` 之间找。
///
/// ## 读要一次读全，写要一次写全
///
/// 这两件事必须成对、且**都是原子的**：
///
///   - 读：pool / 内置排除表 / 账本 / 当前选中是一份完整快照。分批读的话
///     中途失败会留下半份状态，而 `loaded` 只能表达「读完了」这一种结论。
///   - 写：`setString` 四次是四个独立的 IO。中途被杀就落下一个
///     「pool 是新的、currentId 还是旧的」的盘面 —— 下次启动会把账记到
///     错误的出口上。真要更强的一致性得上事务型存储，这里是刻意不做：
///     盘面上的不一致最多让用户重开一次（`currentId` 读回时会被校正到池子
///     里真实存在的那条），不值得为它换存储。
library;

import 'dart:convert';

import 'package:fus_inbox/core/prefs/storage_keys.dart';
import 'package:fus_inbox/core/proxy/builtin_proxies.dart';
import 'package:fus_inbox/core/proxy/identity_ledger.dart';
import 'package:fus_inbox/core/proxy/proxy_config.dart';
import 'package:fus_inbox/core/proxy/proxy_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 一次读盘的全部结果。
///
/// 做成一个值对象而不是让 `read()` 直接返回 `ProxyState`：`loaded` 和
/// `probing` / `results` 不是磁盘上的东西，混进来会让人以为它们也落盘。
class const ProxyPoolData({
  required this.pool,
  required this.builtin,
  required this.excludedBuiltin,
  required this.currentId,
  required this.ledger,
  required this.autoRotate,
}) {
  /// 用户手动添加的代理。
  final List<ProxyConfig> pool;

  /// 内置清单里没被删掉的代理。
  final List<ProxyConfig> builtin;

  /// 被删掉的内置代理 key。
  final Set<String> excludedBuiltin;

  /// 已经校正过：**一定落在池子里**（池子为空时是空串）。
  ///
  /// 磁盘上记的那条可能已经被删除、或者被排除表挡掉了。不校正的话界面会
  /// 拿着一个池子里不存在的 id 去查当前出口，兜底逻辑（`all.firstOrNull`）
  /// 会把账记到**另一条代理**名下 —— 显示「这个出口已看 N 个号」。
  final String currentId;

  final IdentityLedger ledger;

  /// 用满额度后自动换代理 + 换身份。
  final bool autoRotate;
}

/// 代理池的磁盘读写。无状态，可以随手 new。
class const ProxyStore() {
  /// 读回上次的清单。
  ///
  /// 任何异常都往外抛（prefs 打不开、账本 JSON 坏了），由调用方决定回落到
  /// 默认值 —— 那是「启动策略」，不是「存储细节」。
  Future<ProxyPoolData> read() async {
    final p = await SharedPreferences.getInstance();

    final poolRaw = kProxyPoolKey.readString(p) ?? '[]';
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
        kProxyBuiltinExcludedKey.readStringList(p) ?? const <String>[];
    final excluded = excludedRaw.toSet();

    final ledgerRaw = kIdentityLedgerKey.readString(p);
    final ledger = ledgerRaw == null
        ? IdentityLedger()
        : IdentityLedger.fromJson(jsonDecode(ledgerRaw));

    final current = kProxyCurrentKey.readString(p) ?? '';
    final auto = kProxyAutoRotateKey.readBool(p) ?? true;

    final builtin = await const BuiltinProxies().load(excluded: excluded);
    final all = [...builtin, ...list];

    return ProxyPoolData(
      pool: list,
      builtin: builtin,
      excludedBuiltin: excluded,
      currentId: current.isNotEmpty && all.any((e) => e.id == current)
          ? current
          : (all.firstOrNull?.id ?? ''),
      ledger: ledger,
      autoRotate: auto,
    );
  }

  /// 只读内置清单。恢复被删的内置代理时用。
  ///
  /// 不传 `excluded` 是有意的：恢复动作本身就是要拿回**全部**内置代理，
  /// 传上排除表等于刚恢复完又滤掉一遍。
  Future<List<ProxyConfig>> readBuiltin() => const BuiltinProxies().load();

  /// 落盘。
  ///
  /// 调用方负责处理异常（`ProxyNotifier._persist` 里吞掉并继续）：
  /// 写不进去不影响本次运行，下一次状态变化还会再试一次。
  Future<void> write(ProxyState state) async {
    final p = await SharedPreferences.getInstance();
    await kProxyPoolKey.writeString(
      p,
      jsonEncode(state.pool.map((e) => e.toJson()).toList()),
    );
    await kProxyCurrentKey.writeString(p, state.currentId);
    await kIdentityLedgerKey.writeString(p, jsonEncode(state.ledger.toJson()));
    await kProxyAutoRotateKey.writeBool(p, state.autoRotate);
    await kProxyBuiltinExcludedKey.writeStringList(
      p,
      state.excludedBuiltin.toList(),
    );
  }
}
