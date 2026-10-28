// 目录排序的**稳定性**：换一下入参顺序，输出顺序必须完全一样。
//
// ## 为什么这条必须测
//
// `List.sort` 在 Dart 里**不保证稳定**。目录是分页**并发**抓回来的
// （最多 3 个 worker 在飞），页与页的完成顺序每次都不一样 —— 也就是说
// 同一批号码每次刷新时的入参顺序都不同。
//
// 只要比较器里有「并列就返回 0」的路径，输出顺序就会跟着入参顺序漂移：
// 用户看到的是「列表自己会跳」，同一批号码忽上忽下。
//
// 实测过（Dart 3.13.7/aarch64）：全零比较器 + 换入参顺序，输出顺序就变。
// 所以判据只能是「同一集合、不同入参顺序 → 输出序列逐项相等」。
//
// `NumberSort.number` 是阳性对照：号码唯一，天然全序，任何输入顺序下
// 输出都必须一致。它过而其它不过，说明问题确实出在并列兜底上。

import 'dart:io';
import 'dart:math';

import 'package:fus_inbox/features/numbers/domain/available_number.dart';
import 'package:fus_inbox/features/numbers/domain/number_sort.dart';

int pass = 0;
int fail = 0;

void ok(bool c, String name, [String extra = '']) {
  if (c) {
    pass++;
    print('  ok   $name  $extra');
  } else {
    fail++;
    print('  FAIL $name  $extra');
  }
}

/// 造一批**刻意大量并列**的号码。
///
/// 并列是重点：只比一个字段、其余全一样，比较器就会大面积返回 0。
/// 真实目录也长这样 —— 大部分号 messageCount 都是 0 或很小的数。
List<AvailableNumber> sample() {
  final out = <AvailableNumber>[];
  var i = 0;
  for (final fresh in [true, false]) {
    for (final count in [0, 0, 0, 1, 5]) {
      for (final time in [null, null, '2026-10-27T10:00:00Z']) {
        i++;
        out.add(
          AvailableNumber(
            id: 'id$i',
            number: '1419779${(7670 + i).toString().padLeft(4, '0')}',
            state: 'Ohio',
            areaCode: '419',
            messageCount: count,
            lastTextAt: time,
            isFresh: fresh,
          ),
        );
      }
    }
  }
  return out;
}

List<String> orderOf(List<AvailableNumber> items, NumberSort sort) =>
    sortNumbers(items, sort).map((n) => n.number).toList();

/// 同一个集合、若干个不同的入参顺序，输出必须逐项一致。
bool stableAcrossPermutations(List<AvailableNumber> base, NumberSort sort) {
  final want = orderOf([...base], sort);
  final rnd = Random(20261028); // 固定种子：失败可复现
  for (var round = 0; round < 12; round++) {
    final shuffled = [...base]..shuffle(rnd);
    final got = orderOf(shuffled, sort);
    if (got.length != want.length) return false;
    for (var i = 0; i < got.length; i++) {
      if (got[i] != want[i]) return false;
    }
  }
  return true;
}

Future<void> main() async {
  final base = sample();
  print('样本 ${base.length} 条（刻意大量并列）');

  print('');
  print('=== 1. 四种排序在不同入参顺序下都必须稳定 ===');
  for (final s in NumberSort.values) {
    ok(stableAcrossPermutations(base, s), '${s.label}（${s.name}）顺序稳定');
  }

  print('');
  print('=== 2. 收录时间排序：并列与缺失都要有序 ===');
  {
    final seen = <String, DateTime>{};
    // 只给一半号码收录时间，另一半缺失 —— 缺失的必须沉底。
    for (var i = 0; i < base.length; i += 2) {
      seen[base[i].number] = DateTime(2026, 10, 1).add(Duration(days: i % 3));
    }
    final want = sortNumbers([...base], NumberSort.firstSeen, firstSeen: seen);
    final rnd = Random(7);
    var same = true;
    for (var r = 0; r < 8; r++) {
      final got = sortNumbers(
        [...base]..shuffle(rnd),
        NumberSort.firstSeen,
        firstSeen: seen,
      );
      for (var i = 0; i < got.length; i++) {
        if (got[i].number != want[i].number) same = false;
      }
    }
    ok(same, '收录时间排序稳定');
    final noSeen = want
        .skipWhile((n) => seen.containsKey(n.number))
        .takeWhile((n) => !seen.containsKey(n.number))
        .length;
    ok(
      noSeen == want.where((n) => !seen.containsKey(n.number)).length,
      '没有收录时间的一律沉底',
      '(沉底 $noSeen 条)',
    );
  }

  print('');
  print('=== 3. 短信最多：并列时按号码排（不能随机） ===');
  {
    final got = orderOf([...base]..shuffle(Random(3)), NumberSort.messages);
    // 取出所有 messageCount 相同的一段，它的号码必须是升序。
    var okAsc = true;
    for (var i = 1; i < got.length; i++) {
      final a = base.firstWhere((n) => n.number == got[i - 1]);
      final b = base.firstWhere((n) => n.number == got[i]);
      if (a.messageCount == b.messageCount &&
          a.number.compareTo(b.number) > 0) {
        okAsc = false;
      }
    }
    ok(okAsc, '同条数的一段内部按号码升序');
  }

  print('');
  print('=== 4. 号码顺序：唯一全序，永远一致 ===');
  {
    ok(stableAcrossPermutations(base, NumberSort.number), '号码顺序稳定');
  }

  print('');
  print('$pass passed, $fail failed');
  // 只在**失败**时退出：这个文件既可以被单独跑，也会被 tool/gate.dart
  // import 进去当一段。无条件 exit 会把整条 gate 一起杀掉。
  if (fail > 0) exit(1);
}
