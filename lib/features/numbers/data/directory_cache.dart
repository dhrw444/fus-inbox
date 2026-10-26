/// 号码目录的磁盘缓存。
///
/// 首页每次冷启动都要重新抓 5 页、十几秒，看起来像卡死。这里把上一次
/// 抓到的结果落盘，启动时先秒出缓存，再后台静默拉最新的一页做增量合并。
///
/// 两条约束：
///   1. **缓存只用来提前显示，不替代刷新**。打开 App 仍会去站点取最新数据，
///      有新号就并进来，没有就保持原样。
///   2. **缓存坏了不能拖垮首页**。任何解析失败都当「没有缓存」处理，
///      退回原来的纯网络路径。
///
/// 存的是 SharedPreferences 里的一个 JSON 串。上百条号码约 20~30KB，
/// 远低于 Sp 的合理体积；用单字母键名（见 AvailableNumber.toJson）压过一道。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fus_inbox/features/numbers/domain/available_number.dart';

const _kCacheKey = 'number_dir_cache_v1';

/// 缓存快照。
class const DirectoryCache({required this.numbers, required this.savedAt}) {
  final List<AvailableNumber> numbers;

  /// 这份缓存是什么时候抓到的。用来在界面上说「显示的是几分钟前的数据」。
  final DateTime savedAt;
}

/// 读缓存。没有或损坏返回 null。
Future<DirectoryCache?> loadDirectoryCache() async {
  try {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_kCacheKey);
    if (raw == null || raw.isEmpty) return null;
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return null;

    final at = decoded['at'];
    final list = decoded['items'];
    if (at is! String || list is! List) return null;
    final savedAt = DateTime.tryParse(at);
    if (savedAt == null) return null;

    final out = <AvailableNumber>[];
    for (final item in list) {
      final n = AvailableNumber.fromJson(item);
      if (n != null) out.add(n);
    }
    if (out.isEmpty) return null;
    return DirectoryCache(numbers: out, savedAt: savedAt);
  } catch (e) {
    debugPrint('目录缓存读取失败，忽略：$e');
    return null;
  }
}

/// 写缓存。失败静默——缓存写不进去只是下次启动慢一点。
Future<void> saveDirectoryCache(List<AvailableNumber> numbers) async {
  if (numbers.isEmpty) return;
  try {
    final p = await SharedPreferences.getInstance();
    await p.setString(
      _kCacheKey,
      jsonEncode({
        'at': DateTime.now().toIso8601String(),
        'items': [for (final n in numbers) n.toJson()],
      }),
    );
  } catch (e) {
    debugPrint('目录缓存写入失败：$e');
  }
}

/// 清缓存。
Future<void> clearDirectoryCache() async {
  try {
    final p = await SharedPreferences.getInstance();
    await p.remove(_kCacheKey);
  } catch (_) {}
}
