/// freeussms 收件箱主界面。
///
/// 结构：`Stack` 下层是常驻的 WebView（页面必须活着——Turnstile 与每请求
/// WebCrypto 签名都在页面自己的 JS 里跑），上层是原生 Material 列表。
/// 数据由注入脚本经 `FusInbox` 通道推上来，见 `assets/js/fus_inbox.js`。
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'package:freedium_mobile/features/inbox/application/inbox_provider.dart';
import 'package:freedium_mobile/features/inbox/domain/inbox_message.dart';
import 'package:freedium_mobile/features/webview/presentation/widgets/reader_webview.dart'
    show createReaderWebView;

/// 默认收件页。换号只改这里，或后续接一个号码选择器。
const kInboxDefaultUrl = 'https://freeussms.com/numbers/17573242429/';

const _kInjectAsset = 'assets/js/fus_inbox.js';
const _kChannel = 'FusInbox';

class InboxScreen extends ConsumerStatefulWidget {
  const InboxScreen({super.key, this.url = kInboxDefaultUrl});

  final String url;

  @override
  ConsumerState<InboxScreen> createState() => _InboxScreenState();
}

class _InboxScreenState extends ConsumerState<InboxScreen> {
  late final WebViewController _controller;
  late Future<WebViewWidget> _webViewFuture;

  String? _injectScript;
  bool _showWeb = true;
  bool _autoSwitched = false;

  @override
  void initState() {
    super.initState();
    _controller = _buildController();
    _webViewFuture = createReaderWebView(_controller);
    unawaited(_loadInjectScript());
    unawaited(_controller.loadRequest(Uri.parse(widget.url)));
  }

  Future<void> _loadInjectScript() async {
    try {
      _injectScript = await rootBundle.loadString(_kInjectAsset);
    } catch (e) {
      debugPrint('注入脚本读取失败: $e');
      if (mounted) {
        ref.read(inboxProvider.notifier).fail('注入脚本缺失：$e');
      }
    }
  }

  WebViewController _buildController() {
    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFF10131A))
      ..addJavaScriptChannel(
        _kChannel,
        onMessageReceived: (JavaScriptMessage message) {
          if (!mounted) return;
          ref.read(inboxProvider.notifier).ingestRaw(message.message);
          // 第一批数据到达后自动切到原生列表。
          if (!_autoSwitched &&
              ref.read(inboxProvider).messages.isNotEmpty &&
              mounted) {
            _autoSwitched = true;
            setState(() => _showWeb = false);
          }
        },
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (url) {
            // 页面开始加载时先埋一次钩子，尽量赶在页面自己的首次请求之前。
            unawaited(_inject());
          },
          onPageFinished: (url) async {
            // DOM 兜底扫描需要等页面渲染，脚本内部自带重试。
            await _inject();
          },
          onWebResourceError: (error) {
            if (error.isForMainFrame == false) return;
            if (!mounted) return;
            ref
                .read(inboxProvider.notifier)
                .fail('页面加载失败（${error.errorCode}）：${error.description}');
          },
        ),
      );
    return controller;
  }

  Future<void> _inject() async {
    final script = _injectScript ?? await _loadScriptOnce();
    if (script == null || script.isEmpty) return;
    try {
      await _controller.runJavaScript(script);
    } catch (e) {
      debugPrint('注入失败: $e');
    }
  }

  Future<String?> _loadScriptOnce() async {
    try {
      _injectScript = await rootBundle.loadString(_kInjectAsset);
    } catch (e) {
      debugPrint('注入脚本读取失败: $e');
      return null;
    }
    return _injectScript;
  }

  Future<void> _reload() async {
    ref.read(inboxProvider.notifier).reset();
    _autoSwitched = false;
    await _controller.reload();
  }

  Future<void> _rescan() async {
    // 让页面内的脚本立刻再扫一遍 DOM 并回传。
    try {
      await _controller.runJavaScript(
        'window.__fusInbox && window.__fusInbox.rescan();',
      );
    } catch (e) {
      debugPrint('重扫失败: $e');
    }
  }

  Future<void> _copy(String code) async {
    if (code.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: code));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text('已复制 $code'),
          duration: const Duration(milliseconds: 1200),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final inbox = ref.watch(inboxProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('SMS 收件箱'),
        actions: [
          if (inbox.newCount > 0)
            Center(
              child: Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Chip(
                  visualDensity: VisualDensity.compact,
                  label: Text('${inbox.newCount} 新'),
                ),
              ),
            ),
          IconButton(
            tooltip: '切到网页',
            onPressed: () => setState(() => _showWeb = true),
            icon: const Icon(Icons.public),
          ),
          IconButton(
            tooltip: '重新扫描',
            onPressed: _rescan,
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: '重新加载页面',
            onPressed: _reload,
            icon: const Icon(Icons.restart_alt),
          ),
        ],
      ),
      body: Stack(
        children: [
          // 下层：常驻 WebView，永不卸载（页面活着才有签名能力）。
          FutureBuilder<WebViewWidget>(
            future: _webViewFuture,
            builder: (context, snap) {
              if (!snap.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              return snap.data!;
            },
          ),
          // 上层：原生列表。
          if (!_showWeb) _MessageList(messages: inbox.messages, onCopy: _copy),
          if (_showWeb && inbox.messages.isNotEmpty)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: _BottomBar(
                inbox: inbox,
                onShowList: () => setState(() => _showWeb = false),
              ),
            ),
          if (_showWeb && inbox.messages.isEmpty)
            Positioned(
              left: 12,
              right: 12,
              bottom: 12,
              child: _HintCard(inbox: inbox, theme: theme),
            ),
        ],
      ),
      floatingActionButton: _showWeb
          ? null
          : FloatingActionButton.extended(
              onPressed: () => setState(() => _showWeb = true),
              icon: const Icon(Icons.public),
              label: Text(
                inbox.messages.isEmpty
                    ? '网页'
                    : '${inbox.messages.length} 条 · 网页',
              ),
            ),
    );
  }
}

