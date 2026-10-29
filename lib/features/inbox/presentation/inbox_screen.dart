/// 某个号的收件箱。
///
/// 界面是纯原生的：验证码大字（点一下复制）、正文、发送方、时间。
/// 底下有一个常驻但**始终不可见**的 WebView 当引擎——freeussms 的
/// `/sms-api/v1/*` 要求浏览器会话 + 每请求 WebCrypto 签名，签名私钥只存在于
/// 页面上下文，所以必须借页面自己的请求能力。广告、站点导航、页脚全都不渲染。
///
/// 验证全程自动 —— 站点的 reader.js 自己完成，不需要用户点任何东西
/// （见 _pumpVerification）。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fus_inbox/core/log.dart';
import 'package:fus_inbox/core/prefs/prefs_provider.dart';
import 'package:fus_inbox/core/proxy/identity_ledger.dart';
import 'package:fus_inbox/core/proxy/proxy_engine.dart';
import 'package:fus_inbox/core/proxy/proxy_engine_provider.dart';
import 'package:fus_inbox/core/proxy/proxy_provider.dart';
import 'package:fus_inbox/core/webview/browser_identity.dart';
import 'package:fus_inbox/core/webview/browser_shim.dart';
import 'package:fus_inbox/core/webview/http_headers.dart';
import 'package:fus_inbox/core/webview/native_capabilities.dart';
import 'package:fus_inbox/core/webview/verify_round.dart';
import 'package:fus_inbox/features/inbox/application/identity_rotator.dart';
import 'package:fus_inbox/features/inbox/application/inbox_provider.dart';
import 'package:fus_inbox/features/inbox/domain/inbox_message.dart';
import 'package:fus_inbox/features/inbox/domain/inbox_search_state.dart';
import 'package:fus_inbox/features/inbox/presentation/widgets/inbox_app_bar.dart';
import 'package:fus_inbox/features/inbox/presentation/widgets/inbox_attachments.dart';
import 'package:fus_inbox/features/inbox/presentation/widgets/inbox_message_list.dart';
import 'package:fus_inbox/features/numbers/domain/available_number.dart';
import 'package:fus_inbox/platform/web_engine.dart';
import 'package:fus_inbox/platform/web_engine_factory.dart';
import 'package:material_ui/material_ui.dart';

const _kInjectAsset = 'assets/js/fus_inbox.js';
const _kChannel = 'FusInbox';

/// 允许引擎停留的主机。
///
/// [InboxStore.ingestRaw] 会无条件接收通道送来的 JSON，所以通道只能留给
/// 站点自己的页面——第三方页面拿到它就等于能往状态层里塞任意数据。
const _kAllowedHost = 'freeussms.com';

class const InboxScreen({required this.number, super.key})
    extends ConsumerStatefulWidget {
  final AvailableNumber number;

  @override
  ConsumerState<InboxScreen> createState() => _InboxScreenState();
}

class _InboxScreenState() extends ConsumerState<InboxScreen> {
  /// WebView。类型是平台层自己的抽象，不是任何 WebView 包的类型 ——
  /// 换包只影响 `lib/platform/`，这个文件不用动。
  late final WebEngine _engine;
  late final InboxStore _store;

  late final Future<String> _scriptFuture;
  Timer? _watchdog;

  /// 翻页看门狗。和 [_watchdog] 分开：那个管首屏，这个管翻页。
  /// 必须留引用，否则页面销毁后它还会触发 setState。
  Timer? _loadMoreWatchdog;

  /// 站点页面（连着验证）是不是露出来了。
  ///
  /// 两个来源：用户点「自己过验证」主动要看；或者自动路径判定
  /// 「这个出口静默过不去」，到点自己弹出来（见 [_pumpVerification]）。

  /// 搜索框展开了没有。
  /// 搜索状态。三个值必须一起变，所以收成一个不可变对象 ——
  /// 见 `inbox_search_state.dart` 的文件头。
  InboxSearch _search = InboxSearch.closed;

  /// 「自动判验证过了」的检查在跑没有 —— 防止上一轮还没读完 cookie 就再起一轮。
  bool _autoConfirming = false;

  /// 搜索输入框的控制器。归本页持有 —— 关闭搜索时要清空它。
  final _searchController = TextEditingController();

  /// 这一轮验证的计时与闸门。
  ///
  /// 逻辑抽到 [VerifyRound] 里是因为这段状态机**没法在 Flutter 之外
  /// 测**：之前 `tool/` 下那份测试是手抄的一份模型，代码改了模型没改，
  /// 30 条全绿但一行真实代码都没跑过 —— 等于没测。
  ///
  /// 现在状态机本身在 `lib/core/webview/verify_round.dart`，纯 Dart、
  /// 不依赖 Flutter，`tool/verify_round_test.dart` 直接 import 真实
  /// 代码跑。
  final VerifyRound _round = VerifyRound();

  /// 代理引擎：负责起桥 / 设原生代理 / 拆干净。
  ///
  /// 取自 [proxyEngineProvider]，**不是**本页自己 new 一个。全 App 只有
  /// 一条出口：号码目录（`numbers_repository`）也用这条，跟收件共用
  /// 同一个节点。而且 `ProxyController.setProxyOverride` 是全局状态，
  /// 两个引擎会互相覆盖。
  ProxyEngine get _proxyEngine => ref.read(proxyEngineProvider);

  /// 本次打开号码时账本给出的计划（用哪个代理、哪个身份）。
  ///
  /// 在 `_startUp` 里算，算之前先等代理清单读完 —— 顺序不能反：
  /// 代理必须在 `loadUrl` 之前设好，否则第一个请求已经漏了真实 IP。
  ///
  /// 以前在 initState 里算。那时 [proxyProvider] 还没回填磁盘上的池子，
  /// `pool` 和 `builtin` 都是空的，于是计划被判成「直连」—— 用户配的
  /// 几百条代理全被跳过，第一个号直接拿真实 IP 开，还白吃一个额度。
  OpenPlan? _openPlan;

  /// 验证状态轮询。
  Timer? _verifyPoll;

  /// 换出口 / 换身份的控制器。
  ///
  /// 「什么时候该换、换了之后要清什么」整块搬去了
  /// `application/identity_rotator.dart` —— 那是会话被拒之后的补救流程，
  /// 和「把收件页画出来」是两件事。依赖在 initState 里注入。
  late final IdentityRotator _rotator;

