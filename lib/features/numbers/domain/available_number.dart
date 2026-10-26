/// 可选的美国号码（来自 freeussms 的公开号码目录）。
///
/// 目录页 `/numbers/` 是服务端直出的，不需要过站点的会话验证，
/// 所以这个模型完全由原生 HTTP + HTML 解析填充，不依赖 WebView。
library;

import 'package:fus_inbox/features/numbers/domain/state_names.dart';

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

  /// 序列化成 JSON，供磁盘缓存使用。
  ///
  /// 手写而不是用 json_serializable：这个模型只有 7 个字段、结构固定，
  /// 为一个 model 引入 build_runner 整条生成链不值得。
  Map<String, Object?> toJson() => {
    'id': id,
    'n': number,
    's': state,
    'a': areaCode,
    'c': messageCount,
    't': lastTextAt,
    'f': isFresh,
  };

  /// 从缓存 JSON 还原。字段缺失或类型不对时退回默认值，不抛异常——
  /// 缓存是加速手段，坏了就当没有，绝不能因此让首页打不开。
  ///
  /// 键名用单字母是为了压体积：上百条号码的缓存每次启动都要读一遍。
  static AvailableNumber? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final number = raw['n'];
    if (id is! String || number is! String) return null;
    if (id.isEmpty || number.isEmpty) return null;
    final count = raw['c'];
    final last = raw['t'];
    return AvailableNumber(
      id: id,
      number: number,
      state: raw['s'] is String ? raw['s'] as String : '',
      areaCode: raw['a'] is String ? raw['a'] as String : '',
      messageCount: count is int ? count : int.tryParse('$count') ?? 0,
      lastTextAt: last is String && last.isNotEmpty ? last : null,
      isFresh: raw['f'] == true,
    );
  }

  /// `俄亥俄 · 419`
  ///
  /// 界面全中文，州名走 [stateZh] 映射；未知州名原样返回。
  String get regionLabel {
    final zh = stateZh(state);
    if (zh.isEmpty) return areaCode.isEmpty ? '' : areaCode;
    if (areaCode.isEmpty) return zh;
    return '$zh · $areaCode';
  }

  /// 打开该号收件页的 URL。
  String get inboxUrl => 'https://freeussms.com/numbers/$number/';

  /// 搜索用：号码数字、中文州名、英文州名、区号拼在一起。
  ///
  /// 两个州名都放进去，用户打「佛州」查不到，打 `Florida` 或 `佛罗里达` 都能中。
  String get searchBlob =>
      '$number $state ${stateZh(state)} $areaCode'.toLowerCase();

  @override
  bool operator ==(Object other) => other is AvailableNumber && other.id == id;

  @override
  int get hashCode => id.hashCode;
}
