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
class const LedgerPlanner({
  required this.bindings,
  required this.maxPerIdentity,
}) {
  /// 账本里的绑定表：代理 id -> 那个出口上绑着的身份。
  final Map<String, IdentityBinding> bindings;

  /// 一个身份最多看几个号。
  final int maxPerIdentity;

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

  /// 哪个绑定已经看过这个号。没有就返回 null。
  ///
  /// 多个绑定都看过时取**最早创建**的那个 —— 正常情况下一个号只会
  /// 落在一个绑定上（commit 只在代理真设成之后才写），这里只是兜底，
  /// 取个确定的顺序，免得行为飘。
  IdentityBinding? _bindingSeeing(String numberId) {
    IdentityBinding? found;
    for (final b in bindings.values) {
      if (!b.hasSeen(numberId)) continue;
      if (found == null || b.createdAtMs < found.createdAtMs) found = b;
    }
    return found;
  }

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
    final owner = _bindingSeeing(numberId);
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
    //
    // 这**就是 rotate**，别标成 reuse。判据不是「出口换没换」，是
    // 「这个 binding 是现造的还是账本里已有的」：这里造的是全新设备，
    // 浏览器必须换成它、而且必须清掉旧密钥 —— _applyProxyPlan 的 rotate
    // 分支做的正是这两件事。标成 reuse 会被当成「什么都不用做」放过去，
    // 结果是账本记下新设备、页面还挂着上一条出口的旧身份和旧密钥：
    // 既没换成新设备，新出口又白吃一次「同一个人换条线路」的信号。
    if (existing == null) {
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

    // 候选里已经没有**别的**出口了。
    //
    // 两个来源：只配了一条代理（`_nextProxy` 开头的 `pool.length == 1`），
    // 或者整池用满后回落到 `pool[start % pool.length]` 正好又是当前这条。
    //
    // 这时**绝不能返回 rotate**，两个理由都致命：
    //
    //   1. rotate 会让 `_applyProxyPlan` 走 `clearBrowsingData()` + 造新身份，
    //      而出口 IP 一个都没变 —— 正是本文件开头说的「同一个 IP 上冒出
    //      第二台」，站点眼里最扎眼的信号。
    //   2. reason 还会宣称「换代理 X」，可 X 就是当前这一条。用户在界面上
    //      看到「换到新出口」，实际什么都没换，只是额度又少一个。
    //
    // 触发面比「用户只配一条」大得多：候选是 `usable.isNotEmpty ? usable : pool`，
    // 用户点一次「全部检测」，只要这批公共代理里只剩一条通的，候选就变成 1，
    // 之后每个第 4 个号都在这个烂 IP 上换一台「新设备」。
    //
    // 如实退回 reuse：不换身份、不清数据，把真正的问题说出来。
    if (nextProxy.id == current.id) {
      return OpenPlan(
        action: OpenAction.reuse,
        proxy: current,
        binding: existing,
        reason:
            '当前出口已用满 $maxPerIdentity 个号，但没有别的可用出口 —— '
            '去设置里加代理，或换个网络再开',
      );
    }

    final carried = bindings[nextProxy.id];
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
    final binding = _mint(
      nextProxy.id,
      mintUserAgent: mintUserAgent,
      mintModel: mintModel,
      mintChromeMajor: mintChromeMajor,
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
      if (b.used < maxPerIdentity) partial ??= p;
    }
    if (partial != null) return partial;
    // 全满了。退回「下一条」，至少不会原地卡住 —— 真到这一步说明
    // 池子的额度整个用完了，该提醒用户加代理。
    // **绝不能退回当前这一条。**
    //
    // 原来这里是 `pool[start % pool.length]` —— 池子全满时「退回下一条」，
    // 可那一条可能恰好就是 `currentId`。于是 `plan` 里
    // `nextProxy.id == current.id` 成立，退回 `reuse` 并宣称「没有别的
    // 可用出口」—— 用户看到的就是「到了上限有时候不换代理」。
    //
    // 池子只有 3 条、每条上限 3 个号时**最容易走到这一步**：
    // 3×3=9 个号之后整池全满，之后每次开新号都落在这个兜底里。
    //
    // 真正的答案取决于调用方要什么：
    //   - `plan`：全满时应该如实说「池子用完了」，所以给回 current 让它
    //     走 reuse 分支报出那句提示 —— **但那必须是真的全满，不是挑错**。
    //     这里改成「在池里找一条不是 current 的」，找得到就给，找不到才
    //     给 current。
    //   - 这样 `plan` 的 `nextProxy.id == current.id` 就只会在「池里真的
    //     只有这一条」时成立，那句话才是真话。
    final fallback = pool.where((p) => p.id != currentId).firstOrNull;
    return fallback ?? pool[start % pool.length];
  }

  /// `plan` 和 `ProxyNotifier.rotateToNext` 共用同一条挑选规则。
  ///
  /// 两条路径必须一致：`plan` 管「开新号时当前出口满了」，`rotateToNext`
  /// 管「站点报限额时自动换」。之前只修了前者，后者还是纯 +1 —— 于是
  /// 恰恰在最需要跳过的场合（出口刚被限额烧掉）又落回一条用满的出口。
  ProxyConfig? nextUsableProxy(List<ProxyConfig> pool, String currentId) {
    if (pool.isEmpty) return null;
    return _nextProxy(pool, currentId);
  }
}