  @override
  void initState() {
    super.initState();
    _store = InboxStore(
      onChanged: () {
        if (!mounted) return;
        setState(() {});
        // 状态一变就重新判一次「是不是被拒了」。可重入闸在控制器里。
        _rotator.maybeAutoRotate();

        // 翻页结束了就撤掉那 15 秒看门狗。
        //
        // 它原来只在「发起下一次翻页」和 `dispose` 时取消 —— 正常翻完
        // 成功之后还留着，15 秒后空转一次。看着无害，但**同一秒内第二次
        // `_loadMore` 失败了**的话（`fail()` 以前不清 `loadingMore`），
        // 旧 Timer 会把新请求的 `loadingMore` 清掉并谎报「翻页超时」。
        //
        // 挂在 `onChanged` 上而不是三条 ingest 分支里：那三条帧在
        // `inbox_provider` 里处理，本页看不到；而 `loadingMore` 一旦变 false
        // 就是「这一轮结束了」，无论哪条帧导致的。
        if (!_store.state.loadingMore) {
          _loadMoreWatchdog?.cancel();
          _loadMoreWatchdog = null;
        }
      },
    );
    _scriptFuture = rootBundle.loadString(_kInjectAsset).catchError((Object e) {
      _store.fail('注入脚本读不到：$e');
      return '';
    });
    _engine = _buildEngine();
    // 轮换控制器。两个回调是**屏幕这一侧的义务**：那三个计时器
    // （看门狗 / 验证轮询）归本页持有，控制器不许碰。
    _rotator = IdentityRotator(
      ref: ref,
      store: _store,
      engine: _engine,
      inboxUrl: widget.number.inboxUrl,
      isAlive: () => mounted,
      onPageDiscarded: _discardPage,
      onLoadStarted: _beginPageRound,
      toast: _toast,
    );
    // 两条都要等：垫片得在页面任何脚本之前装好，WebView 实例也得
    // 先挂进视图树（原生侧要遍历 content view 才找得到那个实例）。
    unawaited(_startUp());
    _armWatchdog();
  }

  /// 本页作废：清状态 + 重臂看门狗 + 停掉旧的验证轮询。
  ///
  /// [IdentityRotator] 的 `onPageDiscarded`。换身份 / 换出口 / 重新加载
  /// 都要走这一步 —— 上一轮的拒绝信号必须从状态里消失，否则 `hold`
  /// 还在，状态一变控制器就又会触发一次轮换。
  void _discardPage() {
    _stopVerifyPoll();
    _store.reset();
    _armWatchdog();
  }

  /// 新文档开始加载：重开验证轮 + 驱动，计时从头算。
  ///
  /// [IdentityRotator] 的 `onLoadStarted`。
  void _beginPageRound() {
    // **不能 rearm。**
    //
    // 这里是 `onLoadStarted` —— 每次页面加载完都会调一次。原来是
    // `_beginVerifyRound()`（默认 `rearm: true`），于是它把「这轮已经
    // 弹过」的闸门**重新打开**：用户收起验证之后，页面只要重载一次
    // （站点自己刷新、或者任何一次 loadUrl），闸门就开了，6 秒后
    // 又弹回来 —— 用户看到的是「没验证就退出，之后还会再弹」。
    //
    // 闸门只该由**真的拿到消息**来解开（那条路径在 `_pumpVerification`
    // 里：消息到了就 cancel 并清 hold），不该由「页面加载完」解开。
    _beginVerifyRound(rearm: false);
    _pumpVerification();
  }

