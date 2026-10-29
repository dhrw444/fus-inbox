/// 代理 ↔ 身份 ↔ 号码 的账本：**存**下「哪个出口用了哪个身份、看过哪些号」。
///
/// 值类型见 `identity_binding.dart`；开号决策见 `identity_plan.dart`
/// （都在这里转出去，引用方不用多写一行 import）。本文件只管存储与记账：
/// 绑定表的读写、`commit`、落盘 JSON。**决策不在这里** —— `plan()` 只是把
/// 请求转给 [LedgerPlanner]，那边一行都不写。
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

import 'package:fus_inbox/core/proxy/identity_binding.dart';
import 'package:fus_inbox/core/proxy/identity_plan.dart';
import 'package:fus_inbox/core/proxy/proxy_config.dart';

// 值类型和决策器在这里转出去，引用方（界面、provider、测试）只认这一个入口。
export 'package:fus_inbox/core/proxy/identity_binding.dart';
export 'package:fus_inbox/core/proxy/identity_plan.dart';

/// 账本。纯逻辑，不碰磁盘不碰网络。
class IdentityLedger {
  // 带初始化列表 + 非 this 参数，主构造器表达不了。
  // ignore: use_primary_constructors
  IdentityLedger({
    Map<String, IdentityBinding>? bindings,
    Map<String, String>? owners,
    this.maxPerIdentity = 3,
  }) : _bindings = {...?bindings},
       _owners = {...?owners};

  final Map<String, IdentityBinding> _bindings;

  /// **号码 → 看过它的那个出口的 id。**
  ///
  /// 这是「一个号对应一个出口 + 一个身份」的唯一权威来源。
  ///
  /// 以前没有这张表，只能反过来扫 `bindings` 的 `openedNumbers` 猜
  /// 「谁看过它」—— 而一个号可能挂在多个绑定上（A 看过、换到 B 之后
  /// B 又看了一次），猜法必然不准：用户切回一个**已经验证过**的号时，
  /// 被拉到 A 而 A 的站点密钥早就清掉了，看起来就是「身份变成新的」。
  ///
  /// 现在每次 [commit] 都写死「这个号归这条出口」，之后 [plan] 直接查表，
  /// 不猜。
  final Map<String, String> _owners;

  /// 号码 → 出口 id。只读视图。
  Map<String, String> get owners => Map.unmodifiable(_owners);

  /// 这个号归哪条出口。没看过就返回 null。
  String? ownerOf(String numberId) => _owners[numberId];

  /// 一个身份最多看几个号。实测站点给新号额度是 3。
  final int maxPerIdentity;

  Map<String, IdentityBinding> get bindings => Map.unmodifiable(_bindings);

  IdentityBinding? forProxy(String proxyId) => _bindings[proxyId];

  /// 这个出口已经用掉几个号。
  int usedFor(String proxyId) => _bindings[proxyId]?.used ?? 0;

  /// 决定这次打开该用哪个代理、哪个身份。
  ///
  /// 判断规则**全在** [LedgerPlanner]（它只读、不写）；这里是账本对外的
  /// 入口，顺手把当前绑定表和上限交过去。参数含义见那边的 `plan`。
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
  }) =>
      LedgerPlanner(
        bindings: _bindings,
        owners: _owners,
        maxPerIdentity: maxPerIdentity,
      ).plan(
        pool: pool,
        currentProxyId: currentProxyId,
        numberId: numberId,
        mintUserAgent: mintUserAgent,
        mintModel: mintModel,
        mintChromeMajor: mintChromeMajor,
        unusable: unusable,
      );

  /// 记下这次打开。
  ///
  /// 同一个号重复打开不会重复入账 —— 否则用户来回看同一个号
  /// 会把额度白白耗光。
  void commit(String proxyId, String numberId, IdentityBinding binding) {
    // 这个号归这条出口 —— **每次都写**，覆盖上一次的归属。
    //
    // 覆盖是对的：同一个号被 B 出口重新看过之后，它就归 B 了。
    // 用户再点它时应该回到 B 那个身份，而不是最早看过它的 A。
    if (numberId.isNotEmpty) _owners[numberId] = proxyId;
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
  /// 清掉某个出口的绑定，**连同挂在它名下的号**。
  ///
  /// 不清表的话，那些号会指向一个已经不存在的出口 —— 用户点它们时
  /// `plan` 查不到绑定，行为就飘了。
  void clearProxy(String proxyId) {
    _bindings.remove(proxyId);
    _owners.removeWhere((_, owner) => owner == proxyId);
  }

  void clearAll() {
    _bindings.clear();
    _owners.clear();
  }

  /// `plan` 和 `ProxyNotifier.rotateToNext` 共用同一条挑选规则。
  /// 实现见 [LedgerPlanner.nextUsableProxy]（池子空时返回 null）。
  ProxyConfig? nextUsableProxy(List<ProxyConfig> pool, String currentId) =>
      LedgerPlanner(
        bindings: _bindings,
        owners: _owners,
        maxPerIdentity: maxPerIdentity,
      ).nextUsableProxy(pool, currentId);

  Map<String, Object?> toJson() => {
    'maxPerIdentity': maxPerIdentity,
    'bindings': _bindings.map((k, v) => MapEntry(k, v.toJson())),
    'owners': _owners,
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
    // 老版本存盘里没有 `owners` —— 那就从 `openedNumbers` 重建一份
    // （一个号挂多个绑定时取最后写入的那个，和 commit 的覆盖语义一致）。
    final owners = <String, String>{};
    final rawOwners = raw['owners'];
    if (rawOwners is Map) {
      for (final e in rawOwners.entries) {
        final k = e.key?.toString() ?? '';
        final v = e.value?.toString() ?? '';
        if (k.isNotEmpty && v.isNotEmpty) owners[k] = v;
      }
    } else {
      for (final b in out.values) {
        for (final n in b.openedNumbers) {
          owners[n] = b.proxyId;
        }
      }
    }
    return IdentityLedger(
      bindings: out,
      owners: owners,
      maxPerIdentity:
          int.tryParse(raw['maxPerIdentity']?.toString() ?? '') ?? 3,
    );
  }
}
