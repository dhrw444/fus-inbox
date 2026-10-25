/// 可选的美国号码（来自 freeussms 的公开号码目录）。
///
/// 目录页 `/numbers/` 是服务端直出的，不需要过站点的会话验证，
/// 所以这个模型完全由原生 HTTP + HTML 解析填充，不依赖 WebView。
library;

class const AvailableNumber({
  required this.id,
  required this.number,
  this.state = '',
  this.areaCode = '',
  this.messageCount = 0,
  this.lastTextAt,
  this.isFresh = false,
}) {
  /// 站点的 32 位 hex 标识（`data-live-card`）。打开收件页后用它对齐。
  final String id;

  /// E.164 纯数字，例如 `14197797678`。
  final String number;

  /// 州名，例如 `Ohio`。
  final String state;

  /// 区号，例如 `419`。
  final String areaCode;

  /// 该号已收到的短信条数。
  final int messageCount;

  /// 最后一条短信时间（页面给的 ISO 串）。
  final String? lastTextAt;

  /// 页面给的「最近有短信」标记。
  final bool isFresh;

  /// `+1 (419) 779-7678`
  String get pretty {
    if (number.length != 11 || !number.startsWith('1')) return '+$number';
    final a = number.substring(1, 4);
    final b = number.substring(4, 7);
    final c = number.substring(7);
    return '+1 ($a) $b-$c';
  }

  /// `Ohio · 419`
  String get regionLabel {
    if (state.isEmpty) return areaCode.isEmpty ? '' : areaCode;
    if (areaCode.isEmpty) return state;
    return '$state · $areaCode';
  }

  /// 打开该号收件页的 URL。
  String get inboxUrl => 'https://freeussms.com/numbers/$number/';

  /// 搜索用：号码数字、州名、区号拼在一起。
  String get searchBlob => '$number $state $areaCode'.toLowerCase();

  @override
  bool operator ==(Object other) => other is AvailableNumber && other.id == id;

  @override
  int get hashCode => id.hashCode;
}
