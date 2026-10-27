/// 代理 ↔ 身份 ↔ 号码 的账本。
///
/// ## 规则（用户定的）
///
/// 一个代理配置绑定一个浏览器身份；这个身份最多看 3 个号码；
/// 看满 3 个之后，换代理**并**换身份，重新开始。
///
/// ## 为什么是「代理 + 身份」一起换
///
/// 实测过，单独换任何一个都不行：
///
/// - 只换身份（清 localStorage / IndexedDB / cookie，UA 换新）：
///   第 4 个号照样 `New inboxes are on pause`。配额记在出口 IP 上。
/// - 只换代理：站点的 reader 身份还是那对 ECDSA 密钥，服务端认得
///   这是同一个人换了个出口 —— 更像是「有人在绕」而不是新访客。
///
/// 两个一起换才是完整的「新访客」：新出口 + 新密钥。
///
/// ## 为什么身份要缓存而不是每次现造
///
/// 同一个代理上反复造新身份会让这个出口迅速积累一堆半死的身份。
/// 缓存住，3 个号用满之前一直用同一个 —— 这也更接近真实用户行为。
library;

import 'package:fus_inbox/core/proxy/proxy_config.dart';

/// 直连用的占位配置。
///
/// 不放进池子里 —— 池子里只有用户真配的代理。直连只是「没配代理」
/// 时的兜底，账本照样能记账，界面逻辑不用分叉。
ProxyConfig _directProxy() => const ProxyConfig(
  id: '',
  scheme: ProxyScheme.direct,
  host: '',
  port: 0,
  label: '直连',
);

/// 一个代理上绑定的身份。
class IdentityBinding {
  const IdentityBinding({
    required this.proxyId,
    required this.userAgent,
    required this.model,
    required this.chromeMajor,
    required this.openedNumbers,
    required this.createdAtMs,
  });

  /// 绑在哪个代理上。
  final String proxyId;

  final String userAgent;
  final String model;
  final String chromeMajor;

  /// 这个身份已经看过哪些号码（站点 ID）。
  ///
  /// 存号码 ID 而不是时间戳：同一个号重复打开不该重复计数，
  /// 而站点对「24 小时内打开过的号」是放行的。
  final List<String> openedNumbers;

  final int createdAtMs;

  int get used => openedNumbers.length;

  bool hasSeen(String numberId) => openedNumbers.contains(numberId);

  IdentityBinding copyWith({
    List<String>? openedNumbers,
    String? userAgent,
    String? model,
    String? chromeMajor,
  }) => IdentityBinding(
    proxyId: proxyId,
    userAgent: userAgent ?? this.userAgent,
    model: model ?? this.model,
    chromeMajor: chromeMajor ?? this.chromeMajor,
    openedNumbers: openedNumbers ?? this.openedNumbers,
    createdAtMs: createdAtMs,
  );

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
    if (proxyId.isEmpty || ua.isEmpty) return null;
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
enum OpenAction {
  /// 复用当前代理 + 当前身份，直接开。
  reuse,

  /// 该身份看满额度了：换代理 + 换身份，然后再开。
  rotate,
}

class OpenPlan {
  const OpenPlan({
    required this.action,
    required this.proxy,
    required this.binding,
    required this.reason,
  });

  final OpenAction action;

  /// 应该用哪个代理。
  final ProxyConfig proxy;

  /// 应该用哪个身份（rotate 时是**新造**的）。
  final IdentityBinding binding;

  /// 给界面看的一句话，说清为什么。
  final String reason;

  bool get rotated => action == OpenAction.rotate;
}

/// 账本。纯逻辑，不碰磁盘不碰网络。
class IdentityLedger {
  IdentityLedger({
    Map<String, IdentityBinding>? bindings,
    this.maxPerIdentity = 3,
  }) : _bindings = {...?bindings};

  final Map<String, IdentityBinding> _bindings;

  /// 一个身份最多看几个号。实测站点给新号额度是 3。
  final int maxPerIdentity;

  Map<String, IdentityBinding> get bindings => Map.unmodifiable(_bindings);

  IdentityBinding? forProxy(String proxyId) => _bindings[proxyId];

