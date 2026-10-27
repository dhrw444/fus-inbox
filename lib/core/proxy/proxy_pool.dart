/// 代理池与浏览器身份的绑定。
///
/// ## 规则（这是整个功能的核心）
///
/// 站点按**出口 IP** 记配额，实测一个 IP 只给 3 个新号。所以：
///
/// ```
/// 一条代理  →  一个固定的浏览器身份
/// 这个身份看满 3 个号  →  换下一条代理 + 换一个身份
/// ```
///
/// 两条都必须做，缺一条都没用：
///
///   - **只换身份不换代理**：IP 没变，配额还在，第 4 个号照样被拒。
///     实测过：同 IP 上清空 localStorage / IndexedDB / cookie 之后，
///     第 4 个号依然 `New inboxes are on pause`。
///   - **只换代理不换身份**：站点那边的旧会话、旧 cookie、
///     旧 ECDSA 密钥还在，等于同一个访客换了个门进来。
///
/// ## 身份为什么要缓存
///
/// 同一个代理上反复生成新身份，在站点眼里就是「同一个 IP 一分钟来了
/// 十个新访客」—— 比单个爬虫更显眼，还会白白消耗 Turnstile 验证次数。
/// 所以一条代理只生成一次身份，存下来，之后一直用它，直到这条代理
/// 的配额用满。
library;

import 'dart:convert';

import 'package:fus_inbox/core/proxy/proxy_config.dart';

/// 一条代理当前的运行状态。
class ProxySlot {
  const ProxySlot({required this.proxy, required this.identity, this.used = 0});

  final ProxyConfig proxy;

  /// 绑定的浏览器身份（已序列化）。
  ///
  /// 存 Map 而不是 [BrowserIdentity] 是为了让这一层不依赖
  /// webview 模块，纯逻辑可测。
  final Map<String, Object?> identity;

  /// 这条代理下已经开过多少个号。
  final int used;

  ProxySlot copyWith({int? used}) =>
      ProxySlot(proxy: proxy, identity: identity, used: used ?? this.used);
}

/// 每多少条代理一组。
///
/// 实测：一个出口 IP 只给 **3 个新号**。第 4 个开始 `New inboxes are
/// on pause`。所以默认就是 3，写死在这个数上没意义，留成可调。
const kDefaultNumbersPerProxy = 3;

/// 轮换决策。
enum RotationReason {
  /// 这条代理的配额还没用满，继续用它。
  keep,

  /// 用满了，换下一条。
  quotaExhausted,

  /// 站点明确拒绝（配额/挑战），立刻换 —— 不必等到 3 个。
  ///
  /// 有时候第 1 个号就被拒（比如这个 IP 之前被别人用滥了）。
  /// 那时继续用同一个 IP 试剩下的 2 次是纯浪费。
  rejected,

  /// 没有可用代理。
  noProxy,
}

/// 轮换结果。
class RotationDecision {
  const RotationDecision({
    required this.reason,
    required this.next,
    this.message = '',
  });

  final RotationReason reason;

  /// 应该用哪一条。null 表示没有可用代理（[RotationReason.noProxy]）。
  final ProxySlot? next;

  /// 给用户看的一句话。
  final String message;
}

/// 代理轮换器。
///
/// 纯状态机，不碰网络、不碰磁盘 —— 所有持久化都由调用方注入。
class ProxyRotationEngine {
  ProxyRotationEngine({
    required this.slots,
    this.perProxyLimit = kDefaultNumbersPerProxy,
  });

  /// 全部代理，按用户配置的顺序。
  final List<ProxySlot> slots;

  /// 一条代理用满几个号就换。
  final int perProxyLimit;

  /// 当前在用的代理 id。
  String? _currentId;

  /// 当前代理已经开了几个号。
  int _used = 0;

  /// 当前代理 id。
  String? get currentId => _currentId;

  /// 当前已用次数。
  int get used => _used;

  /// 当前槽位。
  ProxySlot? get current {
    final id = _currentId;
    if (id == null) return null;
    for (final s in slots) {
      if (s.proxy.id == id) return s;
    }
    return null;
  }

  /// 从存储恢复上次的进度。
  ///
  /// 恢复的意义：App 被杀掉重开不该把已经用掉的 2 个号算成 0 ——
  /// 那样第 3 个号会被站点直接拒，用户看到的是「刚打开就被限」。
  void restore({String? currentId, int used = 0}) {
    if (currentId == null) return;
    if (!slots.any((s) => s.proxy.id == currentId)) return;
    _currentId = currentId;
    _used = used.clamp(0, perProxyLimit);
  }

