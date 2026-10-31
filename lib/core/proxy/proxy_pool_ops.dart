/// 代理池的**纯决策函数**：给当前状态值，回答「下一步该是什么」。
///
/// ## 为什么单独一个文件
///
/// `ProxyNotifier` 的每个公开方法都是「算出下一个状态 + 写回去 + 落盘」。
/// 「算」这部分全是纯逻辑 —— 批量解析的容错、删除内置代理的排除表簿记、
/// 轮换时挑哪条、要不要清绑定 —— 挤在 notifier 里时，每条规则都被
/// `copyWith` / `_persist` / Riverpod 样板包着，读规则要先拨开三层状态写入。
///
/// 这里不碰 Riverpod、不碰 SharedPreferences、不改任何输入（账本只读），
/// 所以每条规则都能拿一组假状态直接跑 —— `tool/proxy_logic_test.dart`
/// 测的 `parseProxyLine` 是上一层的单行解析，这里是池级决策。
library;

import 'package:fus_inbox/core/proxy/identity_ledger.dart';
import 'package:fus_inbox/core/proxy/proxy_config.dart';
import 'package:fus_inbox/core/proxy/proxy_probe.dart';

/// 批量解析用户粘贴的多行代理。
///
/// 空行和 `#` 注释行跳过；认不出的原样进错误列表（界面要展示原文）。
/// 返回 `(解析成功的配置, 失败的原文)`。
(List<ProxyConfig>, List<String>) parseProxyLines(Iterable<String> lines) {
  final added = <ProxyConfig>[];
  final errors = <String>[];
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
  return (added, errors);
}

/// 池子里同 id 覆盖式合并：`old` 里去掉和 `added` 撞 id 的，`added` 排后面。
///
/// 手动添加一条、批量粘贴多行，走的都是这一条规则 —— 去重按 [ProxyConfig.id]
/// （`scheme://host:port`），改密码不算新代理。
List<ProxyConfig> mergeIntoPool(
  List<ProxyConfig> old,
  List<ProxyConfig> added,
) {
  final ids = added.map((e) => e.id).toSet();
  return [...old.where((e) => !ids.contains(e.id)), ...added];
}

/// 「池子还空着时，新加的第一条自动成为当前出口」。
///
/// 两条添加路径共用这一个兜底：空池加第一条不该停在「没选任何东西」，
/// 用户加完就直接能用。池子非空时用户的选择不受影响。
String currentAfterAdd(String currentId, List<ProxyConfig> added) =>
    currentId.isEmpty ? added.first.id : currentId;

/// 从池里移除一条之后的完整盘面。
class const PoolAfterRemoval({
  required this.pool,
  required this.builtin,
  required this.excludedBuiltin,
  required this.currentId,
}) {
  final List<ProxyConfig> pool;
  final List<ProxyConfig> builtin;
  final Set<String> excludedBuiltin;
  final String currentId;
}

/// 移除一条代理的所有簿记。
///
/// 三件事必须一起做，漏一件都是一个已知 bug 面：
///
/// - 内置代理不能真删（在 APK 资源里），只能进**排除表** —— 重启后
///   不再从内置清单里捞它；
/// - 当前选中的正好是它时，currentId 落到**还存在的**下一条
///   （内置在前）—— 留着死 id 会让界面拿空出口开号；
/// - pool 和 builtin 两边都要滤，同一条 id 不会两边都有，但滤两次
///   比判「在哪边」便宜。
PoolAfterRemoval poolAfterRemoval({
  required List<ProxyConfig> pool,
  required List<ProxyConfig> builtin,
  required Set<String> excludedBuiltin,
  required String currentId,
  required String id,
}) {
  final isBuiltin = builtin.any((e) => e.id == id);
  final nextPool = pool.where((e) => e.id != id).toList();
  final nextBuiltin = builtin.where((e) => e.id != id).toList();
  final nextExcluded = isBuiltin ? {...excludedBuiltin, id} : excludedBuiltin;
  final all = [...nextBuiltin, ...nextPool];
  return PoolAfterRemoval(
    pool: nextPool,
    builtin: nextBuiltin,
    excludedBuiltin: nextExcluded,
    currentId: currentId == id ? (all.firstOrNull?.id ?? '') : currentId,
  );
}

/// 轮换挑选的结果。
class const RotationChoice({required this.next, required this.clearBinding}) {
  /// 换到的那条。调用方保证非空时才用它。
  final ProxyConfig next;

  /// 目标出口上没有可沿用的身份 —— 调用方据此清掉绑定，
  /// 下次开号在它上面造新身份。
  final bool clearBinding;
}

/// 「换到下一条代理」的挑选规则。
///
/// 和 [IdentityLedger.nextUsableProxy] 完全一致（都走
/// `LedgerPlanner._nextProxy`）—— 之前这里是纯 `(idx + 1)`，
/// 于是「站点报限额时自动换」这条路径会落回一条刚被烧掉的出口上，
/// 白烧一次轮转。
///
/// - 检测判死的先剔出去；全被判死就不剔（宁可用可疑代理，不裸奔直连）。
/// - `clearBinding` 只在「目标出口上还没有身份」时为真。目标出口上
///   已经有一台设备时**不清**：复用它，才是「一个代理一个身份」；
///   在同一 IP 上再造一台才是最扎眼的信号。
///
/// 返回 null = 池子是空的（或只剩当前这一条），没得换。
RotationChoice? pickRotation({
  required List<ProxyConfig> all,
  required Map<String, ProxyProbeResult> results,
  required IdentityLedger ledger,
  required String currentId,
}) {
  if (all.isEmpty) return null;

  final unusable = results.entries
      .where((e) => !e.value.ok)
      .map((e) => e.key)
      .toSet();
  final usable = all.where((p) => !unusable.contains(p.id)).toList();
  final candidates = usable.isNotEmpty ? usable : all;

  // 目标出口**必须不是当前那一条**。
  //
  // `nextUsableProxy` 在「候选里没有别的可用出口」时会退回到当前那条
  // （`identity_plan.dart:339` 的 `fallback ?? pool[start % pool.length]`，
  // 池里只有一条时更是直接 `return pool.first`）。于是原来的
  // `?? candidates.first` 会把当前出口又选回来，而下面那行 `clear`
  // 只看「目标出口上有没有可沿用的身份」，不看「目标是不是正在用的那条」。
  // 合起来就是：`rotateToNext()` 返回非 null、`currentId` 写成同一个 id、
  // 并且清掉那个出口的身份 —— **在同一个 IP 上重置浏览器身份**，
  // 这比不换更可疑（站点注释反复警告过这一点）。
  //
  // 真的没有别的出口时返回 null：调用方据此告诉用户「池里只有这一条，
  // 加一条代理才能真正换出口」。宁可什么都不做，也不要假换。
  final others = candidates.where((p) => p.id != currentId).toList();
  if (others.isEmpty) return null;

  final next = ledger.nextUsableProxy(others, currentId) ?? others.first;

  // 目标出口上有没有可沿用的身份。
  //
  // **不再看「用满没」** —— 本地没有额度上限（见 `IdentityLedger` 文件头）。
  // 这里只关心一件事：那条出口上是不是已经有一台设备。有就复用它
  // （同一个 IP 上再 mint 一台才是最扎眼的信号），没有就让下次开号造。
  final clear = ledger.forProxy(next.id) == null;
  return RotationChoice(next: next, clearBinding: clear);
}
