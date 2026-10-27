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
class const IdentityBinding({
  required this.proxyId,
  required this.userAgent,
  required this.model,
  required this.chromeMajor,
  required this.openedNumbers,
  required this.createdAtMs,
}) {
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
enum OpenAction() {
  /// 复用当前代理 + 当前身份，直接开。
  reuse,

  /// 该身份看满额度了：换代理 + 换身份，然后再开。
  rotate,

  /// 这个号之前被另一条出口上的身份看过：切回那条出口，复用那个身份。
  ///
  /// 不新造身份、也不占新额度。站点把「看过哪些号」记在 reader 身份
  /// 自己的 localStorage / IndexedDB 里，24 小时内重看同一个号是放行的；
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
  /// 和 [rotated] 分开：rotate 是额度用满、被迫换新的；
  /// restore 是特意切回原来那条 —— 不新造身份，也不吃新额度。
  bool get restored => action == OpenAction.restore;
}

/// 账本。纯逻辑，不碰磁盘不碰网络。
class IdentityLedger {
  // 带初始化列表 + 非 this 参数，主构造器表达不了。
  // ignore: use_primary_constructors
  IdentityLedger({
    Map<String, IdentityBinding>? bindings,
    this.maxPerIdentity = 3,
  }) : _bindings = {...?bindings};

  final Map<String, IdentityBinding> _bindings;

  /// 一个身份最多看几个号。实测站点给新号额度是 3。
  final int maxPerIdentity;

  Map<String, IdentityBinding> get bindings => Map.unmodifiable(_bindings);

  IdentityBinding? forProxy(String proxyId) => _bindings[proxyId];

  /// 哪个绑定已经看过这个号。没有就返回 null。
  ///
  /// 多个绑定都看过时取**最早创建**的那个 —— 正常情况下一个号只会
  /// 落在一个绑定上（commit 只在代理真设成之后才写），这里只是兜底，
  /// 取个确定的顺序，免得行为飘。
  IdentityBinding? _bindingSeeing(String numberId) {
    IdentityBinding? found;
    for (final b in _bindings.values) {
      if (!b.hasSeen(numberId)) continue;
      if (found == null || b.createdAtMs < found.createdAtMs) found = b;
    }
    return found;
  }

  /// 一个身份最多看几个号。
  ///
  /// 实测：一个身份 + 一个出口 IP 只给 3 个新号，第 4 个直接
  /// `New inboxes are on pause`。这个数不是猜的。
  static const int slotsPerIdentity = 3;

  /// 这个出口已经用掉几个号。
  int usedFor(String proxyId) => _bindings[proxyId]?.used ?? 0;

  /// 决定这次打开该用哪个代理、哪个身份。
  ///
  /// [pool] 是代理池（内置 + 手加），[currentProxyId] 是当前选中的代理，
  /// [numberId] 是这次要看的号。
  ///
  /// [unusable] 是检测已判死的代理 id，会被排除在候选外 —— 但只
  /// 在还剩别的可选时才排，见下面的注释。
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
    Set<String> unusable = const {},
  }) {
    // 检测已经判死的代理不进候选，但**只在还有别的可选时**才剔。
    // 全都被判死时退化成不剔 —— 那说明检测本身有问题（比如用户
    // 在没网的时候点了一次全部检测），按检测结果走会变成直连，
    // 拿真实 IP 去撞站点比用一条可疑代理更糟。
    final usable = pool.where((p) => !unusable.contains(p.id)).toList();
    final candidates = usable.isNotEmpty ? usable : pool;

    final current =
        candidates.where((p) => p.id == currentProxyId).firstOrNull ??
        candidates.firstOrNull;
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

    // 这个号之前是谁看的？必须回到那条出口、那个身份。
    //
    // 站点把「看过哪些号」记在 reader 身份自己的 localStorage /
    // IndexedDB 里 —— 24 小时内重看同一个号是放行的，不扣额度。
    // 换个身份再进来，它不知道你看过，直接当成全新收件箱：既吃一次
    // 新额度，又更容易撞人机验证。
    //
    // 之前这里只查 _bindings[current.id]，轮换过之后回头点老号必然
    // 落到新身份上 —— 就是「重新点进去不是之前那条 socks5 + 身份」。
    final owner = _bindingSeeing(numberId);
    if (owner != null && owner.proxyId != current.id) {
      final ownerProxy = candidates
          .where((p) => p.id == owner.proxyId)
          .firstOrNull;
      if (ownerProxy != null) {
        return OpenPlan(
          action: OpenAction.restore,
          proxy: ownerProxy,
          binding: owner,
          reason: '这个号是 ${ownerProxy.displayName} 上的身份看过的，切回去复用',
        );
      }
    }

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

    // 满了 → 换代理。
    //
    // 身份怎么来，看目标出口上有没有旧绑定：
    //   - 没有 → 造一个新的（新出口 + 新身份，最干净）
    //   - 有 → **复用那个**，不造新的
    //
    // 第二条很关键。_nextProxy 优先挑没绑过的出口，但池子用旧之后会
    // 落到「绑过、还有余额」的出口上。那种出口上已经有一台设备了，
    // 再 mint 一个就等于同一个 IP 上冒出第二台 —— 站点眼里这是最扎眼
    // 的信号。复用它自己的身份，账本才是「一个代理一个身份」。
    final nextProxy = _nextProxy(candidates, current.id);
    final carried = _bindings[nextProxy.id];
    if (carried != null && carried.used < maxPerIdentity) {
      return OpenPlan(
        action: OpenAction.rotate,
        proxy: nextProxy,
        binding: carried,
        reason:
            '当前出口已用满 $maxPerIdentity 个号，换到 ${nextProxy.displayName}'
            '（那边还有 ${maxPerIdentity - carried.used} 个额度）',
      );
    }
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

  /// 池里下一条**还能用的**代理。
  ///
  /// 之前这里只是 `pool[(idx + 1) % pool.length]` —— 纯粹的 +1，压根
  /// 没检查下一条是不是也已经用满。可界面在满的代理上写着「下次会跳过」，
  /// 那是句谎话：真轮到它时照样被选中，照样在那个烧掉的出口上造一个新
  /// 身份，白耗一次轮转；而且站点那边这个 IP 早被盯上了，很容易直接
  /// 弹 CF 验证 —— 就是「有的时候会 cf 验证错误」的来源之一。
  ///
  /// 挑的顺序是两轮，不能反：
  ///   1) 没绑过身份的出口 —— 在上面开一个新身份，正是「一代理一身份」
  ///   2) 绑过、但还有余额的出口 —— 接着用它的身份往下数
  /// 两轮都空（整池都满了）才退回「下一条」。
  ///
  /// 之所以优先找没绑过的：落在一条已经绑过的出口上又造新身份，等于
  /// 同一个 IP 上出现两台设备；而只认没绑过的又会在池子用旧之后无路
  /// 可走，所以留第二轮兜底。
  ///
  /// 轮转而不是随机：代理池通常按顺序配的，随机容易连着撞同一条。
  ProxyConfig _nextProxy(List<ProxyConfig> pool, String currentId) {
    if (pool.isEmpty) return _directProxy();
    if (pool.length == 1) return pool.first;
    final idx = pool.indexWhere((p) => p.id == currentId);
    final start = idx < 0 ? 0 : idx + 1;

    ProxyConfig? partial;
    for (var i = 0; i < pool.length; i++) {
      final p = pool[(start + i) % pool.length];
      if (p.id == currentId) continue;
      final b = _bindings[p.id];
      if (b == null) return p;
      if (b.used < maxPerIdentity) partial ??= p;
    }
    if (partial != null) return partial;
    // 全满了。退回「下一条」，至少不会原地卡住 —— 真到这一步说明
    // 池子的额度整个用完了，该提醒用户加代理。
    return pool[start % pool.length];
  }

  /// [plan] 和 `ProxyNotifier.rotateToNext` 共用同一条挑选规则。
  ///
  /// 两条路径必须一致：`plan` 管「开新号时当前出口满了」，`rotateToNext`
  /// 管「站点报限额时自动换」。之前只修了前者，后者还是纯 +1 —— 于是
  /// 恰恰在最需要跳过的场合（出口刚被限额烧掉）又落回一条用满的出口。
  ProxyConfig? nextUsableProxy(List<ProxyConfig> pool, String currentId) {
    if (pool.isEmpty) return null;
    return _nextProxy(pool, currentId);
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
