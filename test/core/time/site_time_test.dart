/// 站点时间解析回归测试。
///
/// 锁住两件事，任何一条退化都会让界面时间显示错：
///  1. 目录页的 `data-rel-time` 不带时区后缀，必须按 UTC 解释（否则 UTC+8 设备偏 8 小时）
///  2. 收件页的串自带 `Z` / `+00:00`，不能被重复补 `Z`
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:fus_inbox/core/time/site_time.dart';

void main() {
  group('parseSiteTime', () {
    test('无时区后缀按 UTC 解释，不是本地时区', () {
      // 站点目录页真实样本。
      final t = parseSiteTime('2026-10-25T21:31:46');
      expect(t, isNotNull);
      expect(t!.isUtc, isTrue);
      expect(t.toUtc(), DateTime.utc(2026, 10, 25, 21, 31, 46));
    });

    test('带 Z 的后缀照常解析', () {
      final t = parseSiteTime('2026-10-25T21:37:53Z');
      expect(t!.isUtc, isTrue);
      expect(t.toUtc(), DateTime.utc(2026, 10, 25, 21, 37, 53));
    });

    test('带 +00:00 偏移的后缀照常解析', () {
      final t = parseSiteTime('2026-10-26T00:01:03+00:00');
      expect(t!.toUtc(), DateTime.utc(2026, 10, 26, 0, 1, 3));
    });

    test('带 -05:00 偏移不会被补 Z', () {
      final t = parseSiteTime('2026-10-25T16:31:46-05:00');
      expect(t!.toUtc(), DateTime.utc(2026, 10, 25, 21, 31, 46));
    });

    test('两种形状落到同一时间轴', () {
      final a = parseSiteTime('2026-10-25T21:31:46');
      final b = parseSiteTime('2026-10-25T21:37:53Z');
      expect(b!.difference(a!).inMinutes, 6);
    });

    test('空值与垃圾输入返回 null', () {
      expect(parseSiteTime(null), isNull);
      expect(parseSiteTime(''), isNull);
      expect(parseSiteTime('   '), isNull);
      expect(parseSiteTime('not-a-date'), isNull);
    });
  });

  group('relativeTime', () {
    final now = DateTime.utc(2026, 10, 25, 21, 41, 46);

    test('目录页无时区串不再偏 8 小时', () {
      // 若按本地 +08:00 解释，这里会算成 486 分钟前。
      expect(relativeTime('2026-10-25T21:31:46', now), '10 分钟前');
    });

    test('「刚刚」分支可达', () {
      expect(relativeTime('2026-10-25T21:41:30', now), '刚刚');
    });

    test('未来时间戳不显示负数', () {
      expect(relativeTime('2026-10-25T22:00:00', now), '刚刚');
    });

    test('各档位文案', () {
      expect(relativeTime('2026-10-25T20:41:46', now), '1 小时前');
      expect(relativeTime('2026-10-24T21:41:46', now), '1 天前');
    });

    test('解析失败原样返回输入', () {
      expect(relativeTime('not-a-date', now), 'not-a-date');
    });
  });
}
