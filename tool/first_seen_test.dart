// 号码「首次收录时间」的解析。
//
// 这段逻辑以前和 store / provider / HttpClient 挤在同一个文件里，那个文件
// import 了 flutter_riverpod 和 shared_preferences —— **纯 Dart 一行都跑不了**。
// 抽到 `domain/first_seen.dart` 之后才能这么测。
//
// 为什么值得测：解析规则是「看着对、错一个字符就全错」的那种代码，
// 而且它的输入是站点的 HTML —— 站点改模板时**不会报错**，只会静默地
// 让所有号码都显示「没有收录时间」。那种退化从界面上看是「功能本来就这样」。
//
// 纯逻辑，不碰网络。
import 'package:fus_inbox/features/numbers/domain/first_seen.dart';

int pass = 0;
int fail = 0;

void ok(bool cond, String name, [String extra = '']) {
  if (cond) {
    pass++;
    print('  ok   $name  $extra');
  } else {
    fail++;
    print('  FAIL $name  $extra');
  }
}

void eq(Object? got, Object? want, String name) =>
    ok(got == want, '$name  (got=$got want=$want)');

/// 站点详情页里那一行的真实形状。
String row(String value) =>
    '<dt>First recorded in our directory</dt><dd>$value</dd>';

void main() {
  print('=== 1. 正常形状 ===');
  {
    final t = parseFirstSeen(
      '<dl class="number-facts">${row('2026-10-25 23:20 UTC')}</dl>',
    );
    eq(t, DateTime.utc(2026, 10, 25, 23, 20), '解析出 UTC 时间');
    ok(t!.isUtc, '结果是 UTC 实例');
  }

  print('');
  print('=== 2. 【关键】必须按 UTC 解释，不能按本地 ===');
  {
    // 原文标了 UTC。按本地时区解会整体偏 8 小时 —— 在 UTC+8 的设备上，
    // 23:20 会被解成 23:20 本地时间（= 15:20 UTC），整整差 8 小时。
    final t = parseFirstSeen(row('2026-10-25 23:20 UTC'))!;
    eq(t.hour, 23, '小时数就是原文写的 23（没被本地时区挪走）');
    eq(t.toUtc().hour, 23, 'toUtc 之后还是 23');
  }

  print('');
  print('=== 3. 带秒 ===');
  {
    final t = parseFirstSeen(row('2026-10-25 23:20:45 UTC'));
    eq(t, DateTime.utc(2026, 10, 25, 23, 20, 45), '带秒也解得出');
  }

  print('');
  print('=== 4. dd 里夹了标签 / 多余空白 ===');
  {
    final t = parseFirstSeen(
      '<dt>First recorded in our directory</dt>'
      '<dd>\n  <time>2026-10-25 23:20 UTC</time>\n</dd>',
    );
    eq(t, DateTime.utc(2026, 10, 25, 23, 20), '剥掉内层标签 + 压空白');
  }

  print('');
  print('=== 5. 没收录过的号 ===');
  {
    eq(parseFirstSeen(row('Not available')), null, 'Not available → null');
    eq(parseFirstSeen(row('')), null, '空值 → null');
    eq(parseFirstSeen(row('N/A')), null, 'N/A → null');
  }

  print('');
  print('=== 6. 页面里根本没有这一行 ===');
  {
    eq(parseFirstSeen('<html><body>什么都没有</body></html>'), null, '没有该行 → null');
    eq(parseFirstSeen(''), null, '空串 → null');
  }

  print('');
  print('=== 7. 这一行有、但日期形状不认识 ===');
  {
    eq(parseFirstSeen(row('yesterday')), null, '不可解析的日期 → null');
    eq(parseFirstSeen(row('25/10/2026 23:20 UTC')), null, '别的日期格式 → null');
  }

  print('');
  print('=== 8. 别把「最后一条短信时间」当成收录时间 ===');
  {
    // 列表页/详情页里还有 data-rel-time 那种时间，它**不是**收录时间。
    // 解析器只认 "First recorded in our directory" 后面那一格。
    final html =
        '<time data-rel-time="2026-10-26T01:02:03">刚才</time>'
        '${row('2026-10-25 23:20 UTC')}';
    eq(parseFirstSeen(html), DateTime.utc(2026, 10, 25, 23, 20), '只取收录时间那一格');
  }

  print('');
  print('=== 9. 多位月份 / 个位小时 ===');
  {
    eq(
      parseFirstSeen(row('2026-1-5 3:04 UTC')),
      null,
      '非零填充的月份/小时不接受（站点一直是零填充）',
    );
    eq(
      parseFirstSeen(row('2026-01-05 03:04 UTC')),
      DateTime.utc(2026, 1, 5, 3, 4),
      '零填充正常解',
    );
  }

  print('');
  print('$pass passed, $fail failed');
  if (fail > 0) throw StateError('$fail failed');
}