  /// 决定这次打开该用哪个代理、哪个身份。
  ///
  /// [pool] 是用户配的代理池，[currentProxyId] 是当前选中的代理，
  /// [numberId] 是这次要看的号。
  ///
  /// 不会修改账本 —— 落账由 [commit] 做，这样界面可以先把决定
  /// 显示出来再执行。
  OpenPlan plan({
    required List<ProxyConfig> pool,
    required String currentProxyId,
    required String numberId,
    required String Function() mintUserAgent,
    required String Function() mintModel,
    required String Function() mintChromeMajor,
  }) {
    final current =
        pool.where((p) => p.id == currentProxyId).firstOrNull ??
        pool.firstOrNull;
    if (current == null) {
      // 没配代理：用直连，绑一个占位身份。这样界面逻辑不用分叉。
      final binding = IdentityBinding(
        proxyId: '',
        userAgent: mintUserAgent(),
        model: mintModel(),
        chromeMajor: mintChromeMajor(),
        openedNumbers: const [],
        createdAtMs: DateTime.now().millisecondsSinceEpoch,
      );
      return OpenPlan(
        action: OpenAction.reuse,
        proxy: _directProxy(),
        binding: binding,
        reason: '没配代理，走直连',
      );
    }

    final existing = _bindings[current.id];

    // 这个身份已经看过这个号 → 不计数，直接复用。
    // 站点对「24 小时内打开过的号」是放行的，重看同一个号不消耗额度。
    if (existing != null && existing.hasSeen(numberId)) {
      return OpenPlan(
        action: OpenAction.reuse,
        proxy: current,
        binding: existing,
        reason: '这个号当前身份看过了，直接复用',
      );
    }

    // 有绑定但还没满 → 复用。
    if (existing != null && existing.used < maxPerIdentity) {
      return OpenPlan(
        action: OpenAction.reuse,
        proxy: current,
        binding: existing,
        reason: '当前身份已用 ${existing.used}/$maxPerIdentity 个号',
      );
    }

    // 没绑定 → 在这个代理上造一个新身份。
    if (existing == null) {
      final binding = IdentityBinding(
        proxyId: current.id,
        userAgent: mintUserAgent(),
        model: mintModel(),
        chromeMajor: mintChromeMajor(),
        openedNumbers: const [],
        createdAtMs: DateTime.now().millisecondsSinceEpoch,
      );
      return OpenPlan(
        action: OpenAction.reuse,
        proxy: current,
        binding: binding,
        reason: '新代理，绑定新身份',
      );
    }

    // 满了 → 换代理 + 换身份。
    final nextProxy = _nextProxy(pool, current.id);
    final binding = IdentityBinding(
      proxyId: nextProxy.id,
      userAgent: mintUserAgent(),
      model: mintModel(),
      chromeMajor: mintChromeMajor(),
      openedNumbers: const [],
      createdAtMs: DateTime.now().millisecondsSinceEpoch,
    );
    return OpenPlan(
      action: OpenAction.rotate,
      proxy: nextProxy,
      binding: binding,
      reason: nextProxy.isDirectProxy
          ? '已用满 $maxPerIdentity 个号，换身份（没有别的代理了，走直连）'
          : '已用满 $maxPerIdentity 个号，换代理 ${nextProxy.displayName} + 换身份',
    );
  }

  /// 记下这次打开。
  ///
  /// 同一个号重复打开不会重复入账 —— 否则用户来回看同一个号
  /// 会把额度白白耗光。
  void commit(String proxyId, String numberId, IdentityBinding binding) {
    final base = _bindings[proxyId] ?? binding;
    final nums = [...base.openedNumbers];
    if (!nums.contains(numberId)) nums.add(numberId);
    _bindings[proxyId] = IdentityBinding(
      proxyId: proxyId,
      userAgent: binding.userAgent,
      model: binding.model,
      chromeMajor: binding.chromeMajor,
      openedNumbers: nums,
      createdAtMs: binding.createdAtMs,
    );
  }

  /// 清掉某个代理上的绑定（用户手动换身份时用）。
  void clearProxy(String proxyId) => _bindings.remove(proxyId);

  void clearAll() => _bindings.clear();

  /// 池里下一个非当前代理。池空或只有一个时返回当前那个。
  ///
  /// 轮转而不是随机：代理池通常按顺序配的，随机容易连着撞同一个
  /// 已经废掉的出口。
  ProxyConfig _nextProxy(List<ProxyConfig> pool, String currentId) {
    if (pool.isEmpty) return _directProxy();
    if (pool.length == 1) return pool.first;
    final idx = pool.indexWhere((p) => p.id == currentId);
    if (idx < 0) return pool.first;
    return pool[(idx + 1) % pool.length];
  }

  Map<String, Object?> toJson() => {
    'maxPerIdentity': maxPerIdentity,
    'bindings': _bindings.map((k, v) => MapEntry(k, v.toJson())),
  };

  static IdentityLedger fromJson(Object? raw) {
    if (raw is! Map) return IdentityLedger();
    final out = <String, IdentityBinding>{};
    final b = raw['bindings'];
    if (b is Map) {
      for (final entry in b.entries) {
        final binding = IdentityBinding.fromJson(entry.value);
        if (binding != null) out[binding.proxyId] = binding;
      }
    }
    return IdentityLedger(
      bindings: out,
      maxPerIdentity:
          int.tryParse(raw['maxPerIdentity']?.toString() ?? '') ?? 3,
    );
  }
}
