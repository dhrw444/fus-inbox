/// 一条短信卡片：外壳 + 顶栏（发送方 / 新标记 / 时间 / 复制整条）+ 验证码按钮。
///
/// 正文（原文 / 译文 / 翻译中）在 `message_body.dart` —— 那里是纯排版，
/// 这里管「什么时候该请求翻译」。
///
/// ## 为什么这里要 State 而不是 StatelessWidget
///
/// 只为一件事：翻译请求的**触发时机**。`initState`（首次上屏）、
/// `didUpdateWidget`（用户刚在设置里打开翻译）、以及 `build` 里
/// 「条目没了但卡片还在」（清缓存 / 换引擎）三种情况都要踢一次。
/// 排版本身是纯的，所以只有这一小块需要状态。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fus_inbox/core/time/site_time.dart';
import 'package:fus_inbox/core/translate/translation_provider.dart';
import 'package:fus_inbox/features/inbox/domain/inbox_message.dart';
import 'package:fus_inbox/features/inbox/presentation/widgets/message_body.dart';
import 'package:material_ui/material_ui.dart';

export 'package:fus_inbox/features/inbox/presentation/widgets/message_body.dart'
    show bodyStyle, sameText;

/// 一条短信。
class const MessageTile({
  required this.message,
  required this.onCopyCode,
  required this.onCopyAll,
  required this.translate,
  required this.showOriginal,
  required this.fontScale,
  super.key,
}) extends ConsumerStatefulWidget {
  final InboxMessage message;
  final void Function(String) onCopyCode;
  final VoidCallback onCopyAll;
  final bool translate;
  final bool showOriginal;

  /// 正文字号缩放，来自设置页。
  final double fontScale;

  @override
  ConsumerState<MessageTile> createState() => MessageTileState();
}

class MessageTileState() extends ConsumerState<MessageTile> {
  @override
  void initState() {
    super.initState();
    if (widget.translate) _requestIfNeeded(force: true);
  }

  @override
  void didUpdateWidget(MessageTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 用户刚在设置里打开翻译时，已经在屏幕上的那条也要开始翻。
    if (widget.translate && !oldWidget.translate) _requestIfNeeded(force: true);
  }

  /// 请求一次翻译。
  ///
  /// 三个触发点共用这一处，它们要的动作完全一样 —— 以前是两段几乎逐字
  /// 相同的代码，改一处忘一处就会有一个触发点失效：
  ///
  /// | 触发点 | 何时 |
  /// |---|---|
  /// | `initState` | 首次上屏 |
  /// | `didUpdateWidget` | 用户刚在设置里打开翻译 |
  /// | `build` | 清缓存 / 换引擎之后条目没了，但卡片还在屏幕上 |
  ///
  /// [force] 为 true 表示「不管条目在不在都发一次」（前两个触发点用）；
  /// 为 false 表示「只在条目确实不存在时才补一次」（`build` 里用 ——
  /// 那时 [entry] 是刚 watch 到的值，传 null 就说明条目没了）。
  ///
  /// 在下一帧请求：initState 期间改 provider 状态会触发 Riverpod 警告。
  /// `request()` 自身按 key 去重，重复调用无害。
  void _requestIfNeeded({required bool force, TranslationEntry? entry}) {
    if (!widget.translate) return;
    if (!force && entry != null) return;
    final text = widget.message.text;
    if (text.isEmpty) return;
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
      _requestIfNeeded(force: false, entry: entry);
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
                MessageHeader(
                  message: message,
                  theme: theme,
                  onCopyAll: widget.onCopyAll,
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
                if (message.text.isNotEmpty)
                  MessageBody(
                    text: message.text,
                    entry: entry,
                    theme: theme,
                    fontScale: widget.fontScale,
                    showOriginal: widget.showOriginal,
                  ),

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

/// 卡片顶行：发送方 + 「新」标记 + 相对时间 + 复制整条。
class const MessageHeader({
  required this.message,
  required this.theme,
  required this.onCopyAll,
  super.key,
}) extends StatelessWidget {
  final InboxMessage message;
  final ThemeData theme;
  final VoidCallback onCopyAll;

  @override
  Widget build(BuildContext context) {
    final scheme = theme.colorScheme;
    return Row(
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
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
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
          onPressed: onCopyAll,
          visualDensity: VisualDensity.compact,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints.tightFor(width: 32, height: 32),
          iconSize: 16,
          icon: Icon(Icons.copy_rounded, color: scheme.outline),
        ),
      ],
    );
  }
}
