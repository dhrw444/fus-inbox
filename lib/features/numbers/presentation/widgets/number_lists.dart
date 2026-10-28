/// 号码目录的两种列表布局：平铺、「按州」分组。
///
/// 从 `numbers_screen.dart` 的 `_body` / `_stateGrouped` 搬出来。
/// 两者都用 [NumberCard]，差别只在分组标题 —— 放同一个文件里，
/// 改卡片接线时两边不会漂。
///
/// 卡片自带 8dp 外边距，所以两个列表都不画分隔线：卡片 + 细线
/// 同时出现会变成「双边界」，看着很脏。
library;

import 'package:fus_inbox/features/numbers/domain/available_number.dart';
import 'package:fus_inbox/features/numbers/domain/state_names.dart';
import 'package:fus_inbox/features/numbers/presentation/widgets/number_card.dart';
import 'package:material_ui/material_ui.dart';

/// 平铺列表。
class const NumberList({
  required this.items,
  required this.saved,
  required this.firstSeen,
  required this.onTap,
  required this.onCopy,
  required this.onToggleSave,
  required this.onRefresh,
  super.key,
}) extends StatelessWidget {
  final List<AvailableNumber> items;
  final Set<String> saved;
  final Map<String, DateTime> firstSeen;

  final void Function(AvailableNumber number) onTap;
  final void Function(AvailableNumber number) onCopy;
  final void Function(String id) onToggleSave;

  /// 下拉刷新。列表自己包 RefreshIndicator —— 两种布局都必须是可滚动的，
  /// 否则内容不满一屏时手势拉不动（之前分两处写，容易只改一处）。
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: onRefresh,
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 20),
        itemCount: items.length,
        itemBuilder: (context, i) {
          final n = items[i];
          // key 用站点 id：收藏/复制都指向同一条，重排时 Element 能复用。
          return NumberCard(
            key: ValueKey(n.id),
            number: n,
            saved: saved.contains(n.id),
            firstSeen: firstSeen[n.number],
            onTap: () => onTap(n),
            onCopy: () => onCopy(n),
            onToggleSave: () => onToggleSave(n.id),
          );
        },
      ),
    );
  }
}

/// 按州分组：州名做小标题，方便按地区挑号。
class const StateGroupedNumberList({
  required this.items,
  required this.saved,
  required this.firstSeen,
  required this.onTap,
  required this.onCopy,
  required this.onToggleSave,
  required this.onRefresh,
  super.key,
}) extends StatelessWidget {
  final List<AvailableNumber> items;
  final Set<String> saved;
  final Map<String, DateTime> firstSeen;

  final void Function(AvailableNumber number) onTap;
  final void Function(AvailableNumber number) onCopy;
  final void Function(String id) onToggleSave;

  /// 下拉刷新。列表自己包 RefreshIndicator —— 两种布局都必须是可滚动的，
  /// 否则内容不满一屏时手势拉不动（之前分两处写，容易只改一处）。
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 每次都在 build 里分组：目录最多百来条，O(N) 分组耗时可忽略，
    // 缓存分组结果反而要在 state 里多养一份「必须手动失效」的真相。
    final groups = <String, List<AvailableNumber>>{};
    for (final n in items) {
      // 分组标题直接用中文州名，否则「按州」页里全是 Georgia / Florida。
      final zh = stateZh(n.state);
      final key = zh.isEmpty ? '其他' : zh;
      groups.putIfAbsent(key, () => []).add(n);
    }
    final keys = groups.keys.toList()..sort();

    return RefreshIndicator(
      onRefresh: onRefresh,
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 20),
        itemCount: keys.length,
        itemBuilder: (context, i) {
          final key = keys[i];
          final list = groups[key]!;
          return Column(
            key: ValueKey('state-$key'),
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 州名标题：和设置页的分组标题同一套样式（主色 + 加粗，
              // 左边留一点缩进对齐卡片内文字），右边跟一个号码数。
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
                child: Row(
                  children: [
                    Text(
                      key,
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: theme.colorScheme.primary,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.3,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '${list.length} 个',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              for (final n in list)
                NumberCard(
                  key: ValueKey(n.id),
                  number: n,
                  saved: saved.contains(n.id),
                  firstSeen: firstSeen[n.number],
                  onTap: () => onTap(n),
                  onCopy: () => onCopy(n),
                  onToggleSave: () => onToggleSave(n.id),
                ),
              const SizedBox(height: 8),
            ],
          );
        },
      ),
    );
  }
}
