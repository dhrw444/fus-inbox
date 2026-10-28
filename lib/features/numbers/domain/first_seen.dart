/// 号码「首次被站点收录」时间的**解析**。纯函数，不碰 IO。
///
/// 站点把这个字段只放在号码详情页（`/numbers/<号码>/`）：
///
/// ```
/// First recorded in our directory   2026-10-25 23:20 UTC
/// ```
///
/// 列表页的卡片里只有 `data-rel-time`（最后一条短信时间），没有收录时间。
/// 所以只能按需抓：用户点开某个号的收件箱时顺手抓一次，结果永久缓存。
///
/// ## 为什么这里只有解析
///
/// 抓取、缓存、落盘、provider 全在
/// `application/first_seen_store.dart`。分开的理由和 `number_sort.dart`
/// 一样：这一层刻意不依赖 Flutter / SharedPreferences，**这样它能在纯 Dart
/// 里直接跑测试** —— 解析规则是那种「看着对但错了一个字符就全错」的代码，
/// 必须能脱离框架验。
library;

final _rowRe = RegExp(
  r'First recorded in our directory\s*</dt>\s*<dd>(.*?)</dd>',
  dotAll: true,
);
final _tagRe = RegExp(r'<[^>]+>');
final _isoRe = RegExp(
  r'(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2})(?::(\d{2}))?',
);

/// 从详情页 HTML 里抠出收录时间。
///
/// 一律按 UTC 解析 —— 原文标了 UTC，按本地时区解会整体偏 8 小时。
/// 没收录过的号那格是 `Not available`，这里返回 null。
///
/// **不是 `@visibleForTesting`**：生产链路上的 `fetchFirstSeen` 一直在调它，
/// 而 `tool/first_seen_test.dart` 也直接测它。标成「测试专用」是假的，
/// analyzer 会据此报 `invalid_use_of_visible_for_testing_member`。
DateTime? parseFirstSeen(String html) {
  final m = _rowRe.firstMatch(html);
  if (m == null) return null;
  final text = m
      .group(1)!
      .replaceAll(_tagRe, ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  final t = _isoRe.firstMatch(text);
  if (t == null) return null;
  return DateTime.utc(
    int.parse(t.group(1)!),
    int.parse(t.group(2)!),
    int.parse(t.group(3)!),
    int.parse(t.group(4)!),
    int.parse(t.group(5)!),
    int.tryParse(t.group(6) ?? '') ?? 0,
  );
}
