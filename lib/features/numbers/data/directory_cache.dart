/// 号码目录的磁盘缓存：上次抓到的整表落盘，启动先秒出缓存再后台增量刷新。
///
/// 为什么不用 sqflite/hive：只是一份 JSON 快照，SharedPreferences 一个
/// 字符串键足够（上百条约 20~30KB，远低于 Sp 合理体积）；键名用单字母
/// 压过一道体积（见 [AvailableNumber.toJson]）。
///
/// 两条约束：
///   1. 缓存只用来提前显示，不替代刷新 —— 打开仍会去站点取最新。
///   2. 缓存坏了不能拖垮首页 —— 任何解析失败都当「没有缓存」处理。
library;

import 'dart:convert';

import 'package:fus_inbox/core/log.dart';
import 'package:fus_inbox/core/prefs/storage_keys.dart';
import 'package:fus_inbox/features/numbers/domain/available_number.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
    final raw = kDirectoryCacheKey.readString(p);
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
    // 缓存坏了当没有：加速手段不能变成可用性依赖。
    logLine('目录缓存读取失败，忽略：$e');
    return null;
  }
}

/// 写缓存。失败只影响下次启动的速度，不影响本次功能。
Future<void> saveDirectoryCache(List<AvailableNumber> numbers) async {
  if (numbers.isEmpty) return;
  try {
    final p = await SharedPreferences.getInstance();
    await kDirectoryCacheKey.writeString(
      p,
      jsonEncode({
        'at': DateTime.now().toIso8601String(),
        'items': [for (final n in numbers) n.toJson()],
      }),
    );
  } catch (e) {
    logLine('目录缓存写入失败：$e');
  }
}

/// 清缓存。
Future<void> clearDirectoryCache() async {
  try {
    final p = await SharedPreferences.getInstance();
    await kDirectoryCacheKey.remove(p);
  } catch (_) {
    // 清缓存失败没有补救价值 —— 最坏是下次还命中旧缓存，
    // 而缓存本身有 TTL，不是正确性依赖。
  }
}
