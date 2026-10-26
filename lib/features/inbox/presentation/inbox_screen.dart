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

  /// 站点要求人工过风控时，临时露一次页面。平时恒为 false。
  bool _showChallenge = false;

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
    unawaited(_controller.loadRequest(Uri.parse(widget.number.inboxUrl)));
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
    // 引擎常驻在后台，页面走了就把它带走，别留着继续加载和回传。
    _store.detach();
    unawaited(
      _controller
          .loadRequest(Uri.parse('about:blank'))
          .catchError((Object _) {}),
    );
    super.dispose();
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
          onPageFinished: (url) => unawaited(_inject()),
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
  /// 站点会判断「是不是同一个浏览器」：UA 固定会让 Cloudflare 的挑战变严，
  /// 表现就是一直转圈拿不到短信。
  ///
  /// **只换 UA，不碰任何本地数据**：
  ///   - 不清 cookie / 缓存 / localStorage —— 那会把用户的收藏、
  ///     已缓存的号码和译文缓存一起洗掉
  ///   - 只做两件事：设新 UA + 重新加载这个收件页
  ///
  /// 换完只影响这一个 WebView 实例的请求特征，App 自己的磁盘缓存原封不动。
  Future<void> _rotateIdentity() async {
    final messenger = ScaffoldMessenger.of(context);
    _store.note('正在更换浏览器身份…');

    try {
      final ua = rotateUserAgent();
      await _controller.setUserAgent(ua);

      // 重置的只是这个页面的内存状态（已抓到的消息、看门狗），
      // 和磁盘上的目录缓存 / 收录时间缓存无关。
      _store.reset();
      _armWatchdog();
      await _controller.loadRequest(Uri.parse(widget.number.inboxUrl));

      if (!mounted) return;
      messenger
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(
            content: Text('已换新身份：${_shortUa(ua)}'),
            duration: const Duration(milliseconds: 1800),
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

  /// UA 太长，提示里只留关键片段。
  static String _shortUa(String ua) {
    final m = RegExp(r'Android ([\d.]+); ([^)]+)\)').firstMatch(ua);
    final c = RegExp(r'Chrome/([\d.]+)').firstMatch(ua);
    if (m == null) return ua;
    return '${m.group(2)!.trim()} · Chrome ${c?.group(1) ?? ''}';
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
      Timer(const Duration(seconds: 15), () {
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
            onPressed: () => setState(() => _showChallenge = true),
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
            if (n.metrics.pixels >= n.metrics.maxScrollExtent - 240) {
              // 先放本地已有的（站点一次给了 24 条，只是没全摆出来），
              // 本地放完了才真的去站点要更早的一页。
              // 这样翻页请求是「用户真的看完了」才发生，而不是一打开就连发。
              if (s.heldBack > 0) {
                _store.revealMore();
              } else {
                unawaited(_loadMore());
              }
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
                onCopyAll: () => _copy(
                  shown[i].code.isNotEmpty ? shown[i].code : shown[i].text,
                  shown[i].code.isNotEmpty ? '验证码' : '正文',
                ),
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
  Widget _buildEmptyState(InboxState s, ThemeData theme) {
    final failed = s.phase == InboxPhase.failed;
    final scheme = theme.colorScheme;

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
              onPressed: () => setState(() => _showChallenge = true),
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
                    '在上面过掉站点验证，完成后点右边回短信列表。',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                TextButton(
                  onPressed: () {
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
        child: InkWell(
          onLongPress: widget.onCopyAll,
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