  /// 开始用一个新号，返回应该用哪条代理。
  ///
  /// [reason] 传站点刚才的拒绝原因；正常开号传 null。
  RotationDecision beforeOpen({RotationReason? reason}) {
    if (slots.isEmpty) {
      return const RotationDecision(
        reason: RotationReason.noProxy,
        next: null,
        message: '还没有配置代理。加一条代理才能自动换 IP。',
      );
    }

    final exhausted =
        reason == RotationReason.rejected || _used >= perProxyLimit;

    if (!exhausted && _currentId != null && current != null) {
      return RotationDecision(
        reason: RotationReason.keep,
        next: current,
        message: '继续用这条代理（已开 $_used / $perProxyLimit）',
      );
    }

    final next = _nextSlot();
    if (next == null) {
      return const RotationDecision(
        reason: RotationReason.noProxy,
        next: null,
        message: '所有代理都用满了。再加一条代理，或等配额恢复。',
      );
    }

    _currentId = next.proxy.id;
    _used = 0;

    return RotationDecision(
      reason: reason == RotationReason.rejected
          ? RotationReason.rejected
          : RotationReason.quotaExhausted,
      next: next,
      message: '换到 ${next.proxy.displayName}，并换一个浏览器身份',
    );
  }

  /// 开号成功之后记一次。
  ///
  /// 只在这条号**真的读到了消息**时调用。开号失败不该计数 ——
  /// 否则站点的一次 503 就把配额算掉了，等于白扔一条代理。
  void markOpened() {
    _used += 1;
  }

  /// 从当前这条往后找下一条没用满的。
  ///
  /// 循环找：只有一条代理时会回到它自己（清空计数继续用，
  /// 而不是报「没有代理」—— 用户只有一条代理时那条仍是唯一选择）。
  ProxySlot? _nextSlot() {
    if (slots.isEmpty) return null;
    final start = _currentId == null
        ? 0
        : slots.indexWhere((s) => s.proxy.id == _currentId) + 1;
    for (var i = 0; i < slots.length; i++) {
      final slot = slots[(start + i) % slots.length];
      // 已存的 used 是持久化的历史计数，新一轮从 0 起算，
      // 所以这里只看「是不是当前这条」——当前这条刚用满要跳过。
      if (_currentId != null &&
          slot.proxy.id == _currentId &&
          slots.length > 1) {
        continue;
      }
      return slot;
    }
    return slots.first;
  }
}

/// 身份缓存：一条代理 → 一个身份，永久。
///
/// 存成 JSON 字符串的 map：`{proxyId: {userAgent, chromeMajor, model, ...}}`。
class IdentityCache {
  IdentityCache([Map<String, Map<String, Object?>>? seed]) : _map = {...?seed};

  final Map<String, Map<String, Object?>> _map;

  Map<String, Map<String, Object?>> get raw => {..._map};

  bool has(String proxyId) => _map.containsKey(proxyId);

  Map<String, Object?>? get(String proxyId) => _map[proxyId];

  void put(String proxyId, Map<String, Object?> identity) {
    _map[proxyId] = identity;
  }

  /// 这条代理被彻底弃用（用户删了它）时清掉它的身份。
  void remove(String proxyId) {
    _map.remove(proxyId);
  }

  /// 只保留仍然存在的代理，避免删掉代理之后缓存无限膨胀。
  void pruneTo(Iterable<String> liveProxyIds) {
    final live = liveProxyIds.toSet();
    _map.removeWhere((k, _) => !live.contains(k));
  }

  String encode() => jsonEncode(_map);

  static IdentityCache decode(String? raw) {
    if (raw == null || raw.trim().isEmpty) return IdentityCache();
    try {
      final obj = jsonDecode(raw);
      if (obj is! Map) return IdentityCache();
      final out = <String, Map<String, Object?>>{};
      obj.forEach((k, v) {
        if (k is String && v is Map) {
          out[k] = v.map((a, b) => MapEntry(a.toString(), b));
        }
      });
      return IdentityCache(out);
    } catch (_) {
      // 存储坏了就当空的重来，不要因此让 App 起不来。
      return IdentityCache();
    }
  }
}
