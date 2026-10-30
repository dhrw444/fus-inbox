/// 代理池的**纯值状态**。不碰 Flutter、不碰 SharedPreferences。
///
/// 从 proxy_provider.dart 里拆出来是有原因的：
///
/// 1. 它是不可变值类，逻辑只有 `copyWith` 和几个派生 getter —— 这类东西
///    应该能脱离框架单测。跟 Notifier 挤在一个文件里，任何测试都得先把
///    flutter_riverpod 和 shared_preferences 拉进来，纯 Dart 环境直接编不过。
/// 2. 职责本来就不一样：这个文件回答「现在是什么状态」，Notifier 回答
///    「状态怎么变、怎么落盘」。混在一起时改一个字段要翻 400 行。
library;

import 'package:fus_inbox/core/proxy/identity_ledger.dart';
import 'package:fus_inbox/core/proxy/proxy_config.dart';
import 'package:fus_inbox/core/proxy/proxy_probe.dart';

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
    this.loaded = false,
  }) : ledger = ledger ?? IdentityLedger();

  /// 磁盘上的代理清单读完了没有。
  ///
  /// [ProxyNotifier.build] 同步返回空状态、靠 microtask 异步回填，所以在
  /// 回填之前 `pool` 和 `builtin` 都是空的 —— 那**不代表**用户没配代理。
  /// 分不清这两件事的调用方会把「还没读」当成「没代理」，于是产出一条
  /// 直连计划、拿真实 IP 去开号。开号是消耗品，一次就吃掉一个额度。
  ///
  /// 所以计划必须在 `loaded` 为真之后才算（见 `_startUp`）。
  final bool loaded;

  /// 还有没有别的代理可换。
  ///
  /// ## 判据必须和 [pickRotation] 完全一致
  ///
  /// 这个 getter 决定界面说什么、以及自动换出口那条路走不走得下去；
  /// `pickRotation`（`proxy_pool_ops.dart`）决定真的换到哪一条。两边
  /// 用不同规则，就会出现「说没有可换的，其实有」这种卡死。
  ///
  /// ## 原来那条规则错在哪
  ///
  /// 以前写的是「可用条数 > 1」，两种情况会误判成「没得换」：
  ///
  ///   1. 池里 2 条、检测判死 1 条 —— 可用只剩 1 条，于是 `1 > 1` 为假。
  ///      可那条**不是当前出口**，换过去完全有效。用户被判死一条烂
  ///      出口之后，会一直卡在剩下那条上，界面还告诉他「没有别的出口」。
  ///      这是最常撞上的一种：粘一批免费 SOCKS5 进来、点一次全部检测，
  ///      只剩一条通的。
  ///   2. 全池被判死。可用 0 条，`0 > 1` 为假。但 [pickRotation] 的
  ///      规则是「全判死就不剔 —— 宁可用可疑代理，不裸奔直连」，
  ///      也就是说它**愿意**换。两条规则互相矛盾。
  ///
  /// 现在直接问 [IdentityLedger.nextUsableProxy]：「按换出口的规则，
  /// 下一条是不是还是我自己？」是就是没得换。规则只有一处定义，
  /// 不可能再对不上。
  ///
  /// **必须和 [pickRotation] 的「目标不能是当前那条」对齐**：
  /// `pickRotation` 现在把 `currentId` 从候选里剔掉，剔完为空就返回
  /// null（宁可什么都不做，也不在同一 IP 上换身份）。这里照同一套：
  /// 剔完为空 = 没得换。
  bool get canRotate {
    final usable = all.where((p) => !isUnusable(p.id)).toList();
    // 和 pickRotation 一样：全判死也不剔，全池当候选。
    final candidates = usable.isNotEmpty ? usable : all;
    final others = candidates.where((p) => p.id != currentId).toList();
    if (others.isEmpty) return false;
    return ledger.nextUsableProxy(others, currentId)?.id != currentId;
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
    bool? loaded,
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
    loaded: loaded ?? this.loaded,
  );
}
