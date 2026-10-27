/// 某个号的收件箱。
///
/// 界面是纯原生的：验证码大字（点一下复制）、正文、发送方、时间。
/// 底下有一个常驻但**始终不可见**的 WebView 当引擎——freeussms 的
/// `/sms-api/v1/*` 要求浏览器会话 + 每请求 WebCrypto 签名，签名私钥只存在于
/// 页面上下文，所以必须借页面自己的请求能力。广告、站点导航、页脚全都不渲染。
///
/// 只有在站点弹出需要人工操作的风控时才手动露出一次页面（见 _showChallenge）。
library;

import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'package:fus_inbox/core/prefs/prefs_provider.dart';
import 'package:fus_inbox/core/translate/translation_provider.dart';
import 'package:fus_inbox/core/webview/browser_identity.dart';
import 'package:fus_inbox/core/webview/http_headers.dart';
import 'package:fus_inbox/core/webview/native_capabilities.dart';
import 'package:fus_inbox/core/webview/webview_widget.dart';
import 'package:fus_inbox/core/time/site_time.dart';
import 'package:fus_inbox/features/inbox/application/inbox_provider.dart';
import 'package:fus_inbox/features/inbox/domain/inbox_message.dart';
import 'package:fus_inbox/features/numbers/domain/available_number.dart';

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
  late final WebViewController _controller;
  late Future<WebViewWidget> _webViewFuture;
  late final InboxStore _store;

  late final Future<String> _scriptFuture;
  Timer? _watchdog;

  /// 翻页看门狗。和 [_watchdog] 分开：那个管首屏，这个管翻页。
  /// 必须留引用，否则页面销毁后它还会触发 setState。
  Timer? _loadMoreWatchdog;

  /// 站点要求人工过风控时，临时露一次页面。平时恒为 false。
  bool _showChallenge = false;

  /// 验证通过轮询。
  ///
  /// 只在用户打开验证面板时跑，一看到 cf_clearance 就停。
  Timer? _clearancePoll;

  /// 验证面板打开后最多等这么久。
  ///
  /// 用户可能开着面板一直不动（去看别的了）。无上限轮询会白耗电。
  static const _clearancePollWindow = Duration(minutes: 3);

  /// 防重入：上一轮的原生读 cookie 还没回来，这一轮就别再发。
  ///
  /// Timer.periodic 的回调是 async，1.5 秒周期配 2 秒超时，理论上会叠。
  /// 叠起来就是每次点开面板都排一队通道调用，白白压主线程。
  bool _clearanceBusy = false;

  /// 重置身份后置 true：等站点页加载完成，立刻删掉它的密钥。
  ///
  /// 不能提前删 —— about:blank 的 origin 和站点不同，碰不到站点的
  /// IndexedDB。也不能等站点自己发完请求再删，那时旧密钥已经用来
  /// 签名过了。所以卡在 onPageFinished 这一刻：
  /// 站点还没发首屏请求，文档已经就绪，删得掉。
  bool _wipeSiteStorageOnLoad = false;

  @override
  void initState() {
    super.initState();
    _store = InboxStore(
      onChanged: () {
        if (mounted) setState(() {});
      },
    );
    _scriptFuture = rootBundle.loadString(_kInjectAsset).catchError((Object e) {
      _store.fail('注入脚本读不到：$e');
      return '';
    });
    _controller = _buildController();
    _webViewFuture = createPlatformWebView(_controller);
    // 两条都要等：垫片得在页面任何脚本之前装好，WebView 实例也得
    // 先挂进视图树（原生侧要遍历 content view 才找得到那个实例）。
    unawaited(_startUp());
    _armWatchdog();
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
    _clearancePoll?.cancel();
    // 引擎常驻在后台，页面走了就把它带走，别留着继续加载和回传。
    _store.detach();
    unawaited(
      _controller
          .loadRequest(Uri.parse('about:blank'))
          .catchError((Object _) {}),
    );
    super.dispose();
  }

  /// 启动：装垫片 → 打开收件页。
  ///
  /// 顺序不能反。`addDocumentStartJavaScript` 只对**之后**的文档
  /// 生效；先 loadRequest 再装就没有意义了，那一屏的 navigator
  /// 已经被站点和 Turnstile 读过。
  Future<void> _startUp() async {
    // 等 WebView widget 真正 attach 到视图树。
    // createPlatformWebView 只是造参数，原生实例要等下一帧布局后才有。
    try {
      await _webViewFuture;
    } catch (_) {
      // 造不出来就算了，下面照样尝试加载。
    }
    await Future<void>.delayed(const Duration(milliseconds: 120));
    final shimmed = await installBrowserShim();
    if (!shimmed) {
      debugPrint('浏览器垫片没装上（内核太老或找不到 WebView）');
    }
    if (!mounted) return;
    await _controller.loadRequest(Uri.parse(widget.number.inboxUrl));
  }

  /// 25 秒还没拿到任何东西，提示可能卡在风控上。
  void _onWatchdog() {
    if (!mounted || _store.state.messages.isNotEmpty) return;
    _store.note(
      _store.state.hits == 0 ? '25 秒没截获到接口响应，可能卡在站点的人机验证。' : '截获到了接口，但里面没有消息。',
    );
  }

  WebViewController _buildController() {
    return WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      // UA 由 browser_identity 统一管理：平时是稳定的默认值，
      // 用户点「换浏览器身份」时才换成随机的新组合，并且和号码目录
      // 那条原生 HTTP 保持同一个值。
      ..setUserAgent(currentUserAgent)
      // 引擎看不见，背景给个深色免得加载瞬间闪白。
      ..setBackgroundColor(const Color(0xFF10131A))
      ..addJavaScriptChannel(
        _kChannel,
        onMessageReceived: (JavaScriptMessage message) {
          _store.ingestRaw(message.message);
        },
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          // 只放行站点自己的域名。通道会把页面发来的 JSON 直接交给状态层，
          // 任何第三方页面拿到它都是不该有的攻击面。
          onNavigationRequest: (request) {
            final host = Uri.tryParse(request.url)?.host ?? '';
            if (host == _kAllowedHost || host.endsWith('.$_kAllowedHost')) {
              return NavigationDecision.navigate;
            }
            return NavigationDecision.prevent;
          },
          // 注入要抢在站点自己发首屏请求之前，否则只能等 DOM 扫描，
          // 那就是几秒起的延迟。onPageStarted 时 document 可能还没建好，
          // 注入失败无所谓——onPageFinished 会再补一次；JS 有 __fusInboxHooked
          // 守卫，重复注入不会叠加定时器。
          onPageStarted: (url) => unawaited(_injectQuietly()),
          onPageFinished: (url) {
            if (_wipeSiteStorageOnLoad) {
              _wipeSiteStorageOnLoad = false;
              unawaited(_wipeThenReload());
              return;
            }
            unawaited(_inject());
          },
          onWebResourceError: (error) {
            // isForMainFrame 是 bool?：null 表示不确定，别当成主框架失败。
            if (error.isForMainFrame == false) return;
            _store.fail('页面加载失败（${error.errorCode}）：${error.description}');
          },
        ),
      );
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
      await _controller.runJavaScript(script);
    } catch (e) {
      debugPrint('注入失败: $e');
    }
  }

  /// 早期注入：onPageStarted 时文档可能还不存在，失败是常态，不打印噪音。
  Future<void> _injectQuietly() async {
    final script = await _scriptFuture;
    if (script.isEmpty) return;
    try {
      await _controller.runJavaScript(script);
    } catch (_) {
      // 正常情况：document 还没建好。onPageFinished 会重试。
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
  Future<void> _rotateIdentity() async {
    final messenger = ScaffoldMessenger.of(context);
    _store.note('正在重置浏览器身份…');

    try {
      // 分三步，顺序不能换：
      //
      // 1) clearBrowsingData() —— 原生清 cookie / WebStorage / HTTP 凭据。
      //    必须在导航前调：它清的是「这个 WebView 里所有站点的数据」，
      //    和当前文档在哪个页面无关；先清掉能保证 next 这次加载是
      //    一个没有 cookie 的请求。
      //
      // 2) 设新 UA。
      //
      // 3) 打开收件页，等它 onPageFinished 那一刻删 IndexedDB，
      //    然后再重载一次（见 _wipeThenReload）。密钥必须卡在那个
      //    时间点删：about:blank 的 origin 碰不到站点库，
      //    而等站点自己发完请求再删，旧密钥已经用过了。
      final ok = await clearBrowsingData();

      final identity = rotateIdentity();
      await _controller.setUserAgent(identity.userAgent);

      // 下一次加载完成时删密钥，然后重载。
      _wipeSiteStorageOnLoad = true;
      _store.reset();
      _armWatchdog();
      await _controller.loadRequest(Uri.parse(widget.number.inboxUrl));

      if (!mounted) return;
      messenger
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(
            content: Text(
              ok
                  ? '已换新身份：${identity.model} · Chrome ${identity.chromeMajor}'
                  : 'UA 已换，但站点数据没清干净，可能仍被认成同一个人',
            ),
            duration: const Duration(milliseconds: 2200),
          ),
        );
    } catch (e) {
      debugPrint('换身份失败: $e');
      if (!mounted) return;
      messenger
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text('换身份失败：$e')));
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
  Future<void> _wipeThenReload() async {
    await _clearSiteStorage();
    if (!mounted) return;
    _store.reset();
    _armWatchdog();
    try {
      await _controller.reload();
    } catch (e) {
      debugPrint('重载失败: $e');
    }
  }

  /// 在收件页里删掉站点自己的 IndexedDB 密钥。
  ///
  /// 必须在站点页面**加载完成之后立刻**执行，而且要在站点自己
  /// 发请求之前 —— 它会先用旧密钥签名。删完重载一次，
  /// 这次站点找不到密钥，会生成新的。
  Future<void> _clearSiteStorage() async {
    try {
      await _controller.runJavaScript('''
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

  try { localStorage.clear(); } catch (e) {}
  try { sessionStorage.clear(); } catch (e) {}

  var names = [];
  try {
    if (indexedDB.databases) {
      var dbs = await indexedDB.databases();
      for (var i = 0; i < dbs.length; i++) if (dbs[i] && dbs[i].name) names.push(dbs[i].name);
    }
  } catch (e) {}
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
      debugPrint('清站点存储失败: $e');
    }
  }

  /// 打开验证面板，并开始盯 cf_clearance。
  ///
  /// ## 为什么自动退出必须看 cookie，不能看 DOM
  ///
  /// 之前那版自动检测靠三个 DOM 条件：挑战容器消失 + 正文够长 +
  /// 有消息节点。问题是 `[class*=message]` 会命中导航和广告，
  /// 页面一加载就满足，面板开了立刻自己关，用户连验证框都看不到。
  /// 用户当时的原话是「只有我点完成才退」——那条路被整个删掉了。
  ///
  /// 但每次都要手点「完成」也烦。真正的解法是找一个**不会被误判**
  /// 的信号：`cf_clearance`。它是 Cloudflare 在验证通过后发下的
  /// HttpOnly cookie，站点自己不下这个就说明没通过，下了就是真过了。
  /// 没有第二种解释。
  ///
  /// 所以现在：打开面板 → 每 1.5 秒读一次原生 cookie →
  /// 看到 cf_clearance 才自动收起面板。读不到就继续等，
  /// 用户随时可以自己点「完成」。
  void _openChallenge() {
    setState(() => _showChallenge = true);
    _startClearancePoll();
  }

  void _startClearancePoll() {
    _clearancePoll?.cancel();
    final deadline = DateTime.now().add(_clearancePollWindow);
    _clearancePoll = Timer.periodic(const Duration(milliseconds: 1500), (
      timer,
    ) async {
      if (!mounted) {
        timer.cancel();
        return;
      }
      // 用户自己点了完成，就别再轮询。
      if (!_showChallenge) {
        timer.cancel();
        return;
      }
      if (DateTime.now().isAfter(deadline)) {
        timer.cancel();
        _store.note('等验证超时了。过了的话直接点「完成」即可。');
        return;
      }

      if (_clearanceBusy) return;
      _clearanceBusy = true;
      Map<String, String> cookies;
      try {
        cookies = await readCookies(widget.number.inboxUrl);
      } finally {
        _clearanceBusy = false;
      }
      final clearance = cookies['cf_clearance'];
      if (clearance == null || clearance.isEmpty) return;

      // 拿到了。这是站点自己发的通行证，不存在误判。
      timer.cancel();
      _clearancePoll = null;
      if (!mounted) return;
      // 通行证要交给原生 HTTP 那两条链路共用：
      // 号码目录和收录时间走的是 dart:io，不共享 WebView 的 cookie 库。
      // 不搬过去，同一个 App 里就有一条链路裸奔。
      rememberClearance(clearance);
      // 这两句都会走 store 的 onChanged → setState。所以下面那句
      // setState 只负责面板开关，不重复刷数据。
      _store.note('验证通过，已拿到站点通行证。');
      if (!mounted) return;
      setState(() => _showChallenge = false);
      // 面板收起来了，但页面可能还停在挑战页。重载一次，
      // 这次请求会带上 cf_clearance，站点直接放行。
      unawaited(_controller.reload());
      _armWatchdog();
    });
  }

  /// 重扫当前页面 DOM。不发网络请求，纯粹是把已经渲染出来的内容再读一遍。
  Future<void> _rescan() async {
    try {
      await _controller.runJavaScript(
        'window.__fusInbox && window.__fusInbox.rescan();',
      );
    } catch (e) {
      debugPrint('重扫失败: $e');
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
      await _controller.runJavaScript(
        'window.__fusInbox && window.__fusInbox.loadMore();',
      );
      // 看门狗：JS 可能因为拿不到号码 id、页面被风控、或注入没生效而
      // 一声不吭。没有这道兜底，转圈会一直转到用户杀掉页面。
      _loadMoreWatchdog?.cancel();
      _loadMoreWatchdog = Timer(const Duration(seconds: 15), () {
        if (!mounted) return;
        if (!_store.state.loadingMore) return;
        _store.markLoadingMore(done: true);
        _store.note('翻页超时，稍后再试');
      });
    } catch (e) {
      debugPrint('加载更多失败: $e');
      _store.markLoadingMore(done: true);
    }
  }

  /// 拼出可复制的整条短信：发送方 + 时间 + 正文。
  static String _fullText(InboxMessage m) {
    final buf = StringBuffer();
    if (m.sender.isNotEmpty) buf.writeln(m.sender);
    if (m.receivedAt.isNotEmpty) buf.writeln(m.receivedAt);
    buf.write(m.text);
    return buf.toString().trim();
  }

  Future<void> _copy(String text, String label) async {
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text('已复制$label $text'),
          duration: const Duration(milliseconds: 1100),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final s = _store.state;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.number.pretty, style: theme.textTheme.titleMedium),
            if (widget.number.regionLabel.isNotEmpty)
              Text(
                s.messages.isEmpty
                    ? widget.number.regionLabel
                    : '${widget.number.regionLabel} · ${s.messages.length} 条',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
        actions: [
          // 换浏览器身份：站点会按 UA 判断是不是同一个浏览器，
          // 卡验证时点一下换新身份比反复重载有用。
          IconButton(
            tooltip: '换浏览器身份',
            onPressed: _rotateIdentity,
            icon: const Icon(Icons.switch_account_outlined),
          ),
          // 常驻入口：之前只有「加载失败」时才露出这个按钮，
          // 一旦消息列表出来了就再也找不到它——而风控恰恰可能在
          // 列表出来后再次触发（翻页、刷新都会重新走站点会话）。
          IconButton(
            tooltip: '打开浏览器过验证',
            // 只打开面板，不做任何自动检测——退出完全由用户点「完成」决定。
            onPressed: _openChallenge,
            icon: const Icon(Icons.shield_outlined),
          ),
          IconButton(
            tooltip: '重新扫描',
            onPressed: _rescan,
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: '重新加载',
            onPressed: () {
              _store.reset();
              _armWatchdog();
              unawaited(_controller.reload());
            },
            icon: const Icon(Icons.restart_alt),
          ),
        ],
      ),
      body: Stack(
        children: [
          // 界面层铺满，永远可见。
          _buildList(s, theme),

          // 引擎层：整个页面树里**只有这一个** WebViewWidget 实例
          // （同一个 controller 挂两处会崩）。
          //
          // 用 Offstage 藏起来，而不是缩小到 1×1：
          //   - 布局照常跑完整尺寸，原生 WebView 拿到真实视口，媒体查询、
          //     懒加载、IntersectionObserver 都按正常手机尺寸算
          //   - 跳过绘制与命中测试，不占合成层，滚动不掉帧
          //   - 依然在 widget 树上，页面正常加载、JS 正常执行、消息正常回传
          //
          // 缩到 1×1 会让站点按 1 像素视口渲染，布局塌成一条、懒加载永不触发，
          // 反而拿不到数据——那是错的做法。
          // 用户点「过验证」时 offstage 置 false，同一个实例原地露出来。
          Positioned.fill(
            child: Offstage(
              offstage: !_showChallenge,
              child: FutureBuilder<WebViewWidget>(
                future: _webViewFuture,
                builder: (context, snap) =>
                    snap.hasData ? snap.data! : const SizedBox.shrink(),
              ),
            ),
          ),

          // 风控兜底：只在验证态浮一条顶栏，底下的引擎已经露出来了。
          if (_showChallenge) _buildChallengeBar(theme),
        ],
      ),
    );
  }

  Widget _buildList(InboxState s, ThemeData theme) {
    final prefs = ref.watch(prefsProvider);
    final shown = s.shown;
    if (s.messages.isEmpty) {
      return ColoredBox(
        color: theme.colorScheme.surface,
        child: RefreshIndicator(
          onRefresh: _rescan,
          child: ListView(
            // 可滚动，否则 RefreshIndicator 在内容不满一屏时拉不动。
            physics: const AlwaysScrollableScrollPhysics(),
            children: [
              SizedBox(height: MediaQuery.sizeOf(context).height * 0.10),
              _buildEmptyState(s, theme),
            ],
          ),
        ),
      );
    }

    return ColoredBox(
      color: theme.colorScheme.surface,
      child: RefreshIndicator(
        onRefresh: _rescan,
        child: NotificationListener<ScrollNotification>(
          // 滑到底自动拉下一页。用 ScrollNotification 而不是 ScrollController，
          // 是因为这里不想再管一个 controller 的生命周期。
          onNotification: (n) {
            // 只在「滚动结束」时判断，不是每一帧都判断。
            //
            // 之前是每个 ScrollUpdateNotification 都检查，一滑到底会连发
            // 十几次 revealMore()，本地存货瞬间全放完，再连发几次网络请求
            // —— 这就是「加载逻辑很垃圾」的根源。
            // 改成只认 ScrollEndNotification：一次滑动最多触发一次。
            if (n is! ScrollEndNotification) return false;
            if (n.metrics.pixels < n.metrics.maxScrollExtent - 160) {
              return false;
            }
            if (s.loadingMore) return false;

            if (s.heldBack > 0) {
              // 本地存货一次放一屏左右，不要一把全倒出来。
              _store.revealMore();
            } else {
              unawaited(_loadMore());
            }
            return false;
          },
          // 卡片自带 8dp 间距，不再画分隔线。
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
            // 只渲染 s.shown（首屏 5 条），不是全部 24 条。
            // 末尾多一项：翻页脚注。
            itemCount: shown.length + 1,
            itemBuilder: (context, i) {
              if (i == shown.length) {
                return _buildFooter(s, theme);
              }
              return _MessageTile(
                message: shown[i],
                translate: prefs.translate,
                showOriginal: prefs.showOriginal,
                fontScale: prefs.fontScale,
                onCopyCode: (c) => _copy(c, '验证码'),
                // 长按复制整条正文（含发送方和时间），不再「有码就只复制码」——
                // 用户长按多半是想拿全文，替他决定只给验证码是越权。
                onCopyAll: () => _copy(_fullText(shown[i]), '整条短信'),
              );
            },
          ),
        ),
      ),
    );
  }

  /// 列表末尾的翻页脚注。
  ///
  /// 三种状态：正在拉（转圈）、到底了（一行灰字）、还能拉（给个明确的按钮，
  /// 自动加载没触发时用户也能手动点）。
  Widget _buildFooter(InboxState s, ThemeData theme) {
    final scheme = theme.colorScheme;

    if (s.loadingMore) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 20),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              width: 13,
              height: 13,
              child: CircularProgressIndicator(
                strokeWidth: 1.8,
                color: scheme.primary,
              ),
            ),
            const SizedBox(width: 9),
            Text(
              '正在加载更早的消息…',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    }

    // 本地还有存货：明确告诉用户还剩多少，点一下放开。
    if (s.heldBack > 0) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: Center(
          child: TextButton(
            onPressed: () => _store.revealMore(),
            child: Text('还有 ${s.heldBack} 条，显示更多'),
          ),
        ),
      );
    }

    if (!s.hasMore) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 20),
        child: Center(
          child: Text(
            '没有更早的消息了',
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Center(
        child: TextButton(onPressed: _loadMore, child: const Text('加载更早的消息')),
      ),
    );
  }

  /// 风控兜底：只在用户主动点「卡在人机验证？」时出现。
  ///
  /// 空状态：骨架卡片 + 一行状态 + 两个小按钮。
  ///
  /// 之前是整屏居中的转圈 + 一大段文字，视觉上像崩了。改成骨架屏——
  /// 用户一眼就知道「消息正在来的路上」，而不是「这页面卡住了」。
  /// 站点拒绝时的说明。
  ///
  /// 以前这块完全没有：站点的 429/403/503 响应体里没有 messages，
  /// 注入脚本当作「空」跳过，界面就一直卡在骨架屏转圈。
  /// 用户看到的是「软件坏了」，实际是站点在明确说不行。
  Widget _buildHoldState(SiteHold hold, ThemeData theme) {
    final scheme = theme.colorScheme;
    final (icon, tint) = switch (hold.kind) {
      SiteHoldKind.quota => (Icons.hourglass_disabled, scheme.tertiary),
      SiteHoldKind.challenge => (Icons.shield_outlined, scheme.primary),
      SiteHoldKind.temporary => (Icons.cloud_sync_outlined, scheme.secondary),
    };

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
      child: Column(
        children: [
          Icon(icon, size: 42, color: tint),
          const SizedBox(height: 14),
          Text(
            hold.title.isEmpty ? '站点暂时不给消息' : hold.title,
            textAlign: TextAlign.center,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            hold.message,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: scheme.onSurfaceVariant,
              height: 1.5,
            ),
          ),
          if (hold.retrySeconds > 0) ...[
            const SizedBox(height: 8),
            Text(
              '站点建议 ${hold.retrySeconds} 秒后再试',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
          const SizedBox(height: 18),

          // 配额和验证都要用户动手；临时繁忙只要等。
          if (hold.kind == SiteHoldKind.challenge)
            FilledButton.tonalIcon(
              onPressed: _openChallenge,
              icon: const Icon(Icons.shield_outlined, size: 18),
              label: const Text('打开页面过验证'),
            )
          else if (hold.kind == SiteHoldKind.quota)
            FilledButton.tonalIcon(
              onPressed: _rescan,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('再试一次'),
            )
          else
            FilledButton.tonalIcon(
              onPressed: _rescan,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('重试'),
            ),
          const SizedBox(height: 4),
          TextButton(
            onPressed: () => Navigator.of(context).maybePop(),
            child: const Text('换个号码'),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState(InboxState s, ThemeData theme) {
    final failed = s.phase == InboxPhase.failed;
    final scheme = theme.colorScheme;

    // 站点主动拒绝：这不是错误，是它明确说「现在不给」。
    // 单独一块，因为它需要的动作和「加载失败」完全不同——
    // 失败是重试，配额是等或换号，验证是去过验证。
    if (s.hold != null) return _buildHoldState(s.hold!, theme);

    if (failed) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
        child: Column(
          children: [
            Icon(Icons.cloud_off, size: 40, color: scheme.error),
            const SizedBox(height: 14),
            Text(
              s.status,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 18),
            FilledButton.tonalIcon(
              onPressed: _rescan,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('重试'),
            ),
            const SizedBox(height: 6),
            TextButton(
              onPressed: _openChallenge,
              child: const Text('打开浏览器自己过验证'),
            ),
          ],
        ),
      );
    }

    // 骨架：三条占位卡，形状和真实消息一致，来了就原地替换。
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 18, 16, 12),
          child: Row(
            children: [
              SizedBox(
                width: 13,
                height: 13,
                child: CircularProgressIndicator(
                  strokeWidth: 1.8,
                  color: scheme.primary,
                ),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  s.status,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
        for (var i = 0; i < 3; i++) _SkeletonTile(theme: theme),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
          child: Text(
            '停在这是因为要等站点把消息推过来，通常几秒。',
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }

  /// 验证态的顶栏。
  ///
  /// 此时引擎已经通过 Offstage 露出来了（占满 body），用户可以直接在页面上
  /// 过验证、点按钮。这里只叠一条提示，告诉他过完怎么回去——
  /// 不要覆盖引擎区域，那样点不到底下的验证控件。
  Widget _buildChallengeBar(ThemeData theme) {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Material(
        color: theme.colorScheme.surfaceContainerHigh,
        elevation: 4,
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '在上面过掉站点验证。通过后会自动收起；'
                    '不想等就点右边。',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                TextButton(
                  // 自动收起的判定看 cf_clearance（见 _startClearancePoll），
                  // 不看 DOM —— DOM 猜不准，会把导航和广告当成通过。
                  // 这个按钮是手动兜底：用户不想等、或站点没发 cookie
                  // 但页面其实能用了，点它直接回列表。
                  onPressed: () {
                    _clearancePoll?.cancel();
                    _clearancePoll = null;
                    setState(() => _showChallenge = false);
                    unawaited(_rescan());
                  },
                  child: const Text('完成'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 骨架卡：给「消息还没到」一个形状，而不是空白转圈。
class const _SkeletonTile({required this.theme}) extends StatelessWidget {
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    final base = theme.colorScheme.onSurface.withValues(alpha: 0.07);
    Widget bar(double w, double h) => Container(
      width: w,
      height: h,
      decoration: BoxDecoration(
        color: base,
        borderRadius: BorderRadius.circular(h / 2),
      ),
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: bar(110, 11)),
              bar(52, 10),
            ],
          ),
          const SizedBox(height: 12),
          bar(double.infinity, 11),
          const SizedBox(height: 7),
          bar(220, 11),
        ],
      ),
    );
  }
}

/// 正文字体样式，按设置里的缩放倍数调整。
///
/// 只缩放 fontSize，不动 height：行高是相对字号的比例，
/// 跟着字号走的话大字号会变成一大片空白。这里固定行高雅一点。
TextStyle? _bodyStyle(ThemeData theme, double scale) {
  final base = theme.textTheme.bodyMedium;
  if (base == null) return null;
  final size = (base.fontSize ?? 14) * scale;
  return base.copyWith(fontSize: size, height: 1.45);
}

/// 译文和原文是否实质相同。
///
/// 站点偶尔返回「翻译后跟原来一样」的结果（专有名词、已是中文等），
/// 这种情况下再显示一遍原文只会让卡片变高、没有信息增量。
bool _sameText(String a, String b) =>
    a.trim().toLowerCase() == b.trim().toLowerCase();

/// 一条短信。
class const _MessageTile({
  required this.message,
  required this.onCopyCode,
  required this.onCopyAll,
  required this.translate,
  required this.showOriginal,
  required this.fontScale,
}) extends ConsumerStatefulWidget {
  final InboxMessage message;
  final void Function(String) onCopyCode;
  final VoidCallback onCopyAll;
  final bool translate;
  final bool showOriginal;

  /// 正文字号缩放，来自设置页。
  final double fontScale;

  @override
  ConsumerState<_MessageTile> createState() => _MessageTileState();
}

class _MessageTileState() extends ConsumerState<_MessageTile> {
  @override
  void initState() {
    super.initState();
    if (widget.translate) _kick();
  }

  @override
  void didUpdateWidget(_MessageTile old) {
    super.didUpdateWidget(old);
    // 用户刚在设置里打开翻译时，已经在屏幕上的那条也要开始翻。
    if (widget.translate && !old.translate) _kick();
  }

  void _kick() {
    final text = widget.message.text;
    if (text.isEmpty) return;
    // 在下一帧请求：initState 期间改 provider 状态会触发 Riverpod 警告。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(translationStoreProvider.notifier).request(text);
    });
  }

  /// 确保这条消息有一次翻译请求。
  ///
  /// 不能只在 initState 里踢一次：用户在设置里「清除翻译缓存」或切换
  /// 目标语言之后，卡片还在屏幕上、state 里的条目已经没了，
  /// 不补一次请求就永远停在原文。request() 自身按 key 去重，重复调用无害。
  void _ensureRequested(bool hasEntry) {
    if (!widget.translate || hasEntry) return;
    if (widget.message.text.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(translationStoreProvider.notifier).request(widget.message.text);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final message = widget.message;

    // 只有开了翻译才 watch 翻译状态，关着的时候不订阅，省一次 rebuild。
    TranslationEntry? entry;
    if (widget.translate && message.text.isNotEmpty) {
      entry = ref.watch(
        translationStoreProvider.select((m) => m[message.text.trim()]),
      );
      _ensureRequested(entry != null);
    }

    // 卡片式，和号码列表/设置页同一套：elevation:0、16dp 圆角、
    // surfaceContainerHighest 40% 底。「新消息」用一层淡主色叠上去，
    // 而不是整块换色——那样在深色主题下会跳出来很刺眼。
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Card(
        elevation: 0,
        margin: EdgeInsets.zero,
        color: message.isNew
            ? scheme.primaryContainer.withValues(alpha: 0.28)
            : scheme.surfaceContainerHighest.withValues(alpha: 0.4),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        clipBehavior: Clip.antiAlias,
        // SelectionArea：长按可以自由选择任意文字（只选验证码、只选一句、
        // 跨行选都行），系统自带选择手柄和「复制」菜单。
        //
        // 之前是 InkWell.onLongPress 一把抓走整条——那不是自由复制，
        // 是「只能全选」。而且 onLongPress 会抢走长按手势，
        // 导致正文根本没法选中。
        child: SelectionArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 顶行：发送方 + 时间 + 新标记
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        message.sender.isEmpty ? '未知发送方' : message.sender,
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (message.isNew) ...[
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          color: scheme.primary,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          '新',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: scheme.onPrimary,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                    ],
                    if (message.receivedAt.isNotEmpty)
                      Text(
                        relativeTime(message.receivedAt, null),
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    // 一键复制整条（发送方 + 时间 + 正文）。
                    // 和长按的自由选择是两个不同的需求：
                    // 长按选任意片段，这个按钮一次拿走全部。
                    IconButton(
                      tooltip: '复制整条',
                      onPressed: widget.onCopyAll,
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints.tightFor(
                        width: 32,
                        height: 32,
                      ),
                      iconSize: 16,
                      icon: Icon(Icons.copy_rounded, color: scheme.outline),
                    ),
                  ],
                ),
                const SizedBox(height: 8),

                // 验证码：有就放大成按钮，一点即复制。
                if (message.hasCode)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: FilledButton.tonalIcon(
                      onPressed: () => widget.onCopyCode(message.code),
                      icon: const Icon(Icons.copy_all, size: 18),
                      label: Text(
                        message.code,
                        style: theme.textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                          letterSpacing: 3,
                        ),
                      ),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(0, 52),
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                      ),
                    ),
                  ),

                // 正文：开了翻译就先给译文，原文按需保留。
                if (message.text.isNotEmpty) ...[
                  if (entry != null && entry.loading)
                    Row(
                      children: [
                        SizedBox(
                          width: 11,
                          height: 11,
                          child: CircularProgressIndicator(
                            strokeWidth: 1.6,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(width: 7),
                        Text(
                          '翻译中…',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    )
                  else if (entry != null && entry.text.isNotEmpty) ...[
                    Text(
                      entry.text,
                      style: _bodyStyle(theme, widget.fontScale),
                      maxLines: 10,
                      overflow: TextOverflow.ellipsis,
                    ),
                    // 打开「保留原文」时才显示下面这段，否则卡片只是更高。
                    if (widget.showOriginal &&
                        !_sameText(entry.text, message.text))
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          message.text,
                          style: _bodyStyle(
                            theme,
                            widget.fontScale * 0.88,
                          )?.copyWith(color: scheme.onSurfaceVariant),
                          maxLines: 6,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ] else
                    Text(
                      message.text,
                      style: _bodyStyle(theme, widget.fontScale),
                      maxLines: 8,
                      overflow: TextOverflow.ellipsis,
                    ),
                ],

                if (message.isProtected)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      '这条被站点临时标为不可读，稍后刷新。',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.error,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
