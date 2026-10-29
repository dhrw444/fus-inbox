/// 「什么时候该换出口 / 换身份、换了之后要清什么」。
///
/// 从 `inbox_screen.dart` 里整块搬出来的：原来那七个方法散在 1200 行的
/// State 里，和「把收件页画出来」是两件事，却互相够得到对方的状态
/// （看门狗、验证轮询、引擎的 onPageFinished 回调）。搬出来之后
/// **收件页只负责画，这里只负责补救会话**。
///
/// ## 边界画在哪
///
/// 依赖全部走构造函数：
///   - [store]（状态层）、[engine]（WebView）、[ref]（代理 provider）
///   - [isAlive]：页面还在不在。每次 await 之后都要问一次，和原来的
///     `if (!mounted) return;` 等价。
///   - [onPageDiscarded] / [onLoadStarted]：**必须由屏幕做**的两件事
///     （计时器归屏幕持有）：本页作废（清状态 + 重臂看门狗 + 停旧的
///     验证轮询）、新文档开始加载（重开验证轮 + 驱动）。
///   - [toast]：用户可见的吐司。状态栏那条在换身份时不够显眼。
///
/// ## 为什么不用 `part`
///
/// part 文件是独立编译单元，类的方法会变成顶层函数，看不到实例字段。
/// 这里的状态（[_rotating]、[_autoRotating] 那两个闸门）必须跟着实例走。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fus_inbox/core/log.dart';
import 'package:fus_inbox/core/proxy/identity_binding.dart';
import 'package:fus_inbox/core/proxy/proxy_engine_provider.dart';
import 'package:fus_inbox/core/proxy/proxy_provider.dart';
// 带 as identity 前缀：本类自己的方法就叫 [rotateIdentity]，不加前缀的话
// 类内 `rotateIdentity()` 会解析到**自己**，直接无限递归。
import 'package:fus_inbox/core/webview/browser_identity.dart' as identity;
import 'package:fus_inbox/core/webview/http_headers.dart';
import 'package:fus_inbox/core/webview/native_capabilities.dart';
import 'package:fus_inbox/features/inbox/application/inbox_provider.dart';
import 'package:fus_inbox/features/inbox/domain/identity_rotation_policy.dart';
import 'package:fus_inbox/features/inbox/domain/inbox_message.dart';
import 'package:fus_inbox/platform/web_engine.dart';

