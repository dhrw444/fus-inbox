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
