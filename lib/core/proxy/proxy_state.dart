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
import 'package:fus_inbox/core/proxy/proxy_pool_ops.dart';
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
  /// **判据只有一处定义**：直接问 [pickRotation]「按换出口的规则，下一条
  /// 挑得出来吗」。挑不出来（池里没别的条目、别的条目都被检测判死、
  /// 或者有别的条目但组合下来仍然只能是当前这条）= 没得换。
  ///
  /// 以前这里把 `pickRotation` 的筛选规则复述了一遍（剔判死 → 剔当前 →
  /// 问账本），两处各写一遍必然漂：加一条「出口 IP 相同的跳过」就得记得
  /// 两边都改，忘一处就是「界面说能换，点了什么都不发生」。
  bool get canRotate =>
      pickRotation(
        all: all,
        results: results,
        ledger: ledger,
        currentId: currentId,
      ) !=
      null;

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

  /// 站点说新号额度用完时，自动换代理 + 换身份。
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

  /// **当前真正在用的出口**，包括「直连」这个选择本身。
  ///
  /// `currentId` 为空串 = 用户在设置里选了直连 —— 返回 [directProxy()]（`id` 也是
  /// 空串，`displayName` 是「直连」），**不是**池里第一条。
  ///
  /// 原来这里是 `?? all.firstOrNull`：id 查不到就退到第一条，而 `all` 里只有
  /// 用户加的 / 内置的条目，没有直连占位。于是设置页那张卡片左边写着
  /// 「当前：<某条节点>」（`proxy_cards.dart` 里 `current == null` 那个「当前：
  /// 直连」的分支**永远显示不出来**），右边「这个出口已看 N 个号」取的却是
  /// `currentId`（空串）的直连账本 —— 同一张卡片两半说的不是同一条出口。
  ///
  /// 唯一依赖那个兜底的是目录请求（`numbers_provider.dart`），它要的答案是
  /// 「有没有一条真代理可以拿出去抓目录」。那就给它 [realProxy] —— 需求写成
  /// 需求，不要靠一个「查不到就当第一条」的兜底去碰运气。直连也一样被明确
  /// 判掉（`isDirectProxy`）。
  ProxyConfig? get current => currentId.isEmpty ? directProxy() : realProxy;

  /// 池里**那条真的代理**，直连不算。没有任何真代理时为 null。
  ///
  /// 目录请求用它：直连不是用户要的出口，拿真实 IP 去抓目录不算交差。
  ProxyConfig? get realProxy => all.where((p) => p.id == currentId).firstOrNull;

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