/// 换出口 / 换身份的控制器。
///
/// 一个 [InboxScreen] 一个实例，但**冷却器是进程级**的 —— 见
/// [_rotationPolicy] 和 [_lastProxyRotate] 上的注释。
class IdentityRotator({
  required this.ref,
  required this.store,
  required this.engine,
  required this.inboxUrl,
  required this.isAlive,
  required this.onPageDiscarded,
  required this.onLoadStarted,
  required this.toast,
}) {
  final WidgetRef ref;

  /// 收件页的状态层。换身份时要 `reset()` 它（上一轮的拒绝信号必须消掉，
  /// 否则 `hold` 还在，状态一变就又会触发一次轮换）。
  final InboxStore store;

  /// 这个页面的 WebView。清数据 / 换 UA / 重载都走它。
  final WebEngine engine;

  /// 收件页地址。换身份后要重新打开的就是它。
  final String inboxUrl;

  /// 页面还在不在。等价于原来的 `if (!mounted) return;`。
  final bool Function() isAlive;

  /// 本页作废：清状态 + 重臂看门狗 + 停掉旧的验证轮询。
  ///
  /// 由屏幕实现 —— 那几个计时器归屏幕持有，控制器不碰。
  final void Function() onPageDiscarded;

  /// 新文档开始加载：重开验证轮 + 驱动验证，计时从头算。
  final void Function() onLoadStarted;

  /// 给用户看的吐司。
  final void Function(String message) toast;

  /// 验证状态轮询。重置身份后置 true：等站点页加载完成，立刻删掉它的密钥。
  ///
  /// 不能提前删 —— about:blank 的 origin 和站点不同，碰不到站点的
  /// IndexedDB。也不能等站点自己发完请求再删，那时旧密钥已经用来
  /// 签名过了。所以卡在 onPageFinished 这一刻：
  /// 站点还没发首屏请求，文档已经就绪，删得掉。
  ///
  /// 屏幕在 `onPageFinished` 里用 [takeWipeOnLoad] 问一次，问完就清。
  bool _wipeOnLoad = false;

  /// 自动换身份的节流器。
  ///
  /// 一被限制就重置是错的做法：每次重置在站点眼里都是一个全新的
  /// 首次访客，连续重置等于「同一个 IP 一分钟来了十个新访客」，
  /// 比单个爬虫更显眼，还白耗 Turnstile 验证次数。
  ///
  /// **必须是 static（进程级）**：以前它是实例字段，而 InboxScreen 每点
  /// 一个号就 push 一个新实例（numbers_screen / saved_screen 都走
  /// MaterialPageRoute）—— 于是「配额触发后返回列表、再点下一个号」这条
  /// 最常见的动作把冷却直接清零，可以无限速地连烧身份和出口。上面那段
  /// 注释想防的事，本来就被这个实例作用域漏掉了。
  static final _rotationPolicy = IdentityRotationPolicy();

  /// 正在换出口/换身份。见 [maybeAutoRotate] —— 换的过程中会写状态，
  /// 状态一变又回调进来，没有这个闸门会自激。
  bool _rotating = false;

  /// [maybeAutoRotate] 的可重入闸。
  ///
  /// 必须有这一道：身体里任何一次写状态都会同步回调进
  /// `InboxStore.onChanged` → 又调回 [maybeAutoRotate]。
  ///
  /// 以前只有 [_rotating]，而它只在换出口那条路上设置；走「换身份」分支时
  /// 身体里第一句 `store.note(...)`（[rotateIdentity] 的同步段）就会回调
  /// 回来 → `canRotate` 刚被 `record` 打过必然为 false → `note(why)` →
  /// 再回调 → **纯同步无限递归**，几毫秒爆栈。换出口那条路没炸纯属
  /// [_rotating] 的巧合，不是设计。
  bool _autoRotating = false;

  /// 上一次因为配额换出口的时间。
  ///
  /// 单独记一份、而且比 [_rotationPolicy] 的 30 秒更长：换出口之后站点要
  /// 重新握手、重新验人机，这期间 hold 还是旧的，状态一变就又会
  /// 触发一次。真连着换下去会把整份池子在一分钟内烧穿 ——
  /// 而且每换一次在站点眼里都是「同一个 IP 又来一个新访客」的
  /// 反向操作（换出口不换 IP 是不可能的，但换太快本身也可疑）。
  ///
  /// 同 [_rotationPolicy]：**必须是 static**。停在这里就够的冷却，一旦
  /// 回到列表再点下一个号就归零，等于没设。
  static DateTime? _lastProxyRotate;

  /// 连续换了几次都没摆脱拒绝。
  ///
  /// 冷却只挡「换得太快」，挡不住「换了很多次仍然被拒」—— 那种情况
  /// 说明站点不是按 IP/身份拒的（整站维护、或者用户自己没网）。
  /// 继续换只会把代理池烧穿、把用户晾在转圈里。
  ///
  /// 真机上踩过：冷却只有 6 秒时 `hold` 一直不清 → 每 6 秒换一次 →
  /// 用户看到的就是「一直循环换身份」，连点都点不到。
  static int _consecutiveRotations = 0;

  /// 连续换这么多次还在被拒，就停下来让用户自己看。
  static const _maxConsecutiveRotations = 3;

  /// 两次换出口之间至少隔这么久。
  ///
  /// 一次换出口 ≈ 清数据 + 换 UA + 重载 + 站点重新握手，几秒钟。
  /// 冷却必须**明显长于**一次换出口的耗时，否则就是死循环：
  ///
  /// 换出口 → 站点还在重新握手、旧 `hold` 还没被新状态覆盖 →
  /// 状态一变又满足「被拒了」→ 再换一次 → 无限循环。
  ///
  /// 原来这里是 **6 秒**，比一次换出口（清数据 + 换 UA + 重载 +
  /// 重新握手 + 重新验人机）短得多，所以真机上就是「一直循环换身份」。
  /// 45 秒是给「新出口至少能完整试一次」留的余量。
  static const _proxyRotateCooldown = Duration(seconds: 45);

  /// 引擎在 `onPageFinished` 里问一次：这一趟加载完是不是该删站点密钥。
  ///
  /// 只认第一次 —— 读走就清。不能做成 getter：站点一次重定向会连着
  /// 触发多次 pageFinished，留着它就会在后续文档上反复删库重载。
  bool takeWipeOnLoad() {
    if (!_wipeOnLoad) return false;
    _wipeOnLoad = false;
    return true;
  }

  /// 站点一拒绝就换身份。
  ///
  /// 只在「会话坏了」和「服务端临时繁忙」时自动换身份。
  ///
  /// 配额和挑战**不**自动换 —— 它们记在 IP 上，换身份是白烧一次
  /// 新身份（实测：同一 IP 清空 localStorage / IndexedDB / cookie
  /// 之后，第 4 个号依然 New inboxes are on pause）。这两种把
  /// 「换 IP 后重置浏览器」摆到界面上，由用户决定什么时候换。
  ///
  /// 节流是为了别把新身份一次性打光：刚换完立刻又撞墙，
  /// 那个身份就白扔了。
  ///
  /// 这里只是可重入闸；真正的判定在 [_maybeAutoRotateBody]，见
  /// [_autoRotating]。
  void maybeAutoRotate() {
    if (_autoRotating) return;
    _autoRotating = true;
    try {
      _maybeAutoRotateBody();
    } finally {
      _autoRotating = false;
    }
  }

  void _maybeAutoRotateBody() {
    if (_rotating) return;
    final hold = store.state.hold;
    final status = store.state.status;
    // 没有任何拒绝信号就不动。
    if (hold == null && !status.contains('reader_verification')) {
      // 状态干净了 —— 这一轮真的摆脱了拒绝。
      //
      // 必须在这里归零：否则换满 [_maxConsecutiveRotations] 次之后
      // 就永久卡死，用户之后再被拒也换不动了。
      _consecutiveRotations = 0;
      return;
    }

    // 配额和挑战都是 **IP 级** 的，换浏览器身份解决不了 ——
    // 实测：同一个 IP 上清空 localStorage / IndexedDB / cookie（等于换
    // 全新身份）之后，第 4 个号依然是 New inboxes are on pause。
    //
    // 但「换 IP」是 App 自己能做的事：代理池里还有别的出口就直接
    // 换下一条，连身份一起重置（只换一样站点都还认得出是同一个人）。
    // 池子空或只剩一条时才退化成让用户自己换 IP。
    // 连续换了很多次还是被拒 —— 停手。
    //
    // 这不是「再试一次就好」：站点要么在维护、要么按别的东西在拒
    // （不是 IP 也不是身份）。继续换只会把池子烧穿、让界面一直转圈。
    if (_consecutiveRotations >= _maxConsecutiveRotations) {
      store.note(
        '已经连换 $_maxConsecutiveRotations 次还是被拒，先停下。'
        '换个网络、或过一会儿再试。',
      );
      return;
    }

    if (hold?.kind == SiteHoldKind.quota ||
        hold?.kind == SiteHoldKind.challenge) {
      if (!ref.read(proxyProvider).autoRotate) return;
      final now = DateTime.now();
      final last = _lastProxyRotate;
      if (last != null && now.difference(last) < _proxyRotateCooldown) return;
      // 池子里真没得换就**不许 discard**：[_rotateToNextProxy] 内部那个
      // 同款检查在 `_rotateIdentityBody` → `onPageDiscarded()` 之后才到，
      // 而 discard 会 `store.reset()` 清掉 hold —— 配额卡片整个消失，
      // 提示只剩骨架屏头部一行小字。用户点了「换 IP 后重置浏览器」，
      // 页面反而从一张说得清状况的卡片变成一张空白骨架。先判后动。
      if (!ref.read(proxyProvider).canRotate) {
        store.note('代理池里没有别的出口可换，需要你换个网络再点重置。');
        return;
      }
      // **计数和冷却时间戳都不在这里加。**
      //
      // 原来加在这里，也就是「还没真正换」之前 —— 而 `_rotateToNextProxy`
      // 里 `apply(next)` 可能失败（新出口握手失败）就直接 return，
      // 什么都没换，计数却已经 +1、45 秒冷却也已经起算。
      //
      // 后果：自动换出口失败一次，接下来 45 秒内**连手动重载都不再触发**
      // 自动换 —— 页面停在旧会话上，用户只有一行状态字可看。
      //
      // 现在挪到真正换成功之后（见 `_rotateToNextProxy` / `_rotateIdentityBody`）。
      unawaited(_rotateToNextProxy());
      return;
    }

    // 已经在这个身份上换过一次还没缓过来，就别连着换。
    final now = DateTime.now();
    final (ok, why) = _rotationPolicy.canRotate(now);
    if (!ok) {
      store.note(why);
      return;
    }
    _rotationPolicy.record(now);
    unawaited(rotateIdentity());
  }

  /// 换下一条代理 + 重置浏览器身份。
  ///
  /// 两步必须都做：只换 IP，站点的 reader 密钥还是那一对，服务端认得
  /// 这是同一个人换了个出口；只换身份，配额还记在同一个 IP 上。
  ///
  /// 没得换时（池空 / 只剩一条可用）就什么都不做，界面上的
  /// 「换 IP 后重置浏览器」还留着，由用户自己换。
  Future<void> _rotateToNextProxy() async {
    _rotating = true;
    try {
      final notifier = ref.read(proxyProvider.notifier);
      if (!ref.read(proxyProvider).canRotate) {
        store.note('代理池里没有别的出口可换，需要你换个网络再点重置。');
        return;
      }
      final next = await notifier.rotateToNext();
      if (next == null || !isAlive()) return;

      // 出口要先换掉。rotateIdentity 最后会打开收件页，那一下的流量
      // 必须已经走新出口 —— 晚一步就是拿旧 IP 又去撞一次限额。
      final active = await ref.read(proxyEngineProvider).apply(next);
      if (!isAlive()) return;
      if (!active.ok && !next.isDirectProxy) {
        store.note('换到 ${next.displayName} 没设上：${active.detail}。');
        return;
      }
      store.note('配额用满，换到 ${next.displayName}（${active.detail}）。');

      // 出口**真的换成了**才起算冷却。见上面那段说明。
      _lastProxyRotate = DateTime.now();
      // 直调 body：本方法已经持有 [_rotating] 了。走公开的
      // [rotateIdentity] 会被它自己的闸门当成「正在换」直接 return，
      // 自动轮换就此失效 —— 而且失效得很安静。
      await _rotateIdentityBody();
    } finally {
      _rotating = false;
    }
  }

  /// 换一个浏览器身份并重新打开收件页。
  ///
  /// ## 只换 UA 是没用的
  ///
  /// 站点把访客身份绑在一对 **ECDSA 密钥**上，密钥存在 IndexedDB
  /// `fus-reader-v1`，每次请求的 `X-FUS-Proof` 都用它签名。
  /// 上一版这里只做了 `setUserAgent` + reload：UA 变了，密钥没变，
  /// 服务端认出的还是同一个访客 —— 换了个马甲而已，
  /// 配额、限流、信誉全都跟着走。
  ///
  /// 真正的「换一个浏览器」必须把这四样一起清掉：
  ///   1. cookie（含 HttpOnly 的 cf_clearance）
  ///   2. localStorage / sessionStorage
  ///   3. IndexedDB（那对密钥）
  ///   4. UA
  ///
  /// 然后重新加载，站点会当成全新访客，重新生成密钥对。
  ///
  /// **不碰 App 自己的数据**：号码目录缓存、收录时间、译文缓存
  /// 都存在 SharedPreferences 里，和 WebView 的站点数据完全隔离。
  ///
  /// ## 重入闸
  ///
  /// 这个方法是 AppBar 上那个按钮的**直接**回调（`onRotateIdentity`），
  /// 用户连点两下就会并发跑两次：两次都清库、两次都换 UA、两次都导航，
  /// 结果是「清了 A 的数据、又按 B 的身份加载」，站点看到的是一个自相
  /// 矛盾的访客。所以闸门要开在入口这一层，不能只靠
  /// [_rotateToNextProxy] 里那个（那条路是自动触发的，走的不是同一个口）。
  Future<void> rotateIdentity() async {
    if (_rotating) return;
    _rotating = true;
    try {
      await _rotateIdentityBody();
    } finally {
      _rotating = false;
    }
  }

  Future<void> _rotateIdentityBody() async {
    // **先清 hold，再动手。**
    //
    // `onPageDiscarded()` 里也会 `store.reset()`，但它在函数**后半段**
    // （`loadUrl` 之前）。中间这一串 `await` 每次都会 `store.note()`，
    // 每次 note 都触发 `onChanged` → `maybeAutoRotate()`。此时旧的
    // `hold` 还在，于是又满足「被拒了」→ 再换一次 → 死循环。
    //
    // 真机上就是这个表现：一直循环换身份，用户根本来不及点。
    store.reset();
    store.note('正在重置浏览器身份…');

    try {
      // 分三步，顺序不能换：
      //
      // 1) 引擎清 cookie / WebStorage / HTTP 凭据：
      //    必须在导航前调：它清的是「这个 WebView 里所有站点的数据」，
      //    和当前文档在哪个页面无关；先清掉能保证 next 这次加载是
      //    一个没有 cookie 的请求。
      //
      // 2) 设新 UA。
      //
      // 3) 打开收件页，等它 onPageFinished 那一刻删 IndexedDB，
      //    然后再重载一次（见 [wipeThenReload]）。密钥必须卡在那个
      //    时间点删：about:blank 的 origin 碰不到站点库，
      //    而等站点自己发完请求再删，旧密钥已经用过了。
      final ok = await engine.clearSiteData();
      // 同上：旧证绑在旧 (IP, UA) 上，换完就是废纸。
      forgetClearance();

      final fresh = identity.rotateIdentity();
      await engine.setUserAgent(fresh.userAgent);
      // 立刻落盘。不存的话重启会回到设备真实机型，而站点那边的
      // reader 密钥还是这一对 —— 同一个身份换了台「设备」，比不换更扎眼。
      await persistCurrentIdentity();
      // **新身份必须写进账本。**
      //
      // 不写的话账本里这条出口还是空的：下次 `plan()` 看到
      // `bindings[current.id] == null`，就再 mint 一个新身份、再走一次 rotate
      // —— 用户感受是「换了身份，但下次开号又换一遍」，而且界面上的额度
      // 显示永远对不上实际在用的身份。
      //
      // `commitOpen` 原来只在「打开号码」那条路（inbox_screen）里调，换身份
      // 这条完全没写账。这里补上，`numberId` 传空串表示「只是建了身份、还没
      // 看号」—— `commit` 只在 numberId 非空时才往 openedNumbers 里加。
      final proxyId = ref.read(proxyProvider).currentId;
      if (proxyId.isNotEmpty) {
        await ref
            .read(proxyProvider.notifier)
            .commitOpen(
              proxyId,
              '',
              IdentityBinding(
                proxyId: proxyId,
                userAgent: fresh.userAgent,
                model: fresh.model,
                chromeMajor: fresh.chromeMajor,
                openedNumbers: const [],
                createdAtMs: DateTime.now().millisecondsSinceEpoch,
              ),
            );
      }

      // 下一次加载完成时删密钥，然后重载。
      _wipeOnLoad = true;
      onPageDiscarded();
      await engine.loadUrl(inboxUrl);
      // 新身份加载完也要盯验证状态 —— 换身份之后站点会重新
      // pending → ready 走一遍，这是一次全新的加载，计时从头算。
      onLoadStarted();

      // 换成功了一次 —— 连续计数在这里 +1（上面两处提前计数已删）。
      _consecutiveRotations++;

      if (!isAlive()) return;
      toast(
        ok
            ? '已换新身份：${fresh.model} · Chrome ${fresh.chromeMajor}'
            : 'UA 已换，但站点数据没清干净，可能仍被认成同一个人',
      );
    } catch (e) {
      logLine('换身份失败: $e');
      if (!isAlive()) return;
      toast('换身份失败：$e');
    }
  }

  /// 站点页刚加载完：删掉它的密钥，然后重载一次。
  ///
  /// 为什么是「加载完 → 删 → 再加载」两趟：
  ///   - about:blank 的 origin 不是站点，碰不到站点的 IndexedDB，
  ///     所以不能在空白页删
  ///   - 站点页面加载完成的那一刻，文档就绪但首屏请求还没发出去，
  ///     这是唯一能抢在「旧密钥被用来签名」之前删掉的窗口
  ///   - 删完这个文档已经没用了（密钥没了，发请求会 401），
  ///     重载一次让站点在干净状态下重新生成密钥
  Future<void> wipeThenReload() async {
    await _clearSiteStorage();
    if (!isAlive()) return;
    onPageDiscarded();
    try {
      // **必须 loadUrl 回收件页，不能 reload。**
      //
      // `reload` 重载的是**当前文档** —— 而当前文档可能不是收件页：
      // 验证界面开着的时候 `reload` 会把验证页一起重载 —— 换完身份
      // 用户看到的还是验证页、而不是新身份的收件页。
      //
      // 这条是「验证页」那次改动带进来的回归 —— 加验证页之前当前文档
      // 一定是收件页，所以 reload 一直是对的。
      await engine.loadUrl(inboxUrl);
    } catch (e) {
      logLine('重载失败: $e');
    }
    // 重载完是新文档，重新盯验证状态，计时从头算。
    onLoadStarted();
  }

  /// 在收件页里删掉站点自己的 IndexedDB 密钥。
  ///
  /// 必须在站点页面**加载完成之后立刻**执行，而且要在站点自己
  /// 发请求之前 —— 它会先用旧密钥签名。删完重载一次，
  /// 这次站点找不到密钥，会生成新的。
  Future<void> _clearSiteStorage() async {
    try {
      await engine.runJavaScript('''
(async function () {
  // reader.js 每次用完都会 db.close()，而且注册了 onversionchange，
  // 所以 deleteDatabase 一般会立刻成功。但仍然要 await 它，
  // 不能发完就 reload —— 删到一半重载，站点会读到半删除的库。
  function dropOne(name) {
    return new Promise(function (res) {
      var settled = false;
      function done(ok) { if (settled) return; settled = true; res(ok); }
      try {
        var req = indexedDB.deleteDatabase(name);
        req.onsuccess = function () { done(true); };
        req.onerror = function () { done(false); };
        // blocked = 站点还连着。最多等 1.2 秒，超时也返回，
        // 让上层照常 reload（新文档不会再握着旧连接）。
        req.onblocked = function () { setTimeout(function () { done(false); }, 1200); };
        setTimeout(function () { done(false); }, 2000);
      } catch (e) { done(false); }
    });
  }

  // 清不掉就不要拦着重载：这两个 API 在某些内核的隐私模式下会抛
  // SecurityError。真正关键的是下面删 IndexedDB，那才是身份的根。
  try { localStorage.clear(); } catch (e) {}
  try { sessionStorage.clear(); } catch (e) {}

  var names = [];
  try {
    if (indexedDB.databases) {
      var dbs = await indexedDB.databases();
      for (var i = 0; i < dbs.length; i++) if (dbs[i] && dbs[i].name) names.push(dbs[i].name);
    }
  } catch (e) {
    // indexedDB.databases() 在部分内核上不存在或会被隐私模式拒绝。
    // 列不出来不要紧 —— 下面无论如何都会把 'fus-reader-v1' 塞进名单，
    // 那才是身份的根，其余库漏掉一两个不影响「换个人」这件事。
  }
  // 拿不到列表也要删这个 —— 它是身份的根。
  if (names.indexOf('fus-reader-v1') < 0) names.push('fus-reader-v1');

  var results = [];
  for (var k = 0; k < names.length; k++) {
    results.push(names[k] + ':' + (await dropOne(names[k]) ? 'ok' : 'blocked'));
  }
  return results.join(',');
})();
''');
    } catch (e) {
      logLine('清站点存储失败: $e');
    }
  }

  /// 用户已经换了出口 IP，点这个把浏览器身份也一起清掉再重来。
  ///
  /// 配额记在 IP 上，换身份单独做没用（实测同一 IP 换身份后第 4 个号
  /// 依然被拒）。反过来只换 IP 不清身份，站点那边还认旧会话。所以
  /// 这两半必须一起 —— App 负责身份这一半，IP 那一半用户来做。
  Future<void> restartWithNewIdentity() async {
    // 账本里这个出口的绑定也要清掉 —— 否则下次打开还会拿回同一个
    // 身份，用户明明换了 IP 却还是旧身份，等于白换。
    await ref.read(proxyProvider.notifier).resetCurrentIdentity();
    if (!isAlive()) return;
    onPageDiscarded();
    // 公开入口：这条路径没有别的闸门持有者，交给 [rotateIdentity] 自己管。
    await rotateIdentity();
  }
}