  /// 用户可见的吐司。
  ///
  /// [IdentityRotator] 的 `toast` —— 状态栏那行字在换身份时不够显眼，
  /// 换完得让用户看见换成了什么。
  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          duration: const Duration(milliseconds: 2200),
        ),
      );
  }

  /// AppBar 的「重新加载」：本页作废 → 重载 → 重开一轮等待。
  Future<void> _reload() async {
    _discardPage();
    await _engine.reload();
    _beginPageRound();
  }

  /// 重新武装 25 秒看门狗。
  ///
  /// 只设一次不够：用户点「重新加载」后页面若又卡在风控，就再也没有提示了，
  /// 而那恰恰是最需要提示的场景。
  void _armWatchdog() {
    _watchdog?.cancel();
    _watchdog = Timer(const Duration(seconds: 25), _onWatchdog);
  }

  @override
  void dispose() {
    _watchdog?.cancel();
    _loadMoreWatchdog?.cancel();
    _stopVerifyPoll();
    _searchController.dispose();
    // 引擎常驻在后台，页面走了就把它带走，别留着继续加载和回传。
    _store.detach();
    // 页面走了就让引擎停在空白页，别留着继续加载、继续往已卸载的
    // 状态层回传。整个引擎的收尾在 `ProxyEngine.clear()` 那条路径上 ——
    // 这里的 WebView 只是这个号的视图。
    unawaited(_engine.loadUrl('about:blank').catchError((Object _) {}));
    super.dispose();
  }

  /// 启动：装垫片 → 打开收件页。
  ///
  /// 顺序不能反。`injectOnDocumentStart` 只对**之后**的文档
  /// 生效；先 `loadUrl` 再装就没有意义了，那一屏的 navigator
  /// 已经被站点和 Turnstile 读过。
  Future<void> _startUp() async {
    // 代理清单是异步从磁盘读的，读之前 pool/builtin 都是空的 —— 那和
    // 「用户没配代理」长得一模一样。先等它读完再算计划，否则算出来的是
    // 一条直连计划：几百条代理全被跳过，真实 IP 直接露给站点。
    await ref.read(proxyProvider.notifier).ready;
    if (!mounted) return;
    // 3 秒兜底之后 `loaded` 仍可能是 false（读盘卡住）。那时 pool 是空的，
    // 算出来的计划必然是直连 —— 拿真实 IP 去开号，比不开更糟。停下并说清。
    if (!ref.read(proxyProvider).loaded) {
      _store.fail('代理清单没读出来，已停下。请到设置里确认代理，或重新打开这个号。');
      return;
    }
    _openPlan = _planForThisNumber();
    // 等平台视图真正 attach。引擎是同步造出来的，但内核的控制器要等
    // widget 挂进树、`onWebViewCreated` 回调回来才有 —— 在那之前
    // `loadUrl` 会被丢掉，页面永远白屏。
    await Future<void>.delayed(const Duration(milliseconds: 120));
    // 代理必须最先设：垫片和第一个页面请求都会带流量出去，
    // 晚一步就是真实 IP 先露一次。
    //
    // 返回 null = 代理没设上 → **就此停下**，绝不能往下走到 `loadUrl`：
    // 那会拿真实 IP 去撞站点（见 _applyProxyPlan）。
    if (await _applyProxyPlan() == null) return;
    // 垫片必须在**任何页面脚本之前**装上：站点自己的 reader.js 和
    // Turnstile 一进来就会读 navigator，晚一步那一屏就已经被判定过了。
    final shim = await buildBrowserShim();
    if (shim.isEmpty) {
      // 装不上就别硬塞：一个 uaFullVersion 为空的垫片，比没有垫片更像
      // 一个被人改过的浏览器。这里只是记一笔，页面照常打开。
      logLine('浏览器垫片没装上（UA 里解不出 Chrome 版本）');
    } else {
      _engine.injectOnDocumentStart(shim);
      // 请求头那一路和垫片是**一对**：垫片管 JS 读到的 userAgentData，
      // 这条管引擎真发出去的 Sec-CH-UA。只装一个就是「JS 说 A、
      // 请求头说 B」。
      unawaited(applyClientHints());
    }
    if (!mounted) return;
    await _engine.loadUrl(widget.number.inboxUrl);
    // 页面开始加载就挂上验证驱动器。站点大多会自己 pending → ready，
    // 这一步不需要用户参与；但有的出口站点就是不给静默过，那时过了
    // 余量还没 ready 就把页面弹出来让用户点一下（见 _pumpVerification）。
    _beginVerifyRound();
    _pumpVerification();
  }

  /// 按账本决定这次用哪个代理、哪个身份。
  ///
  /// 规则：一个代理绑一个身份，一个身份最多看 3 个号，满了就
  /// 换代理 + 换身份。见 [IdentityLedger]。
  OpenPlan _planForThisNumber() {
    final proxyState = ref.read(proxyProvider);
    // 三个 mint 回调必须给出**同一个**新身份。
    //
    // 每次调 mintIdentity() 都会随机造一套新的，三个回调各自调一次
    // 就会得到 UA 说 SM-S918B / Chrome 134、机型字段却是 Pixel 7、
    // 版本字段是 131 —— 账本里记的身份自相矛盾，套到浏览器上就是
    // navigator.userAgentData 和 UA 对不上，比不换还扎眼。
    //
    // 所以一次造好、三个回调读同一份。账本只在真要造新身份时才调用
    // 它们，所以不会白烧。
    final fresh = mintIdentity();
    return proxyState.ledger.plan(
      // 必须用 all：内置的和用户手加的分开存（内置的在 APK
      // 资源里，只能靠排除表隐藏），只传 pool 的话内置代理在运行时
      // 一条都用不上，等于白内置。
      pool: proxyState.all,
      currentProxyId: proxyState.currentId,
      numberId: widget.number.id,
      // 检测判死的直接不进候选。没测过的照常进 —— 不能因为用户没点
      // 「全部检测」就退化成直连，那会烧掉真实 IP 的额度。
      unusable: proxyState.results.entries
          .where((e) => !e.value.ok)
          .map((e) => e.key)
          .toSet(),
      // 用 mintIdentity() 而不是 rotateIdentity()：后者会直接改当前
      // 身份，而此刻代理还没设上 —— 失败的话页面已经换成新身份却
      // 挂在旧出口上，一次白烧。造好的身份先记进账本，等代理真的
      // 设上了由 _applyProxyPlan 应用。
      mintUserAgent: () => fresh.userAgent,
      mintModel: () => fresh.model,
      mintChromeMajor: () => fresh.chromeMajor,
    );
  }

  /// 把计划里的代理设上，必要时连带把浏览器身份换掉。
  ///
  /// 返回 `null` = **别继续**：代理没设上就 `loadUrl`，等于拿真实 IP
  /// 去撞站点，比不打开更糟 —— 它会把这个 IP 的额度也吃掉。
  /// 调用方 [_startUp] 必须检查返回值。
  ///
  /// 以前这里返回 void、调用方也不看，于是「代理不可用，已停下。」这句
  /// 话只是写了一行提示，页面照旧用真实 IP 打开；而且因为提前 return，
  /// `commitOpen` 也没执行 —— 额度被吃了，账本还不知道。
  Future<ActiveProxy?> _applyProxyPlan() async {
    final plan = _openPlan;
    if (plan == null) return null;
    final active = await _proxyEngine.apply(plan.proxy);
    if (!mounted) return null;
    _store.note(active.ok ? '出口：${active.detail}' : '代理没设上：${active.detail}');
    if (!active.ok && !plan.proxy.isDirectProxy) {
      _store.fail('代理不可用，已停下。换一条代理再试。');
      return null;
    }

    // 换出口的同时必须把**浏览器身份**也换掉，三条分支一条都不能漏。
    //
    // 判据是「账本的 binding 是不是浏览器当前这台设备」，不是「出口换没换」：
    // 账本说 B 而页面露 A，站点交叉核对 UA 与客户端提示就看出来 ——
    // 本仓 browser_identity.dart 开头写着「一旦对不上，比不伪装更明显」。
    //
    // 三条分支的区别只在**清不清数据**，不能一把清：
    //   rotate  → 现造的新设备：换 UA + **清浏览数据**（新身份不能带着旧密钥）
    //   restore → 切回账本里已有的老设备：只换 UA，**绝不清数据** —— 它的
    //             全部价值就在于复用原来那对 ECDSA 密钥和「已读过哪些号」
    //             的记录。清掉等于又造一个全新身份，白吃一次额度。
    //   reuse   → 同样是账本里已有的设备，同样只换 UA、不清数据；差别是它
    //             连出口都没换。以前这里写的是「什么都不用做」，那句是错的：
    //             reuse 当时还覆盖着「这条出口从没绑过、刚 mint 了一份新
    //             身份」那条路 —— 那条已改判成 rotate（见 identity_ledger.plan）。
    //
    // 三条分支跑完，下面还会统一补一次 setUserAgent —— applyBoundIdentity 换的
    // 是全局身份，WebView 自己那个 UA 得单独设。
    if (plan.rotated) {
      applyBoundIdentity(
        userAgent: plan.binding.userAgent,
        model: plan.binding.model,
        chromeMajor: plan.binding.chromeMajor,
      );
      // 站点认人靠 IndexedDB 里那对密钥，光换 UA 没用 —— 必须清掉。
      // 否则新身份带着旧密钥回来，站点眼里还是同一个人。
      await _engine.clearSiteData();
      // 通行证跟着一起作废：cf_clearance 绑在旧 (IP, UA) 上，
      // 新出口配新身份还带着它，比不带更像在伪造。
      forgetClearance();
      if (!mounted) return null;
      await persistCurrentIdentity();
      if (!mounted) return null;
    } else if (plan.restored) {
      applyBoundIdentity(
        userAgent: plan.binding.userAgent,
        model: plan.binding.model,
        chromeMajor: plan.binding.chromeMajor,
      );
      // 不清数据，但要保证页面上真的用上了这个 UA。
      if (mounted) await persistCurrentIdentity();
      if (!mounted) return null;
    } else if (currentUserAgent != plan.binding.userAgent) {
      // reuse：binding 是账本里**已有**的那台设备，但浏览器当前不一定就是它。
      //
      // 例：先看 A 出口的号（身份 A），再看 B 出口的号（身份 B），回头点 B 的
      // 另一个号 —— owner 是 B、和 current 相同，于是走 reuse 而不是 restore，
      // 而浏览器此刻装着的是 A。不补这一刀，账本说 B、页面露 A。
      //
      // 与 rotate 的差别只在**清不清数据**：这台设备之前就用过这个出口，
      // 它的密钥和「已读过哪些号」都得留着。
      applyBoundIdentity(
        userAgent: plan.binding.userAgent,
        model: plan.binding.model,
        chromeMajor: plan.binding.chromeMajor,
      );
      if (mounted) await persistCurrentIdentity();
      if (!mounted) return null;
    }

    // rotate / restore 都在上面把**全局身份**换成了 plan.binding，但 WebView
    // 自己的 UA 是 _buildController() 在 initState 里同步焊死的，那时还是
    // 计划应用**之前**的旧身份。不补这一刀，站点看到的 navigator.userAgent
    // 是旧设备，而 navigator.userAgentData（垫片紧跟着读 currentIdentity）
    // 是另一台 —— 本仓 browser_identity.dart 开头自己写着「客户端提示必须
    // 和 UA 同步……一旦对不上，比不伪装更明显」。
    //
    // 位置也是死的：必须在 _startUp 装垫片之前 ——
    // 垫片一装上，它里面的 brands / model 就改不了了。
    await _engine.setUserAgent(plan.binding.userAgent);
    if (!mounted) return null;

    // 代理设成了才记账。没设成就记一笔的话，这个出口的 3 个额度
    // 会被白白吃掉 —— 而且记的还是别人的账。
    await ref
        .read(proxyProvider.notifier)
        .commitOpen(plan.proxy.id, widget.number.id, plan.binding);
    if (!mounted) return null;
    if (plan.rotated) {
      _store.note('换到新出口：${plan.proxy.displayName}（${plan.reason}）。');
    } else if (plan.restored) {
      // 回头点老号才会走到这 —— 说清楚是「切回原来那条」，不是又轮换。
      _store.note('切回原出口：${plan.proxy.displayName}（${plan.reason}）。');
    }
    return active;
  }

  /// 25 秒还没拿到任何东西，提示可能卡在风控上。
  void _onWatchdog() {
    final st = _store.state;
    if (!mounted || st.messages.isNotEmpty) return;
    // 失败面板直接把 status 当正文显示（InboxEmptyState 的 failed 分支）。
    // 这里再 note 一句会把「代理不可用，已停下」顶成「可能卡在风控」——
    // 用户看到的失败原因凭空变假。失败态有自己的「重试」按钮，不用看门狗。
    if (st.phase == InboxPhase.failed) return;
    // 这条提示只写在状态栏里。弹层开着时状态栏被站点页面整个盖住
    // （见 build 里那个 Positioned.fill 的 Offstage），hold 挂着时状态栏
    // 被 HoldNotice 顶掉 —— 这两种情况下这一响没人看得见。
    //
    // 而看门狗只此一响：_armWatchdog 只在换身份 / 重载（_discardPage）
    // 时重臂。在这一响上白白耗掉，这个会话剩下的时间就再没有兜底
    // 提示了 —— 弹层一收起、还是卡着，用户什么提示都等不到。
    // 所以看不见就别消耗：重臂一轮，等弹层收起 / hold 解除后的下一响。
    if (_round.open || st.hold != null) {
      _armWatchdog();
      return;
    }
    _store.note(st.hits == 0 ? '25 秒没截获到接口响应，可能卡在站点的人机验证。' : '截获到了接口，但里面没有消息。');
  }

  /// 造这个页面的 WebView。
  ///
  /// 回调在这里**一次注册完**：引擎会把它们攒着，等 [WebEngine.buildView]
  /// 真正创建出平台视图时一起交给内核。所以顺序是先调 [WebEngine.buildView]，
  /// 再让引擎去加载东西 —— 反过来的话第一个请求会漏掉 UA 和代理。
  WebEngine _buildEngine() {
    final engine = createWebEngine(userAgent: currentUserAgent);

    // 只放行站点自己的域名。通道会把页面发来的 JSON 直接交给状态层，
    // 任何第三方页面拿到它都是不该有的攻击面。
    engine.onNavigationRequest((url) {
      final host = Uri.tryParse(url)?.host ?? '';
      return host == _kAllowedHost || host.endsWith('.$_kAllowedHost');
    });

    engine.onMessage(_kChannel, _store.ingestRaw);

    // 注入要抢在站点自己发首屏请求之前，否则只能等 DOM 扫描，那就是几秒
    // 起的延迟。onPageStarted 时 document 可能还没建好，注入失败无所谓 ——
    // onPageFinished 会再补一次；JS 有 `__fusInboxHooked` 守卫，重复注入
    // 不会叠加定时器。
    engine.onPageStarted((url) => unawaited(_injectQuietly()));
    engine.onPageFinished((url) {
      // 换身份那条路径要卡在这一刻删站点密钥（见 IdentityRotator）。
      // 只认第一次 —— 一次重定向会连着触发多次 pageFinished。
      if (_rotator.takeWipeOnLoad()) {
        unawaited(_rotator.wipeThenReload());
        return;
      }
      unawaited(_inject());
    });

    // 引擎层已经把「只报主框架的错」判过了，这里不用再判一次。
    engine.onWebResourceError((error) {
      // 给用户看的是 [WebEngineError.userMessage]（中文、能照着做），
      // 内核原文只进日志 —— 直接贴 net::ERR_xxx 用户看不懂也做不了什么。
      logLine('页面加载失败 code=${error.code} url=${error.url}');
      _store.fail(error.userMessage);
    });

    return engine;
  }

  /// 注入脚本。
  ///
  /// 不在这里做「同一页面只注入一次」的闸：JS 文件开头有
  /// `if (window.__fusInboxHooked)` 守卫，同页面重复执行只会触发一次 rescan，
  /// 不会重启定时器。而 Dart 侧加时间窗口反而危险——页面重定向后
  /// 新文档需要重新注入，被窗口吞掉就彻底不工作了。
  Future<void> _inject() async {
    final script = await _scriptFuture;
    if (script.isEmpty) return;
    try {
      await _engine.runJavaScript(script);
    } catch (e) {
      logLine('注入失败: $e');
    }
  }

  /// 早期注入：onPageStarted 时文档可能还不存在，失败是常态，不打印噪音。
  Future<void> _injectQuietly() async {
    final script = await _scriptFuture;
    if (script.isEmpty) return;
    try {
      await _engine.runJavaScript(script);
    } catch (_) {
      // 正常情况：document 还没建好。onPageFinished 会重试。
    }
  }

  /// 开一轮新的验证等待：起算点归位。
  ///
  /// 换号 / 换身份 / 换 IP / 手动重载时调 —— 这些都是「上一个页面作废、
  /// 从头再来」。除此之外 [_pumpVerification] 只是接着当前这轮算，
  /// 因为换身份那条路径会把 [_pumpVerification] 连着调两次（`loadUrl`
  /// 之后一次、`IdentityRotator.wipeThenReload` 里一次），每次都归零的话起算点会被
  /// 顶到最新那一刻，等满自动弹出阈值就遥遥无期。
  ///
  /// [rearm] 决定要不要把「这轮已经弹过」的闸门也解开。用户在验证页上
  /// 点了按钮（过了 / 收起）之后调这个，得把起算点重置 —— 否则他要是
  /// 在页面上耗了超过窗口时长，一回来轮询第一次 tick 就判超时自杀，
  /// 明明刚说「我过了」反而当场放弃。
  ///
  /// 但闸门不能一律解开：点「收起」是明确表示不想过，解开就会在 6 秒后
  /// 立刻又弹回来，等于没得选。所以那条路径传 `rearm: false`。
  void _beginVerifyRound({bool rearm = true}) => _round.begin(rearm: rearm);

  /// 停掉验证轮询。**所有**停止路径都必须走这里。
  ///
  /// 关键是**把字段置 null**。原来各条自杀路径只写 `timer.cancel()`，
  /// 字段仍指向那个已取消的 Timer —— 于是 [_openChallenge] 里那句
  /// `else if (_verifyPoll == null)` 恒为假：轮询已经死了，它还认为
  /// 「正在跑」，于是不重启。
  ///
  /// 后果：页面等超时/收到消息/验证报错之后轮询自杀 → 用户点「自己过
  /// 验证」→ 不重启 → `cf_clearance` 到手也没人读，自动收层全死。
  void _stopVerifyPoll() {
    _stopVerifyPoll();
    _verifyPoll = null;
  }

  /// 驱动器：让站点自己把验证走完。
  ///
  /// ## 实测结论（不要再凭猜想改）
  ///
  /// 打开收件页后，站点的 reader.js 会自己发起验证：
  ///
  ///   phase: pending  →  （静默建立会话，页面里**不会**出现任何
  ///                        Turnstile iframe 或复选框）
  ///   phase: ready    →  会话可用，接着才去要消息
  ///
  /// 实测从加载到 ready 大约 4 秒，全程 `iframes: 0`。也就是说
  /// 主路径是静默：轮询 `FUSReader.status()`，等它自己到 ready。
  /// 大多数出口 4 秒内就过了，全程不需要用户参与。
  ///
  /// 但**有的出口站点不给静默过**，那时页面里会真的摆一个
  /// 「Verify you are human」复选框，只有人点得到（跨域 shadow DOM，
  /// JS 摸不着）。所以静默等过自动弹出阈值还没 ready，
  /// 就把页面弹出来让用户点一下 —— 这也是「只弹需要点的那种」：
  /// 能在 4 秒里自己过的出口根本走不到这一步。
  ///
  /// 真失败时（category/errorCode 有值，Cloudflare 报错也走这条）
  /// 一样把页面放出来，用户至少能看到失败原因、能自己点一下重试。
  void _pumpVerification() {
    _stopVerifyPoll();
    // 起算点只在没有的时候才落 —— 重复调用接着算，不归零。
    _round.arm();
    _verifyPoll = Timer.periodic(const Duration(milliseconds: 900), (
      timer,
    ) async {
      if (!mounted) {
        _stopVerifyPoll();
        return;
      }
      // 用真实流逝时间，不是累加 900ms —— 定时器被系统挂起时
      // 累加值会落后于真实时间，真实时间才代表用户等了多久。
      _round.refresh();
      // 超时只在**弹层没开**的时候算。
      //
      // 窗口是 90 秒，而用户在站点页面上点复选框、等 Cloudflare 转圈，
      // 很容易超过 90 秒 —— 那时候把轮询停掉，等于「你正在过验证，
      // 但 App 已经不看了」。用户过完回来发现界面还是老样子，
      // 原因就是他过验证的那段时间状态机自杀了。
      //
      // 弹层开着 = 用户正在亲手处理，这段时间不该计时淘汰他。
      if (_round.timedOut && !_round.open) {
        _stopVerifyPoll();
        _store.note('站点验证超时，已停止等待。');
        return;
      }

      // 已经拿到消息就不用再管验证状态。
      if (_store.state.messages.isNotEmpty) {
        _stopVerifyPoll();
        return;
      }
      // **自动弹层开着时，不要在页面里跑任何 JS。**
      //
      // 用户要求：跳转过去之后不许自己刷新、不许自己乱动。
      // 而下面那段每 900ms 都会 `evaluateJavascript` 读一次
      // `FUSReader.status()` —— 对用户来说那就是页面一直在动。
      //
      // 弹层开着时唯一还需要盯的是 `cf_clearance`（它一出现就说明
      // 验证真过了，可以自动收层）。那件事读的是**原生 cookie 库**，
      // 不碰页面，所以单独走一条最短路径。
      if (_round.open) {
        if (_round.watchingForAutoPass) {
          await _autoConfirmIfPassed();
        }
        return;
      }
      String phase = '';
      try {
        // 必须走 evaluateJavascript：WebEngine.runJavaScript 返回
        // Future<void>，拿不到值（`_loadMore` 那边的注释也记着这点）。
        final raw = (await _engine.evaluateJavascript(
          '(window.FUSReader && window.FUSReader.status)'
          ' ? JSON.stringify(window.FUSReader.status()) : ""',
        )).toString();
        if (raw.isNotEmpty && raw != '""') {
          // runJavaScript 返回的是 JSON 字符串里的字符串，剥两层引号。
          final decoded = jsonDecode(raw) as String;
          if (decoded.isNotEmpty) {
            final obj = jsonDecode(decoded) as Map<String, dynamic>;
            phase = obj['phase']?.toString() ?? '';
            final category = obj['category']?.toString() ?? '';
            final message = obj['message']?.toString() ?? '';
            if (phase == 'error') {
              _stopVerifyPoll();
              _store.note(
                message.isNotEmpty ? '站点验证失败：$message' : '站点验证失败（$category）',
              );
              // 验证已经明确失败了（Cloudflare 报错也是走这条），这时候
              // 页面藏着一句话说明不了任何问题 —— 放出来让用户自己看
              // 一眼、必要时点一下重试。之前这里只留一条日志，用户
              // 既看不到失败原因也做不了任何事。
              // 验证已经明确失败了（Cloudflare 报错也走这条），这时候页面藏着
              // 一句话说明不了任何问题 —— 放出来让用户自己看一眼、必要时点一下
              // 重试。只留一条日志的话，用户既看不到失败原因也做不了任何事。
              if (!_round.open && !_round.autoPopped) {
                _openChallenge(auto: true);
              }
              return;
            }
          }
        }
      } catch (e) {
        // 页面还在加载、没有 FUSReader，属正常，继续等。
      }

      if (phase == 'ready') {
        // 这里**不能** cancel。
        //
        // ready 只说明 FUSReader 的会话建好了，不代表站点肯把消息给你：
        // 号码是新开的、IP 刚被限流、或者页面上还压着一个没点的人机
        // 验证，都会出现「ready 了但消息一直不来」。之前这里直接
        // timer.cancel() + return，轮询当场自杀 —— 于是永远走不到下面
        // 那个自动弹出，用户只看到状态栏一直转圈，等多久都不弹验证。
        //
        // 现在继续盯：消息到了上面那条会自己 cancel，没到就靠下面的
        // 「等太久」把页面放出来。
        if (_round.markReady()) {
          // 会话好了，让站点自己去拉消息。
          unawaited(_rescan());
          // 顺手把 Cloudflare 通行证搬到原生 HTTP。
          //
          // 号码目录和收录时间走 dart:io HttpClient，**不共享 WebView 的
          // cookie 库**。不搬，那两条链路每次都裸奔着被单独挑战 ——
          // 这正是「同一个 App 里一条链路有通行证、一条没有」的来源。
          // cf_clearance 是 HttpOnly，JS 的 document.cookie 永远读不到，
          // 只有原生 getCookie 拿得到。
          unawaited(_syncClearance());
        }
      }

      // 等太久还没消息 → 把页面放出来让用户点一下。
      //
      // 走到这里说明：站点要么在等人机验证（页面里正摆着一个真的
      // 「Verify you are human」复选框），要么会话好了但一直不给消息。
      // 两种情况用户能做的事是一样的 —— 把页面亮出来，他点一下就行。
      //
      // 能在几秒里自己过的出口根本走不到这一步，所以「弹出来的
      // 必定是需要点一下的那种」。
      if (!_round.open && _round.shouldAutoPop) {
        _store.note('这个出口卡住了，已把页面放出来让你点一下。');
        _openChallenge(auto: true);
      }

      // 自动弹层开着 → 盯着 cf_clearance，它一出现就自动收层继续。
      // （用户自己点开的那个弹层不自动收：他可能只是想顺便看看网页。）
      if (_round.watchingForAutoPass) {
        unawaited(_autoConfirmIfPassed());
      }
    });
  }

  /// 自动弹层时盯着 `cf_clearance`：一出现就说明人机验证真的过了，
  /// 立刻收层继续，不用用户再去点「验证好了」。
  ///
  /// ## 判据只认这一个 cookie，不认 DOM 猜
  ///
  /// 「挑战容器消失了」「页面里出现消息节点了」这类 DOM 信号在导航栏、
  /// 广告、骨架屏上都成立 —— 项目里为此误判过一整轮。而 `cf_clearance`
  /// 是 Cloudflare **只在真的放行之后**才下发的凭证，且它是 HttpOnly，
  /// 页面的 JS 根本读不到，只有原生 cookie 接口拿得到。
  ///
  /// 这条思路和站点的做法一致：Han1meViewer 那边判通过也是
  /// 「页面加载完 + 挑战标记都不在 + cookie 里有 cf_clearance」三条同时成立，
  /// 而其中决定性的那条就是最后这个 cookie。
  Future<void> _autoConfirmIfPassed() async {
    if (_autoConfirming) return;
    _autoConfirming = true;
    try {
      // 先看 DOM 上还有没有挑战标记。参照 Han1meViewer
      // （CloudflareActivity.kt）的三条判据：页面加载完、挑战标记都不在、
      // cookie 里有 cf_clearance。这里做前两条 —— 标记还在就说明挑战页
      // 还挂着，哪怕 cookie 已经下发也不能收（可能是上一次留下的）。
      //
      // 三个标记是 Cloudflare 挑战页自己的 id，不是猜的：
      // `id="challenge-form"`（要填的表单）、`id="challenge-success-text"`（成功文案
      // 还在渲染）、`id="challenge-error-text"`（失败重试）。
      final stillChallenging = await _engine.evaluateJavascript(
        'var h = document.head ? document.head.innerHTML : "";'
        'var b = document.body ? document.body.innerHTML : "";'
        'var s = h + b;'
        // **查 id="..."，不是查 #...。**
        //
        // innerHTML 里是 id="challenge-form"，根本没有 # 号。原来查的是
        // indexOf("#challenge-form")，恒为假 —— 于是「挑战标记还在就别收层」
        // 这道闸形同不存在。
        'var a = s.indexOf("id=\\"challenge-form\\"") >= 0;'
        'var b2 = s.indexOf("id=\\"challenge-success-text\\"") >= 0;'
        'var c2 = s.indexOf("id=\\"challenge-error-text\\"") >= 0;'
        '(a || b2 || c2) ? "1" : "0";',
      );
      if ('$stillChallenging'.contains('1')) return;

      final cookies = await _engine.readCookies(widget.number.inboxUrl);
      final value = cookies['cf_clearance'];
      if (value == null || value.isEmpty) return;
      // 读 cookie 是异步的，回来时前提可能已经变了（用户点了收起 / 页面走了）。
      if (!mounted || !_round.watchingForAutoPass) return;
      rememberClearance(value);
      _store.note('验证通过，继续加载。');
      // **不能直接在这里调 `_confirmChallengeDone`**：这个方法本身是从
      // `_verifyPoll` 的 Timer 回调里被调起来的，而 `_confirmChallengeDone`
      // 第一句就是 `_verifyPoll?.cancel()` —— 在正在执行的回调里取消自己
      // 属于竞态（旧回调可能还没 await 回来，新一轮就已经起了）。
      //
      // 推迟到当前微任务队列之后再做：那时这一轮回调已经完整返回，
      // 取消 + 重启就是干净的一次状态切换。
      unawaited(Future<void>.microtask(_confirmChallengeDone));
    } catch (_) {
      // 页面正在导航时读 cookie 会抛，那是正常时序，下一轮再试。
    } finally {
      _autoConfirming = false;
    }
  }

  /// 把 WebView cookie 库里的 cf_clearance 搬到原生 HTTP 的请求头。
  ///
  /// 只在拿到值的时候写。没拿到就保持原样 —— 发一个空的 cf_clearance
  /// 等于明确告诉站点「我试过但没拿到」，比不发更糟。
  Future<void> _syncClearance() async {
    try {
      final cookies = await _engine.readCookies(widget.number.inboxUrl);
      final value = cookies['cf_clearance'];
      if (value != null && value.isNotEmpty) rememberClearance(value);
    } catch (_) {
      // 读不到就算了，收件箱本身已经能用了。
    }
  }

  /// 把站点页面亮出来，让用户自己在上面过验证。
  ///
  /// 为什么要留这个入口 —— 自动路径（[_pumpVerification]）覆盖大多数情况，
  /// 但**有的出口 IP 站点就是不给静默通过**，那时页面里会真的出现一个
  /// 「Verify you are human」复选框，而且它在跨域 shadow DOM 里，JS 摸不到，
  /// 只能靠人点。所以这个入口是给「自动过不去」用的，不是必经步骤。
  ///
  /// [reload] 只给「用户主动点自己过验证」用 —— 那种情况页面可能停在旧状态，
  /// 重载一次让站点重新发起验证。**自动弹出绝不能重载**：页面本来就是刚加载
  /// 的，重载只会把用户正要点的那个验证框销毁重建，点下去落在已经不存在的
  /// DOM 上，等于白点。
  ///
  /// ## 这里**不能**停掉 [_pumpVerification]
  ///
  /// 以前这里有一句 `_verifyPoll?.cancel()`，取消之后再也没重启 —— 于是
  /// 「弹层弹出来 → 用户在页面上过验证 → 回来」这段路上，**状态机是死的**：
  /// App 不知道站点已经 ready，也不知道消息已经到了，界面就一直卡在原来
  /// 那个状态。用户看到的是「切过去了但回来还是不让我过」。
  ///
  /// （收尾的那两个方法 `_confirmChallengeDone` / `_closeChallenge` 都会重启
  /// 轮询，所以「点了按钮之后」反而是好的 —— 坏的正是**弹层开着、用户正在
  /// 过验证**这一段，而那一段恰恰是唯一需要盯着状态的时段。）
  ///
  /// 现在不动轮询：它自己有几个退出条件（消息到了、超窗口、明确失败），
  /// 而「到点自动弹」的闸门由 [_round.markPopped] 管住，不会重复弹。
  void _openChallenge({bool reload = false, bool auto = false}) {
    // 不管是谁弹的（用户点的还是到点自动弹的），都算「这次加载弹过了」，
    // 免得收起之后又被自动弹回来。
    _round.markPopped();
    // 起算点归零：可能已经耗过一会儿（自动弹出就是等满 6 秒才弹的）。
    // 不归零的话，用户一进来就已经「用了 6 秒」，90 秒窗口只剩 84 秒。
    // `rearm` 传 false —— 闸门要保持关着，否则收起之后 6 秒又自动弹回来。
    _round.begin(rearm: false);
    setState(() {
      if (auto) {
        _round.showAuto();
      } else {
        _round.showManual();
      }
    });
    if (reload) {
      // 重载一次让站点重新发起验证。
      //
      // 用 `loadUrl` 而不是 `reload`：`reload` 重载的是**当前文档**，
      // 而当前文档不一定还是收件页（用户可能在站点内部跳转了几层）。
      // `loadUrl` 一律回到收件页 —— 这个入口的意义就是「我要看网站
      // 页面、自己在上面过验证」。
      unawaited(_engine.loadUrl(widget.number.inboxUrl));
    } else if (_verifyPoll == null) {
      // 真没在跑才启动（比如页面刚加载完、还没走到 _pumpVerification）。
      _pumpVerification();
    }
  }

  /// 用户说验证过了：收起页面，重新要消息。
  ///
  /// 和 [_closeChallenge]（收起）的区别：收起是「先退出来」，状态还继续
  /// 盯着；这个是真的断言「我过了」，所以重开一轮等待、立刻重扫一次。
  ///
  /// 起算点要重置 —— 用户可能在人机验证上耗了一分钟以上，接着旧起算点
  /// 算的话第一次 tick 就超窗口，当场判超时。
  void _confirmChallengeDone() {
    _stopVerifyPoll();
    setState(_round.close);
    // **闸门保持关着（`rearm: false`）。**
    //
    // 这里原来是 `_beginVerifyRound()`，默认 `rearm: true` —— 于是刚点完
    // 「验证好了」，闸门解开，`_pumpVerification` 再等 6 秒又满足
    // `shouldAutoPop`，验证页立刻又弹回来。用户的实际感受是「验证完还会
    // 再弹，而且永远弹不完」。
    //
    // 只有**真的拿到消息**才该解开闸门（那条路径在 `_pumpVerification`
    // 里：消息到了就 cancel 并清 hold），不是靠「用户点了确认」。
    _beginVerifyRound(rearm: false);
    unawaited(_rescan());
    _pumpVerification();
  }

  /// 用户说先不弄了：收起页面，但继续盯状态。
  ///
  /// 起算点同样重置（免得旧轮次已经超窗口），但**不解开闸门** —— 用户
  /// 刚说了不想过，6 秒后又自动弹回来等于没给他选。
  void _closeChallenge() {
    _stopVerifyPoll();
    setState(_round.close);
    _beginVerifyRound(rearm: false);
    // 收起之后继续盯状态，站点可能自己就 ready 了。
    _pumpVerification();
  }

  /// 让注入脚本重扫一遍当前页面 DOM。
  ///
  /// 不发网络请求 —— 纯粹是把已经渲染出来的内容再读一遍。用途是用户
  /// 刚在站点页面上点完人机验证、或者站点自己 ready 之后补一次读取，
  /// 免得干等下一个轮询周期。
  Future<void> _rescan() async {
    try {
      await _engine.runJavaScript(
        'window.__fusInbox && window.__fusInbox.rescan();',
      );
    } catch (e) {
      logLine('重扫失败: $e');
    }
  }

  /// 拉更早的一页。
  ///
  /// 由列表滑到底触发，一页一页来。用户没滑到底就绝不请求——
  /// 站点在 Cloudflare 后面，多抓一页就多一分被风控的概率。
  Future<void> _loadMore() async {
    final s = _store.state;
    if (s.loadingMore || !s.hasMore) return;
    _store.note('正在加载更早的消息…');
    _store.markLoadingMore();
    try {
      // runJavaScript 返回 Future<void>，拿不到返回值。
      // 所以这里只负责发起；结束状态由 JS 的 moreDone/moreEnd/moreFail 回传。
      await _engine.runJavaScript(
        'window.__fusInbox && window.__fusInbox.loadMore();',
      );
      // 看门狗：JS 可能因为拿不到号码 id、页面被风控、或注入没生效而
      // 一声不吭。没有这道兜底，转圈会一直转到用户杀掉页面。
      _loadMoreWatchdog?.cancel();
      _loadMoreWatchdog = Timer(const Duration(seconds: 15), () {
        if (!mounted) return;
        if (!_store.state.loadingMore) return;
        _store.markLoadingMore(done: true);
        _store.note('翻页超时，稍后再试。');
      });
    } catch (e) {
      logLine('加载更多失败: $e');
      _store.markLoadingMore(done: true);
      // 超时有提示（见上面的看门狗），这里以前只有一行日志 ——
      // 同样是「没翻成」，一个说话一个不说，用户无从知道该怎么办。
      _store.note('翻页失败，稍后再试。');
    }
  }

  /// 复制到剪贴板，并告诉用户复制了什么。
  ///
  /// [label] 是「验证码」/「整条短信」这类名字；[text] 是**真正进剪贴板**的内容。
  ///
  /// ## 提示里为什么不把正文照抄一遍
  ///
  /// 以前提示写的是 `已复制$label $text`，也就是把正文原样贴进 SnackBar。
  /// 复制验证码时没问题（就 6 位），复制整条短信时就成了**把整条短信糊在
  /// 屏幕底部** —— 一条长短信能占掉大半个屏幕、盖住下面的消息，用户还得
  /// 等它自己消失。而他刚刚本来就看着这条短信。
  ///
  /// 现在：短的（验证码那种）照原样显示，确认「复制的确实是这个」；
  /// 长的只报个名字 —— 内容已经进剪贴板了，提示的任务是告知，不是复述。
  Future<void> _copy(String text, String label) async {
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text('已复制$label${text.length <= 24 ? '：$text' : ''}'),
          duration: const Duration(milliseconds: 1100),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final s = _store.state;
    final theme = Theme.of(context);

    // 验证层开着的时候，返回键只收验证层，不退出号码页。
    //
    // 系统返回键和 AppBar 自动生成的返回箭头走的都是
    // Navigator.maybePop，而 maybePop 会先问 PopScope 的 canPop，
    // 所以这一处能同时管住两个入口。
    //
    // 用户点「自己过验证」是想亲眼看一眼站点页面、必要时点掉那个
    // 跨域 shadow DOM 里的复选框（JS 摸不到，只能人点）。看完按返回
    // 的意图是「回到我刚才看消息的地方」，不是「这个号我不看了」。
    // 之前没有这道拦截，返回键会直接 pop 掉整个 InboxScreen 回到
    // 号码列表，用户还得重新点进来、重新走一遍加载和验证。
    return PopScope<Object?>(
      canPop: !_round.open,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (_round.open) _closeChallenge();
      },
      child: Scaffold(
        // 验证态**不挂收件页的 AppBar**：那一刻用户不在收件箱里，他在做
        // 站点要求的一个动作。顶栏换成 [ChallengeHeader]（见下面的 Stack），
        // 说清「现在在干什么、怎么退出去」。
        appBar: _round.open
            ? null
            : InboxAppBar(
                number: widget.number,
                messageCount: s.messages.length,
                searching: _search.open,
                controller: _searchController,
                codeOnly: _search.codeOnly,
                onQuery: (q) => setState(() => _search = _search.withQuery(q)),
                onOpenSearch: () => setState(() => _search = _search.opened()),
                onCloseSearch: () {
                  // 关闭时把关键词和「只看验证码」一起清掉 —— 下次点开搜索是
                  // 全新的，不会莫名其妙只剩几条。`closed` 是唯一入口，
                  // 三个值不可能漏清一个。
                  _searchController.clear();
                  setState(() => _search = InboxSearch.closed);
                },
                onToggleCodeOnly: () =>
                    setState(() => _search = _search.toggleCodeOnly()),
                onChallenge: _openChallenge,
                onRotateIdentity: _rotator.rotateIdentity,
                onRescan: _rescan,
                onReload: _reload,
              ),
        body: Stack(
          children: [
            // 界面层铺满，永远可见。
            InboxMessageList(
              state: s,
              theme: theme,
              prefs: ref.watch(prefsProvider),
              query: _search.query,
              codeOnly: _search.codeOnly,
              onRescan: _rescan,
              onChallenge: () => _openChallenge(reload: true),
              onRestart: _rotator.restartWithNewIdentity,
              onRevealMore: _store.revealMore,
              onLoadMore: _loadMore,
              onCopyCode: (c) => _copy(c, '验证码'),
              onCopyAll: (m) => _copy(fullMessageText(m), '整条短信'),
            ),

            // 引擎层：整个页面树里**只有这一个** WebView 实例
            // （一个内核控制器只能对应一个平台视图）。
            //
            // 默认 Offstage 藏着：验证通常由站点自己完成（见
            // _pumpVerification），不需要人看。只有用户点了「自己过验证」
            // 才把它放出来 —— 有些出口 IP 站点不给静默通过，会真的弹出
            // 「Verify you are human」复选框，那个东西在跨域 shadow DOM
            // 里 JS 摸不到，只能靠人点。
            //
            // 用 Offstage 而不是缩到 1×1：布局照常跑完整尺寸，原生
            // WebView 拿到真实视口，媒体查询、懒加载、IntersectionObserver
            // 都按正常手机尺寸算；跳过绘制与命中测试，不占合成层。
            //
            // **整页显示，不做任何裁剪/缩放。** 这一条是真机证伪之后改的：
            // 之前为了「只放大验证框」，在它外面套了 ClipRect + Transform，
            // 用 [focusOnChallenge] 算缩放和平移。结果真机上是一片空白 +
            // 底下露出背景色 —— 因为 `Transform` 对**平台视图**不生效：
            // 原生 WebView 不是 Flutter 绘制的纹理，布局被缩了、渲染照旧，
            // 内容直接被推出可见区域。
            //
            // 参照 Han1meViewer（CloudflareScreen.kt）：它的验证页就是
            // `AndroidView` + `fillMaxSize()`，一个变换都没有。要改页面内部
            // 布局只能靠 WebView 自己（站点页面），Flutter 这边改不了。
            Positioned.fill(
              child: Offstage(
                offstage: !_round.open,
                child: ColoredBox(
                  // 引擎自己看不见背景，给个深色免得加载瞬间闪白。
                  color: const Color(0xFF10131A),
                  child: _engine.buildView(),
                ),
              ),
            ),

            // 独立验证界面的标题栏，顶到 SafeArea 上沿。
            if (_round.open)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: ChallengeHeader(
                  theme: theme,
                  auto: _round.auto,
                  onClose: _closeChallenge,
                ),
              ),

            // 用户自己过验证时的底栏。叠在引擎上方、贴底，不遮住
            // 复选框区域（实测复选框在视口 y≈600，底栏只占最下面一条）。
            if (_round.open)
              ChallengeBar(
                theme: theme,
                onClose: _closeChallenge,
                onConfirm: _confirmChallengeDone,
              ),
          ],
        ),
      ),
    );
  }
}
