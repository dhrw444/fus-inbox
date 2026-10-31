/// 开号决策：这次该用哪条出口、哪个身份。
///
/// ## 为什么从 `identity_ledger.dart` 拆出来
///
/// 那边（`IdentityLedger`）回答的是「**已经**记下了什么」—— 读写绑定表、
/// 落盘、记账。这里回答的是「**接下来**该做什么」—— 只读绑定表，产出一个
/// [OpenPlan]，一个字都不写。
///
/// 混在一起时 `plan()` 的 170 多行判断夹在 `commit` / `fromJson` 之间，
/// 改落盘格式要先翻过一个完全不相干的决策树。拆开之后两边各自能单独读，
/// 而且决策器只吃「绑定表 + 上限」两个输入，谁都能拿一组假绑定跑。
///
/// ## 决策器不持有任何状态
///
/// [bindings] 是**借用**账本那份映射（`IdentityLedger.plan()` 直接把自己的
/// `_bindings` 递过来），不是拷贝。`plan()` 全程同步执行，中途不会有人改它；
/// 决策器自己一个字都不写，落账由 `IdentityLedger.commit` 负责。
library;

import 'package:fus_inbox/core/proxy/identity_binding.dart';
import 'package:fus_inbox/core/proxy/proxy_config.dart';

/// 账本的决策器。纯逻辑，不碰磁盘不碰网络。
class const LedgerPlanner({required this.bindings, required this.owners}) {
  /// 账本里的绑定表：代理 id -> 那个出口上绑着的身份。
  final Map<String, IdentityBinding> bindings;

  /// 号码 → 出口 id 的确定映射（见 `IdentityLedger.owners`）。
  ///
  /// 有它就不用扫 `bindings` 猜「谁看过这个号」了 —— 猜法在一个号挂在
  /// 多个绑定上时必然不准。
  final Map<String, String> owners;

  /// 在某条出口上铸造一个全新身份：UA / 型号 / Chrome 版本都现造，
  /// 看过的号从零数起。mint 回调由调用方注入，决策器不管熵从哪来。
  IdentityBinding _mint(
    String proxyId, {
    required String Function() mintUserAgent,
    required String Function() mintModel,
    required String Function() mintChromeMajor,
  }) => IdentityBinding(
    proxyId: proxyId,
    userAgent: mintUserAgent(),
    model: mintModel(),
    chromeMajor: mintChromeMajor(),
    openedNumbers: const [],
    createdAtMs: DateTime.now().millisecondsSinceEpoch,
  );