class _MessageList extends StatelessWidget {
  const _MessageList({required this.messages, required this.onCopy});

  final List<InboxMessage> messages;
  final Future<void> Function(String) onCopy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (messages.isEmpty) {
      return ColoredBox(
        color: theme.colorScheme.surface,
        child: const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              '还没抓到短信。\n点右上角「网页」查看收件页状态——\n如果卡在验证，在网页里过一下即可。',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }
    return ColoredBox(
      color: theme.colorScheme.surface,
      child: ListView.separated(
        padding: const EdgeInsets.only(top: 4, bottom: 96),
        itemCount: messages.length,
        separatorBuilder: (context, index) => const Divider(height: 1),
        itemBuilder: (context, i) {
          final m = messages[i];
          return ListTile(
            onTap: () => onCopy(m.code),
            leading: Container(
              width: 76,
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(vertical: 6),
              decoration: BoxDecoration(
                color: m.code.isEmpty
                    ? theme.colorScheme.surfaceContainerHighest
                    : theme.colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                m.code.isEmpty ? '——' : m.code,
                style: theme.textTheme.titleLarge?.copyWith(
                  letterSpacing: 1.2,
                  color: m.code.isEmpty
                      ? theme.colorScheme.onSurfaceVariant
                      : theme.colorScheme.onPrimaryContainer,
                ),
              ),
            ),
            title: Text(
              m.text.isEmpty ? '(无正文)' : m.text,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: (m.phone.isEmpty && m.time.isEmpty)
                ? null
                : Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Wrap(
                      spacing: 6,
                      children: [
                        if (m.phone.isNotEmpty)
                          _Tag(text: m.phone, theme: theme),
                        if (m.time.isNotEmpty) _Tag(text: m.time, theme: theme),
                        if (m.isNew) _Tag(text: '新', theme: theme, busy: true),
                      ],
                    ),
                  ),
            trailing: const Icon(Icons.copy_rounded, size: 18),
          );
        },
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag({required this.text, required this.theme, this.busy = false});

  final String text;
  final ThemeData theme;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: busy
            ? theme.colorScheme.primary.withValues(alpha: 0.18)
            : theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        busy ? '$text 新' : text,
        style: theme.textTheme.labelSmall?.copyWith(
          color: busy
              ? theme.colorScheme.primary
              : theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _BottomBar extends StatelessWidget {
  const _BottomBar({required this.inbox, required this.onShowList});

  final InboxState inbox;
  final VoidCallback onShowList;

  @override
  Widget build(BuildContext context) {
    return Material(
      elevation: 8,
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      child: SafeArea(
        top: false,
        child: ListTile(
          onTap: onShowList,
          leading: const Icon(Icons.markunread_mailbox_outlined),
          title: Text('已抓到 ${inbox.messages.length} 条短信'),
          subtitle: Text(
            inbox.status,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: const Icon(Icons.keyboard_arrow_up),
        ),
      ),
    );
  }
}

class _HintCard extends StatelessWidget {
  const _HintCard({required this.inbox, required this.theme});

  final InboxState inbox;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Row(
          children: [
            SizedBox(
              width: 18,
              height: 18,
              child: inbox.phase == InboxPhase.failed
                  ? Icon(
                      Icons.error_outline,
                      size: 18,
                      color: theme.colorScheme.error,
                    )
                  : const CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(inbox.status, style: theme.textTheme.bodySmall),
            ),
          ],
        ),
      ),
    );
  }
}
