/// 号码「首次被站点收录」的时间。
///
/// 站点把这个字段只放在号码详情页（`/numbers/<号码>/`）：
///   First recorded in our directory   2026-10-25 23:20 UTC
/// 列表页的卡片里只有 `data-rel-time`（最后一条短信时间），没有收录时间。
///
/// 所以只能按需抓：用户点开某个号的收件箱时顺手抓一次，结果永久缓存，
/// 之后首页直接带出来。不预抓整表——百来个号就是百来次请求，
/// 那正是站点风控的源头。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _kCacheKey = 'number_first_seen_v1';

final _rowRe = RegExp(
  r'First recorded in our directory\s*</dt>\s*<dd>(.*?)</dd>',
  dotAll: true,
);
final _tagRe = RegExp(r'<[^>]+>');
final _isoRe = RegExp(
  r'(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2})(?::(\d{2}))?',
);

/// 从详情页 HTML 里取收录时间。
///
/// 站点写的是 `2026-10-25 23:20 UTC`，没有 ISO 的 T 和 Z。
/// 一律按 UTC 解析——原文标了 UTC，按本地时区解会整体偏 8 小时。
/// 没收录过的号那格是 `Not available`，这里返回 null。
@visibleForTesting
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

/// 号码 → 收录时间。键用 E.164 纯数字（`14197797678`）。
class FirstSeenStore() extends Notifier<Map<String, DateTime>> {
  @override
  Map<String, DateTime> build() {
    // 不 watch 任何东西：这份缓存只由 put() 写入。
    _restore();
    return const {};
  }

  Future<void> _restore() async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_kCacheKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      final out = <String, DateTime>{};
      for (final e in decoded.entries) {
        final k = e.key;
        final v = e.value;
        if (k is! String || v is! String) continue;
        final t = DateTime.tryParse(v);
        if (t != null) out[k] = t;
      }
      if (out.isNotEmpty) state = out;
    } catch (_) {
      // 缓存坏了当没有，不影响任何功能。
    }
  }

  bool has(String number) => state.containsKey(number);

  DateTime? get(String number) => state[number];

  /// 写入一条并落盘。已经有的不重复写。
  Future<void> put(String number, DateTime at) async {
    if (state[number] == at) return;
    state = {...state, number: at};
    await _save();
  }

  Future<void> _save() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(
        _kCacheKey,
        jsonEncode({
          for (final e in state.entries) e.key: e.value.toIso8601String(),
        }),
      );
    } catch (_) {
      // 落盘失败只影响下次启动，本次会话仍可用。
    }
  }
}

final firstSeenStoreProvider =
    NotifierProvider<FirstSeenStore, Map<String, DateTime>>(FirstSeenStore.new);

/// 抓单个号码详情页里的收录时间。
///
/// 失败返回 null —— 收录时间只是附注，不能因为它拦住收件箱。
Future<DateTime?> fetchFirstSeen(String e164, {HttpClient? client}) async {
  final http = client ?? HttpClient();
  final own = client == null;
  try {
    final req = await http
        .getUrl(Uri.parse('https://freeussms.com/numbers/$e164/'))
        .timeout(const Duration(seconds: 15));
    req.headers
      ..set(HttpHeaders.userAgentHeader, _ua)
      ..set(
        HttpHeaders.acceptHeader,
        'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
      )
      ..set(HttpHeaders.acceptLanguageHeader, 'en-US,en;q=0.9');
    final res = await req.close().timeout(const Duration(seconds: 20));
    if (res.statusCode != HttpStatus.ok) {
      unawaited(res.drain<void>().catchError((Object _) {}));
      return null;
    }
    return parseFirstSeen(await res.transform(utf8.decoder).join());
  } catch (e) {
    debugPrint('抓收录时间失败（$e164）：$e');
    return null;
  } finally {
    if (own) http.close(force: true);
  }
}

const _ua =
    'Mozilla/5.0 (Linux; Android 13; K) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';
