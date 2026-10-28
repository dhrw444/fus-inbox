/// 号码列表里的一张卡片。
///
/// 显示号码、州、区号、短信条数和收录时间，并提供复制/收藏。
/// 号码页和收藏页共用它（收藏页不传 [now]，时间相对当前时刻算）。
/// 单独一个文件是为了让 `numbers_screen` 只管编排，不掺排版。
library;

import 'package:fus_inbox/core/time/site_time.dart';
import 'package:fus_inbox/features/numbers/domain/available_number.dart';
import 'package:material_ui/material_ui.dart';

/// 号码卡片。
///
/// 视觉语言和设置页一致：一张 elevation:0 + 16dp 圆角的浅色卡片，
/// 卡片内部靠留白分层，不画分隔线。
///
/// 层级设计：
///   1. 号码 —— 最大最黑，一眼能读
///   2. 州·区号 + 条数 + 最后时间 —— 次级信息，统一降到 bodySmall 灰
///   3. 收录时间 —— 最次要，独立一行，没有就不渲染
///
/// 右侧两个按钮给 40/44 的紧凑尺寸：默认 48 会把行撑高，
/// 星标会和文字基线错位。
class const NumberCard({
  required this.number,
  required this.saved,
  required this.onTap,
  required this.onToggleSave,
  required this.onCopy,
  this.firstSeen,
  this.now,
  super.key,
}) extends StatelessWidget {
  final AvailableNumber number;
  final bool saved;
  final VoidCallback onTap;
  final VoidCallback onToggleSave;

  /// 复制号码。
  final VoidCallback onCopy;

  /// 号码首次被站点收录的时间。缓存里没有就是 null —— 这时整行不渲染。
  final DateTime? firstSeen;

  /// 「现在」的注入点，测试用；null 则用站点时间工具自己的当前时刻。
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final fresh = number.isFresh;

    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 8),
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
          child: Row(
            children: [
              // 活跃指示灯：绿点 = 最近有短信进来。
              Padding(
                padding: const EdgeInsets.only(right: 10),
                child: Container(
                  width: 8,
                  height: 8,
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
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // 第一层：号码。
                    Text(
                      number.pretty,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.3,
                      ),
                    ),
                    const SizedBox(height: 5),
                    // 第二层：州·区号、条数、最后时间。
                    Row(
                      children: [
                        if (number.regionLabel.isNotEmpty) ...[
                          Icon(
                            Icons.place_outlined,
                            size: 12,
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
                          const SizedBox(width: 10),
                        ],
                        if (number.messageCount > 0) ...[
                          _CountPill(
                            text: '${number.messageCount} 条',
                            // 有短信的号用主色系，没有的用中性色，
                            // 一眼能看出哪些号是「活的」。
                            bg: scheme.primaryContainer.withValues(alpha: 0.7),
                            fg: scheme.onPrimaryContainer,
                          ),
                          const SizedBox(width: 10),
                        ],
                        if (number.lastTextAt != null)
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
                    ),
                    // 第三层：收录时间。没有就不占位置。
                    if (firstSeen != null) ...[
                      const SizedBox(height: 3),
                      Text(
                        '收录于 ${relativeTime(firstSeen!.toIso8601String(), now)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant.withValues(alpha: 0.8),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              IconButton(
                tooltip: '复制号码',
                onPressed: onCopy,
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints.tightFor(
                  width: 40,
                  height: 44,
                ),
                iconSize: 18,
                icon: Icon(Icons.copy_rounded, color: scheme.outline),
              ),
              IconButton(
                tooltip: saved ? '取消收藏' : '收藏',
                onPressed: onToggleSave,
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints.tightFor(
                  width: 40,
                  height: 44,
                ),
                iconSize: 20,
                icon: Icon(
                  saved ? Icons.star_rounded : Icons.star_border_rounded,
                  color: saved ? scheme.primary : scheme.outline,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 条数徽章。数字用等宽感的粗体，和「条」拉开层次。
class const _CountPill({required this.text, required this.bg, required this.fg})
    extends StatelessWidget {
  final String text;
  final Color bg;
  final Color fg;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
