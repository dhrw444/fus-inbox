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
          // 文档就绪后才注入；onPageStarted 阶段 document 还不存在。
          onPageFinished: (url) => unawaited(_inject()),
          onWebResourceError: (error) {
            if (error.isForMainFrame == false) return;
            _store.fail('页面加载失败（${error.errorCode}）：${error.description}');
          },
        ),
      );
  }

  /// 注入中的标记。
  ///
  /// `onPageFinished` 在每次导航完成后都会触发——站点有重定向、风控跳转，
  /// 一次打开可能触发三四次。没有这道闸，注入就叠三四遍，
  /// 每遍都会重启一整套 setTimeout/setInterval，请求量直接乘上去。
  bool _injecting = false;

  Future<void> _inject() async {
    if (_injecting) return;
    _injecting = true;
    try {
      final script = await _scriptFuture;
      if (script.isEmpty) return;
      await _controller.runJavaScript(script);
    } catch (e) {
      debugPrint('注入失败: $e');
    } finally {
      // 留一点余量再放开：页面内重定向往往在同一个 tick 里连着触发。
      await Future<void>.delayed(const Duration(milliseconds: 600));
      _injecting = false;
    }
  }

  Future<void> _rescan() async {
    try {
      await _controller.runJavaScript(
        'window.__fusInbox && window.__fusInbox.rescan();',
      );
    } catch (e) {
      debugPrint('重扫失败: $e');
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
          // 引擎层：常驻、永不卸载。整个页面树里**只有这一个** WebViewWidget
          // 实例——同一个 controller 挂两处会崩，所以验证态靠"不盖列表"来露出它。
          Positioned.fill(
            child: FutureBuilder<WebViewWidget>(
              future: _webViewFuture,
              builder: (context, snap) =>
                  snap.hasData ? snap.data! : const SizedBox.shrink(),
            ),
          ),
          // 界面层：不透明，盖死引擎。验证态时不渲染，引擎自然露出来。
          if (!_showChallenge) Positioned.fill(child: _buildList(s, theme)),
          if (_showChallenge) _buildChallengeBar(theme),
        ],
      ),
    );
  }

  Widget _buildList(InboxState s, ThemeData theme) {
    final prefs = ref.watch(prefsProvider);
    if (s.messages.isEmpty) {
      final failed = s.phase == InboxPhase.failed;
      return ColoredBox(
        color: theme.colorScheme.surface,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!failed)
                  const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2.4),
                  )
                else
                  Icon(
                    Icons.error_outline,
                    size: 36,
                    color: theme.colorScheme.error,
                  ),
                const SizedBox(height: 16),
                Text(
                  s.status,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 20),
                Wrap(
                  spacing: 8,
                  alignment: WrapAlignment.center,
                  children: [
                    OutlinedButton.icon(
                      onPressed: _rescan,
                      icon: const Icon(Icons.refresh, size: 18),
                      label: const Text('再试一次'),
                    ),
                    TextButton.icon(
                      onPressed: () => setState(() => _showChallenge = true),
                      icon: const Icon(Icons.verified_user_outlined, size: 18),
                      label: const Text('卡在人机验证？'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
    }

    return ColoredBox(
      color: theme.colorScheme.surface,
      child: RefreshIndicator(
        onRefresh: _rescan,
        child: ListView.separated(
          padding: const EdgeInsets.only(bottom: 24),
          itemCount: s.messages.length,
          separatorBuilder: (context, i) => const Divider(height: 1),
          itemBuilder: (context, i) => _MessageTile(
            message: s.messages[i],
            translate: prefs.translate,
            showOriginal: prefs.showOriginal,
            onCopyCode: (c) => _copy(c, '验证码'),
            onCopyAll: () => _copy(
              s.messages[i].code.isNotEmpty
                  ? s.messages[i].code
                  : s.messages[i].text,
              s.messages[i].code.isNotEmpty ? '验证码' : '正文',
            ),
          ),
        ),
      ),
    );
  }

  /// 风控兜底：只在用户主动点「卡在人机验证？」时出现。
  ///
  /// 只是一条顶栏——底下的引擎此时已经露出来了（列表层不渲染），
  /// 用户可以在这里过验证。过完点「完成」回到短信列表。
  Widget _buildChallengeBar(ThemeData theme) {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: Material(
        color: theme.colorScheme.surfaceContainerHigh,
        elevation: 3,
        child: SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '请在这里过掉站点的人机验证，完成后回短信列表。',
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
}) extends ConsumerStatefulWidget {
  final InboxMessage message;
  final void Function(String) onCopyCode;
  final VoidCallback onCopyAll;
  final bool translate;
  final bool showOriginal;

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
    }

    return InkWell(
      onLongPress: onCopyAll,
      child: Container(
        color: message.isNew
            ? scheme.primaryContainer.withValues(alpha: 0.22)
            : null,
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
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
                  onPressed: () => onCopyCode(message.code),
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
                  style: theme.textTheme.bodyMedium,
                  maxLines: 10,
                  overflow: TextOverflow.ellipsis,
                ),
                // 打开「保留原文」时才显示下面这段，否则卡片只是更高。
                if (widget.showOriginal && !_sameText(entry.text, message.text))
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      message.text,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                        height: 1.45,
                      ),
                      maxLines: 6,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ] else
                Text(
                  message.text,
                  style: theme.textTheme.bodyMedium,
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
    );
  }
}