  /// 决定这次打开该用哪个代理、哪个身份。
  ///
  /// [pool] 是代理池（内置 + 手加），[currentProxyId] 是当前选中的代理，
  /// [numberId] 是这次要看的号。
  ///
  /// [unusable] 是检测已判死的代理 id，会被排除在候选外 —— 但只
  /// 在还剩别的可选时才排，见下面的注释。
  ///
  /// 不会修改账本 —— 落账由 `IdentityLedger.commit` 做，这样界面可以先把
  /// 决定显示出来再执行。
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
      final binding = _mint(
        '',
        mintUserAgent: mintUserAgent,
        mintModel: mintModel,
        mintChromeMajor: mintChromeMajor,
      );
      return OpenPlan(
        action: OpenAction.reuse,
        proxy: directProxy(),
        binding: binding,
        reason: '没配代理，走直连',
      );
    }

    final existing = bindings[current.id];

    // 这个号之前是谁看的？必须回到那条出口、那个身份。
    //
    // 站点把「看过哪些号」记在 reader 身份自己的 localStorage /
    // IndexedDB 里 —— 24 小时内重看同一个号是放行的，不扣额度。
    // 换个身份再进来，它不知道你看过，直接当成全新收件箱：既吃一次
    // 新额度，又更容易撞人机验证。
    //
    // 之前这里只查 bindings[current.id]，轮换过之后回头点老号必然
    // 落到新身份上 —— 就是「重新点进去不是之前那条 socks5 + 身份」。
    // 这个号归哪条出口 —— **直接查表，不猜**。
    //
    // 以前是扫 `bindings` 的 `openedNumbers` 猜「谁看过它」，一个号挂在
    // 多个绑定上时必然猜错。现在 `commit` 每次都写死归属，这里查就完了。
    final ownerProxyId = owners[numberId];
    final owner = ownerProxyId == null ? null : bindings[ownerProxyId];
    if (owner != null) {
      // 这个号有归属身份。**要不要切回去，分两种情况** ——
      // 原来只判 `owner.proxyId != current.id`，漏了第二种。
      //
      // 第一种：owner 就在当前出口上，而且当前绑定**就是** owner。
      //   那就什么都不用做 —— 直接落到下面的 reuse 分支（它只保证 UA 一致）。
      //   这是最常见的路径：同一个身份重开同一个号，站点 24 小时内放行。
      //
      // 第二种：owner 在别的出口上，**或者** owner 不是当前绑定
      //   （浏览器此刻装的是另一台设备）。这两种都必须真的切回 owner ——
      //   reuse 分支只保证「UA 和账本一致」，它**不会**把绑定换成 owner。
      //   站点眼里这个号仍然算新访客：既吃一次额度，又更容易撞验证。
      //
      // 归属身份的全部价值就在「它看过这个号」：密钥和本地记录都在它身上。
      // 换个身份再进来，那两条全丢。
      // 同一个绑定用 `createdAtMs` 认（[IdentityBinding] 没有 id 字段，
      // `_bindingSeeing` 也是按它挑最早的那个）。
      final sameSlot =
          owner.proxyId == current.id &&
          existing != null &&
          existing.createdAtMs == owner.createdAtMs;
      if (!sameSlot) {
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
        // 那条出口不在候选里。这里要再分两种，**不能一把都 restore**：
        //
        //   - 出口还在池子里（只是这次候选把它剔了，比如检测暂时判死）：
        //     切回那个身份 —— 它的密钥和「已读记录」都还在，站点认得它。
        //     出口仍用当前这条（保证有网可走）。站点眼里「同一台设备换了条
        //     线路」比「一台全新的设备」轻得多。
        //
        //   - 出口**已经被删了**（不在 pool 里）：别 restore。切回一个连出口都
        //     不存在的身份没有意义 —— 账本里那条绑定再也走不了那个 IP，硬套它
        //     的 UA 只会让「账本说 A、实际走 B」更乱。这种情况正常走当前出口的
        //     身份（后面的分支会处理），让用户自己决定要不要加回那条代理。
        final ownerInPool = pool.any((p) => p.id == owner.proxyId);
        if (ownerInPool) {
          return OpenPlan(
            action: OpenAction.restore,
            proxy: current,
            binding: owner,
            reason: '这个号是别的出口上的身份看过的，切回那个身份复用',
          );
        }
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

    // 有绑定 → 一直复用。
    //
    // **这里不数「已经看了几个号」。** 本地没有额度上限：站点从不告诉你
    // 上限是几、已用几（`SITE.md:157`：没有任何配额头、没有计数字段），
    // 自己猜一个数字只会把站点还愿意给的额度白白扔掉 —— 多换一次出口
    // 就是多烧一个身份、多一次「同一个人换线路」的信号。
    //
    // 什么时候该换由站点说：`429 X-Fair-Use: pause`（新号额度）或
    // `403 challenge`。那条路径在 `IdentityRotator._maybeAutoRotateBody`。
    if (existing != null) {
      return OpenPlan(
        action: OpenAction.reuse,
        proxy: current,
        binding: existing,
        reason: '复用当前出口的身份（已看 ${existing.used} 个号，站点没拒就继续）',
      );
    }

    // 没绑定 → 在这个代理上造一个新身份。
    //
    // 这**就是 rotate**，别标成 reuse。判据不是「出口换没换」，是
    // 「这个 binding 是现造的还是账本里已有的」：这里造的是全新设备，
    // 浏览器必须换成它、而且必须清掉旧密钥 —— _applyProxyPlan 的 rotate
    // 分支做的正是这两件事。标成 reuse 会被当成「什么都不用做」放过去，
    // 结果是账本记下新设备、页面还挂着上一条出口的旧身份和旧密钥：
    // 既没换成新设备，新出口又白吃一次「同一个人换条线路」的信号。
    final binding = _mint(
      current.id,
      mintUserAgent: mintUserAgent,
      mintModel: mintModel,
      mintChromeMajor: mintChromeMajor,
    );
    return OpenPlan(
      action: OpenAction.rotate,
      proxy: current,
      binding: binding,
      reason: '这条出口上还没有身份，绑一个新的',
    );
  }

  /// 池里下一条代理（换出口时用）。
  ///
  /// 之前这里只是 `pool[(idx + 1) % pool.length]` —— 纯粹的 +1，不看
  /// 下一条是不是已经绑过身份。落到一条绑过的出口上又造新身份，等于
  /// 同一个 IP 上冒出第二台设备，站点眼里最扎眼；那个 IP 上更容易
  /// 直接弹 CF 验证 —— 就是「有的时候会 cf 验证错误」的来源之一。
  ///
  /// 挑的顺序是两轮，不能反：
  ///   1) 没绑过身份的出口 —— 在上面开一个新身份，正是「一代理一身份」
  ///   2) 绑过的出口 —— 复用它已有的身份，不造新的
  ///
  /// 之所以优先找没绑过的：落在一条已经绑过的出口上又造新身份，等于
  /// 同一个 IP 上出现两台设备；而只认没绑过的又会在池子用旧之后无路
  /// 可走，所以留第二轮兜底。
  ///
  /// 轮转而不是随机：代理池通常按顺序配的，随机容易连着撞同一条。
  ProxyConfig _nextProxy(List<ProxyConfig> pool, String currentId) {
    if (pool.isEmpty) return directProxy();
    if (pool.length == 1) return pool.first;
    final idx = pool.indexWhere((p) => p.id == currentId);
    final start = idx < 0 ? 0 : idx + 1;

    ProxyConfig? partial;
    for (var i = 0; i < pool.length; i++) {
      final p = pool[(start + i) % pool.length];
      if (p.id == currentId) continue;
      final b = bindings[p.id];
      if (b == null) return p;
      partial ??= p;
    }
    if (partial != null) return partial;
    // 池里每一条别的出口都已经绑了身份 —— 也照样得给一条。
    // **绝不能退回当前这一条。**
    //
    // 原来这里是 `pool[start % pool.length]`，可那一条可能恰好就是
    // `currentId`：调用方拿到「还是我自己」，就会以为没得换，
    // 从而什么都不做 —— 用户看到的就是「被拒了却一直不换出口」。
    //
    // 这里改成「在池里找一条不是 current 的」，找得到就给，找不到
    // 才给 current。这样调用方判「是不是我自己」时，结论才是真的。
    final fallback = pool.where((p) => p.id != currentId).firstOrNull;
    return fallback ?? pool[start % pool.length];
  }

  /// 换出口时的挑选规则（`ProxyNotifier.rotateToNext` 走这条）。
  ///
  /// 和 [plan] 共用 [_nextProxy]，所以「优先没绑过的、其次绑过的」
  /// 两轮顺序只有一处定义 —— 以前是两处各写一遍，改一处忘另一处
  /// 就会在最需要跳过的场合落回一条烧掉的出口。
  ProxyConfig? nextUsableProxy(List<ProxyConfig> pool, String currentId) {
    if (pool.isEmpty) return null;
    return _nextProxy(pool, currentId);
  }
}
