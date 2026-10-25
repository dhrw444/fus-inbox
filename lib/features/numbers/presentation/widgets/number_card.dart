/// 号码卡片。目录列表里一行一个号。
library;

import 'package:material_ui/material_ui.dart';

import 'package:fus_inbox/features/numbers/domain/available_number.dart';

class const NumberCard({
  super.key,
  required this.number,
  required this.onTap,
  required this.saved,
  required this.onToggleSave,
  this.now,
}) extends StatelessWidget {
  final AvailableNumber number;
  final VoidCallback onTap;
  final bool saved;
  final VoidCallback onToggleSave;

  /// 注入当前时间便于测试相对时间。
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final fresh = number.isFresh;

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 活跃指示灯：绿点表示最近有短信进来。
            Padding(
              padding: const EdgeInsets.only(top: 6, right: 12),
              child: Container(
                width: 9,
                height: 9,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: fresh
                      ? const Color(0xFF34C759)
                      : scheme.outlineVariant,
                ),
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          number.pretty,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0.2,
                          ),
                        ),
                      ),
                      if (number.messageCount > 0)
                        _Pill(
                          text: '${number.messageCount} 条',
                          bg: scheme.secondaryContainer,
                          fg: scheme.onSecondaryContainer,
                          theme: theme,
                        ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      if (number.regionLabel.isNotEmpty) ...[
                        Icon(
                          Icons.place_outlined,
                          size: 14,
                          color: scheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 3),
                        Text(
                          number.regionLabel,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(width: 10),
                      ],
                      if (number.lastTextAt != null) ...[
                        Icon(
                          Icons.schedule,
                          size: 14,
                          color: scheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 3),
                        Text(
                          relativeTime(number.lastTextAt!, now),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: fresh
                                ? scheme.primary
                                : scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: saved ? '取消收藏' : '收藏',
              onPressed: onToggleSave,
              icon: Icon(
                saved ? Icons.star : Icons.star_border,
                color: saved ? scheme.primary : scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class const _Pill({
  required this.text,
  required this.bg,
  required this.fg,
  required this.theme,
}) extends StatelessWidget {
  final String text;
  final Color bg;
  final Color fg;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(text, style: theme.textTheme.labelSmall?.copyWith(color: fg)),
    );
  }
}

/// 把 ISO 时间转成「3 分钟前」这类短文案。
String relativeTime(String iso, DateTime? now) {
  final t = DateTime.tryParse(iso);
  if (t == null) return iso;
  final delta = (now ?? DateTime.now()).difference(t);
  if (delta.inSeconds < 60) return '刚刚';
  if (delta.inMinutes < 60) return '${delta.inMinutes} 分钟前';
  if (delta.inHours < 24) return '${delta.inHours} 小时前';
  if (delta.inDays < 30) return '${delta.inDays} 天前';
  return '${(delta.inDays / 30).floor()} 个月前';
}
