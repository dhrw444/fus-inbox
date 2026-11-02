/// 代理 ↔ 身份 ↔ 号码 的账本：**存**下「哪个出口用了哪个身份、看过哪些号」。
///
/// 值类型见 `identity_binding.dart`；开号决策见 `identity_plan.dart`
/// （都在这里转出去，引用方不用多写一行 import）。本文件只管存储与记账：
/// 绑定表的读写、`commit`、落盘 JSON。**决策不在这里** —— `plan()` 只是把
/// 请求转给 [LedgerPlanner]，那边一行都不写。
///
/// ## 规则
///
/// 一个代理配置绑定一个浏览器身份；**本地不数「看了几个号」**。
/// 开号一律复用当前出口上的身份，直到站点自己说「不给新的了」
/// （`429 X-Fair-Use: pause` / `403 challenge`，见 `SITE.md` §5）。
/// 那时换代理**并**换身份，重新开始。
///
/// ## 为什么不在本地设上限
///
/// 站点从不告诉你「上限是几个、已用几个」（`SITE.md:157`：没有任何配额
/// 头、没有计数字段）。本地猜一个数字，猜小了就是白白扔掉站点还愿意给的
/// 额度 —— 比如本地按 3 个换，而站点实际还愿意给第 4、第 5 个。
/// 多换一次出口 = 多烧一个身份、多一次「同一个人换线路」的信号。
///
/// 所以判据交给站点：它给，就继续用；它拒，才换。
///
/// ## 为什么是「代理 + 身份」一起换
///
/// 单独换任何一个都不行：
///
/// - 只换身份（清 localStorage / IndexedDB / cookie，UA 换新）：
///   下一个号照样 `New inboxes are on pause`。配额记在出口 IP 上。
/// - 只换代理：站点的 reader 身份还是那对 ECDSA 密钥，服务端认得
///   这是同一个人换了个出口 —— 更像是「有人在绕」而不是新访客。
///
/// 两个一起换才是完整的「新访客」：新出口 + 新密钥。
///
/// ## 为什么身份要缓存而不是每次现造
///
/// 同一个代理上反复造新身份会让这个出口迅速积累一堆半死的身份。
/// 缓存住，一直用同一个 —— 这也更接近真实用户行为。
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
    Map<String, int>? burned,
  }) : _bindings = {...?bindings},
       _owners = {...?owners},
       _burned = {...?burned};

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

  /// **烧着的出口：出口 id → 到期时刻（epoch ms）。**
  ///
  /// 站点把新号额度记在出口 IP 上（`429 X-Fair-Use: pause`，见 `SITE.md` §5）。
  /// 某条出口撞墙之后，[plan] 会把用户拉回它 —— 因为账本里那些号仍然写着
  /// 「归它所有」（`_owners`）。于是点「换出口并重置身份」换到 B，下一次
  /// 点开同一个号时又切回 A：**界面说换了出口，实际回到了那条已经烧掉的**。
  ///
  /// 这张表补的就是那条判据：到期之前，烧着的出口既不被当作归属切回、
  /// 也不进候选。**到期自动失效，不用人清** —— 站点的暂停本来就会自愈，
  /// 只是没人知道确切的到期时刻，所以由调用方把自己知道的那个窗口填进来。
  final Map<String, int> _burned;

  /// 号码 → 出口 id。只读视图。
  Map<String, String> get owners => Map.unmodifiable(_owners);

  /// 这个号归哪条出口。没看过就返回 null。
  String? ownerOf(String numberId) => _owners[numberId];

  Map<String, IdentityBinding> get bindings => Map.unmodifiable(_bindings);

  IdentityBinding? forProxy(String proxyId) => _bindings[proxyId];

  /// 这个出口已经用掉几个号。
  int usedFor(String proxyId) => _bindings[proxyId]?.used ?? 0;

  /// 决定这次打开该用哪个代理、哪个身份。
  ///
  /// 判断规则**全在** [LedgerPlanner]（它只读、不写）；这里是账本对外的
  /// 入口，顺手把当前绑定表和归属表交过去。参数含义见那边的 `plan`。
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
  }) => LedgerPlanner(
    bindings: _bindings,
    owners: _owners,
    burned: burnedNow(),
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
    // **空 id 不记。**
    //
    // 换身份那条路（`_rotateIdentityBody`）调 `commitOpen(proxyId, '', ...)`
    // —— 意思是「只建了身份，还没看号」。`''` 若进了 `openedNumbers`，
    // 它**白占一个额度**（`used = openedNumbers.length`），用户 3 个号变 2 个。
    //
    // 这不是假想：每点一次「换浏览器身份」就多占一个，连着点两次额度就没了。
    if (numberId.isNotEmpty && !nums.contains(numberId)) nums.add(numberId);
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

  /// 记下「这条出口撞墙了」。[untilMs] 之后自动失效。
  ///
  /// 空 id（直连）不记：直连没有「换一条出口」这回事，把它烧了只会让
  /// 整池都被剔掉。
  void burn(String proxyId, {required int untilMs}) {
    if (proxyId.isEmpty) return;
    _burned[proxyId] = untilMs;
  }

  /// 这条出口此刻是不是还烧着。
  bool isBurned(String proxyId, {int? nowMs}) {
    final until = _burned[proxyId];
    if (until == null) return false;
    return until > (nowMs ?? DateTime.now().millisecondsSinceEpoch);
  }

  /// 人工解封（比如用户自己知道那条出口又能用了）。
  void clearBurn(String proxyId) => _burned.remove(proxyId);

  /// 此刻还烧着的出口 id。**顺手剔掉已过期的** —— 不剔的话这张表只增
  /// 不减，换过一百次出口之后落盘里就攒着一百条死记录。
  Set<String> burnedNow({int? nowMs}) {
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    _burned.removeWhere((_, until) => until <= now);
    return _burned.keys.toSet();
  }

  void clearAll() {
    _bindings.clear();
    _owners.clear();
    _burned.clear();
  }

  /// `plan` 和 `ProxyNotifier.rotateToNext` 共用同一条挑选规则。
  /// 实现见 [LedgerPlanner.nextUsableProxy]（池子空时返回 null）。
  ProxyConfig? nextUsableProxy(List<ProxyConfig> pool, String currentId) =>
      LedgerPlanner(
        bindings: _bindings,
        owners: _owners,
        burned: burnedNow(),
      ).nextUsableProxy(pool, currentId);

  /// 只存绑定表、归属表和烧表。
  ///
  /// 老版本还会写一个 `maxPerIdentity` —— 那是本地自己数的额度上限，
  /// 已经删掉了（判据交给站点，见文件头）。新代码读到它一律忽略，
  /// 不报错：老盘面要能照常打开。
  Map<String, Object?> toJson() => {
    'bindings': _bindings.map((k, v) => MapEntry(k, v.toJson())),
    'owners': _owners,
    // 烧表要落盘：用户重启 App 之后「这条出口刚刚撞过墙」仍然成立 ——
    // 不落盘的话重启就把烧痕抹了，点同一个号又会被拉回那条出口。
    'burned': _burned,
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
    // 烧表：老盘面里没有这一项，读到就按「一条都没烧」处理 ——
    // 老盘面要能照常打开（和 `owners` 的兼容规则一样）。
    final burned = <String, int>{};
    final rawBurned = raw['burned'];
    if (rawBurned is Map) {
      for (final e in rawBurned.entries) {
        final k = e.key?.toString() ?? '';
        final until = int.tryParse('${e.value}');
        if (k.isNotEmpty && until != null) burned[k] = until;
      }
    }
    return IdentityLedger(bindings: out, owners: owners, burned: burned);
  }
}
