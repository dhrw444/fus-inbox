import 'package:material_ui/material_ui.dart';

import 'package:fus_inbox/core/time/site_time.dart';
import 'package:fus_inbox/features/numbers/domain/available_number.dart';

/// 号码卡片。
///
/// 布局要点：整行用 [CrossAxisAlignment.center] 让星标与两行文字垂直居中。
/// 之前的 `start` 对齐 + 默认 [IconButton]（48×48 最小点击区）把行撑高，
/// 星标看起来浮在下方、和号码基线错位。这里改成紧凑图标按钮 + center 对齐。
class const NumberCard({
  required this.number,
  required this.saved,
  required this.onTap,
  required this.onToggleSave,
  this.now,
  super.key,
}) extends StatelessWidget {
  final AvailableNumber number;
  final bool saved;
  final VoidCallback onTap;
  final VoidCallback onToggleSave;
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final fresh = number.isFresh;

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 4, 10),
        child: Row(
          children: [
            // 活跃指示灯：绿点表示最近有短信进来。
            Container(
              width: 8,
              height: 8,
              margin: const EdgeInsets.only(right: 10),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: fresh ? const Color(0xFF34C759) : scheme.outlineVariant,
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 第一行只放号码。条数挪到第二行，避免和号码抢宽度——
                  // 长号码 + 徽章挤在一起时，号码会被省略号截断。
                  Text(
                    number.pretty,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.2,
                    ),
                  ),
                  const SizedBox(height: 4),
                  // 第二行：州名 · 区号 · 条数 · 时间，一条水平线排开。
                  Row(
                    children: [
                      if (number.regionLabel.isNotEmpty) ...[
                        Icon(
                          Icons.place_outlined,
                          size: 13,
                          color: scheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 3),
                        Flexible(
                          child: Text(
                            number.regionLabel,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                      if (number.messageCount > 0) ...[
                        const SizedBox(width: 8),
                        _Pill(
                          text: '${number.messageCount} 条',
                          bg: scheme.secondaryContainer,
                          fg: scheme.onSecondaryContainer,
                          theme: theme,
                        ),
                      ],
                      if (number.lastTextAt != null) ...[
                        const SizedBox(width: 8),
                        Icon(
                          Icons.schedule,
                          size: 13,
                          color: scheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 3),
                        Flexible(
                          child: Text(
                            relativeTime(number.lastTextAt!, now),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: fresh
                                  ? scheme.primary
                                  : scheme.onSurfaceVariant,
                              fontWeight: fresh ? FontWeight.w600 : null,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            // 用 32×32 的紧凑按钮，避免默认 48 把行撑高。
            IconButton(
              tooltip: saved ? '取消收藏' : '收藏',
              onPressed: onToggleSave,
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints.tightFor(width: 40, height: 40),
              iconSize: 20,
              icon: Icon(
                saved ? Icons.star_rounded : Icons.star_border_rounded,
                color: saved ? scheme.primary : scheme.outline,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 小圆角标签，用于条数、州名这类附注。
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
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        text,
        style: theme.textTheme.labelSmall?.copyWith(
          color: fg,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
