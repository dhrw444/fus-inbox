/// 账本的值类型：一份绑定、一次决策，以及直连占位。
///
/// 从 `identity_ledger.dart` 拆出来的理由和 `translation.dart` 那次一样：
/// 那边要同时装「一个身份绑了哪些号」的数据、`plan()` 的判断逻辑和
/// 落盘 JSON，再加几个只有字段的类就太挤了。
///
/// 这几个类型**没有依赖**（除了 `ProxyConfig`），所以能被纯逻辑测试直接
/// 引用 —— `tool/ledger_test.dart` 就是这么跑的。
library;

import 'package:fus_inbox/core/proxy/proxy_config.dart';

/// 账本里给「无代理」用的直连占位（`proxyId` 是空串）。
///
/// 是函数而不是 const 变量：返回值依赖 [ProxyScheme.direct] 枚举，
/// 非 const 上下文写不了。
ProxyConfig directProxy() => const ProxyConfig(
  id: '',
  scheme: ProxyScheme.direct,
  host: '',
  port: 0,
  label: '直连',
);

/// 一个代理上绑定的身份。
class const IdentityBinding({
  required this.proxyId,
  required this.userAgent,
  required this.model,
  required this.chromeMajor,
  required this.openedNumbers,
  required this.createdAtMs,
}) {
  /// 绑在哪个代理上（直连占位就是空串，见 [directProxy]）。
  final String proxyId;

  /// 该身份的完整 User-Agent，以及 UA 里的 Chrome 主版本号。
  final String userAgent;
  final String model;
  final String chromeMajor;

  /// 这个身份已经看过哪些号码（站点 ID）。
  ///
  /// 存号码 ID 而不是时间戳：同一个号重复打开不该重复计数，
  /// 而站点对「24 小时内打开过的号」是放行的。
  final List<String> openedNumbers;

  /// 身份的铸造时间（毫秒），目前只落盘备查。
  final int createdAtMs;

  int get used => openedNumbers.length;

  bool hasSeen(String numberId) => openedNumbers.contains(numberId);

  Map<String, Object?> toJson() => {
    'proxyId': proxyId,
    'userAgent': userAgent,
    'model': model,
    'chromeMajor': chromeMajor,
    'openedNumbers': openedNumbers,
    'createdAtMs': createdAtMs,
  };

  static IdentityBinding? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final proxyId = raw['proxyId']?.toString() ?? '';
    final ua = raw['userAgent']?.toString() ?? '';
    // **只拒 `ua` 为空的**，不拒 `proxyId` 为空。
    //
    // 直连占位的 `proxyId` 就是空串（见 [_directProxy]），它是合法值，
    // 和「坏数据」不是一回事。以前这里连 `proxyId.isEmpty` 一起拒掉，
    // 结果是直连出口的账本重启即丢：下次开号 `_bindings['']` 是 null →
    // `existing == null` → 在**同一个 IP** 上造一台新身份，正是本文件
    // 开头说的「同一个 IP 上冒出第二台」。
    if (ua.isEmpty) return null;
    final nums = <String>[];
    final list = raw['openedNumbers'];
    if (list is List) {
      for (final n in list) {
        final s = n?.toString() ?? '';
        if (s.isNotEmpty) nums.add(s);
      }
    }
    return IdentityBinding(
      proxyId: proxyId,
      userAgent: ua,
      model: raw['model']?.toString() ?? '',
      chromeMajor: raw['chromeMajor']?.toString() ?? '',
      openedNumbers: nums,
      createdAtMs:
          int.tryParse(raw['createdAtMs']?.toString() ?? '') ??
          DateTime.now().millisecondsSinceEpoch,
    );
  }
}

/// 打开一个号码之前要做什么。
enum OpenAction() {
  /// 复用当前代理 + 当前身份，直接开。
  reuse,

  /// 这条出口上还没有身份：造一个新身份，然后再开。
  ///
  /// 不是「额度用满」—— 本地不限号（见 `IdentityLedger` 文件头）。
  /// 只在「当前出口上没有任何身份」时出现。
  rotate,

  /// 这个号之前被另一条出口上的身份看过：切回那条出口，复用那个身份。
  ///
  /// 不新造身份。站点把「看过哪些号」记在 reader 身份自己的
  /// localStorage / IndexedDB 里，24 小时内重看同一个号是放行的；
  /// 换个身份再进来，它根本不知道你看过 —— 直接当成全新收件箱。
  restore,
}

class const OpenPlan({
  required this.action,
  required this.proxy,
  required this.binding,
  required this.reason,
}) {
  final OpenAction action;

  /// 应该用哪个代理。
  final ProxyConfig proxy;

  /// 应该用哪个身份（rotate 时是**新造**的）。
  final IdentityBinding binding;

  /// 给界面看的一句话，说清为什么。
  final String reason;

  bool get rotated => action == OpenAction.rotate;

  /// 为了回到「看过这个号的那条出口」而换了代理。
  ///
  /// 和 [rotated] 分开：rotate 是这条出口上还没有身份、要造一个新的；
  /// restore 是特意切回原来那条 —— 不新造身份。
  bool get restored => action == OpenAction.restore;
}
