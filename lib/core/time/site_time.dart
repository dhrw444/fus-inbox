/// 站点时间串的解析。
///
/// freeussms 的时间戳有两种形状：
///  * 目录页 `data-rel-time="2026-10-25T21:31:46"` —— **UTC 但不带时区后缀**
///  * 收件页 `<time datetime="2026-10-25T21:37:53Z">` —— 带 `Z` / `+00:00`
///
/// `DateTime.tryParse` 对第一种会按**本地时区**解释，在 UTC+8 设备上整整偏 8 小时。
/// 站点自己的 `live.js:238` 是这么处理的：
///
/// ```js
/// function parseUTC(raw){ return Date.parse(/(?:Z|[+-]\d{2}:?\d{2})$/i.test(raw) ? raw : raw + 'Z'); }
/// ```
///
/// 即：没有时区后缀就补 `Z`。这里照抄同一条规则，避免展示层各自猜。
library;

final _zoneSuffix = RegExp(r'(?:Z|[+-]\d{2}:?\d{2})$', caseSensitive: false);

/// 解析站点时间串，返回**带 UTC 标记**的 [DateTime]。
///
/// 无时区后缀的串按 UTC 解释（不按本地）。无法解析时返回 null。
DateTime? parseSiteTime(String? iso) {
  if (iso == null || iso.isEmpty) return null;
  final raw = iso.trim();
  if (raw.isEmpty) return null;
  return DateTime.tryParse(_zoneSuffix.hasMatch(raw) ? raw : '${raw}Z');
}

/// 把 ISO 时间转成「3 分钟前」这类短文案。
///
/// [now] 仅供测试注入；生产传 null 即用当前时间。
String relativeTime(String iso, DateTime? now) {
  final t = parseSiteTime(iso);
  if (t == null) return iso;
  // t 现在是 UTC 实例，difference 比的是瞬时点，跨时区安全。
  final delta = (now ?? DateTime.now()).difference(t);
  // 未来时间戳（时钟偏差 / 站点提前量）不要显示成「-1 分钟前」。
  if (delta.isNegative) return '刚刚';
  if (delta.inSeconds < 60) return '刚刚';
  if (delta.inMinutes < 60) return '${delta.inMinutes} 分钟前';
  if (delta.inHours < 24) return '${delta.inHours} 小时前';
  if (delta.inDays < 30) return '${delta.inDays} 天前';
  return '${(delta.inDays / 30).floor()} 个月前';
}
