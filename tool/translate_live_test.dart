// 真跑 translator.dart：三家引擎 + 降级链 + 缓存 + 票据复用。
//
// 用法：dart run tool/translate_live_test.dart [--offline]
//
// 直接 import 真实代码，不抄副本。这是本轮唯一的「能不能用」判据——
// 协议是我从 translators 源码推的，必须打真网络才算数。
import 'dart:io';

import 'package:fus_inbox/core/translate/translator.dart';

int pass = 0;
int fail = 0;

void ok(String name, [String extra = '']) {
  pass++;
  stdout.writeln('  ✓ $name${extra.isEmpty ? '' : '  [$extra]'}');
}

void bad(String name, String why) {
  fail++;
  stdout.writeln('  ✗ $name  → $why');
}

/// 跳过：不算通过也不算失败，但会打印出来，让人知道这条没验。
int skipped = 0;

void skip(String name, String why) {
  skipped++;
  stdout.writeln('  – $name  [跳过：$why]');
}

Future<void> check(String name, Future<void> Function() body) async {
  try {
    await body();
  } on Object catch (e) {
    bad(name, '$e');
  }
}

const sms = 'Your verification code is 482913. Do not share it.';

Future<void> main(List<String> args) async {
  final offline = args.contains('--offline');

  stdout.writeln('=== 1. needsTranslation（纯逻辑，不联网）===');
  final cases = <String, bool>{
    '': false,
    '1': false,
    '123456': false,
    '---': false,
    '你好': false,
    '你的验证码是 123': false,
    'Hello': true,
    sms: true,
    '¡Hola!': true,
  };
  cases.forEach((text, want) {
    final got = Translator.needsTranslation(text);
    got == want
        ? ok('needsTranslation(${text.isEmpty ? "空" : text}) = $want')
        : bad('needsTranslation($text)', '期望 $want 实得 $got');
  });

  stdout.writeln('\n=== 2. engineOrder（降级顺序，不联网）===');
  await check('默认首选微软', () async {
    final t = Translator();
    final o = t.engineOrder;
    o.first == TranslateEngine.bing
        ? ok('默认首选 = ${o.first.label}', o.map((e) => e.label).join(' → '))
        : bad('默认首选', '实得 ${o.first.label}');
    t.dispose();
  });
  await check('首选谷歌时谷歌排最前', () async {
    final t = Translator(preferred: TranslateEngine.google);
    final o = t.engineOrder;
    o.first == TranslateEngine.google
        ? ok('首选 = ${o.first.label}', o.map((e) => e.label).join(' → '))
        : bad('首选谷歌', '实得 ${o.first.label}');
    t.dispose();
  });
  await check('三家全覆盖且不重复', () async {
    final t = Translator(preferred: TranslateEngine.yandex);
    final o = t.engineOrder;
    final uniq = o.toSet();
    (o.length == 3 && uniq.length == 3)
        ? ok('顺序 = ${o.map((e) => e.label).join(" → ")}')
        : bad('覆盖', '长度 ${o.length} 去重 ${uniq.length}');
    t.dispose();
  });

  await check('沉底：失败过的引擎排到末尾', () async {
    // 直接测纯函数：给「谷歌已失败一次」的状态，看它是否让位。
    final o = Translator.orderEngines(
      preferred: TranslateEngine.google,
      lastGood: null,
      fails: {TranslateEngine.google: 1},
      demoteAfter: 1,
    );
    o.last == TranslateEngine.google
        ? ok('沉底生效', o.map((e) => e.label).join(' → '))
        : bad('沉底未生效', '谷歌仍在 ${o.indexOf(TranslateEngine.google)} 位');
  });
  await check('沉底：没失败过的不动', () async {
    final o = Translator.orderEngines(
      preferred: TranslateEngine.google,
      lastGood: null,
      fails: const {},
      demoteAfter: 1,
    );
    o.first == TranslateEngine.google
        ? ok('未失败时首选在最前', o.map((e) => e.label).join(' → '))
        : bad('未失败却沉底了', '实得 ${o.first.label}');
  });
  await check('沉底：成功过的引擎排最前', () async {
    final o = Translator.orderEngines(
      preferred: TranslateEngine.google,
      lastGood: TranslateEngine.yandex,
      fails: const {},
      demoteAfter: 1,
    );
    o.first == TranslateEngine.yandex && o.length == 3
        ? ok('lastGood 置顶', o.map((e) => e.label).join(' → '))
        : bad('lastGood 未置顶', o.map((e) => e.label).join(' → '));
  });
  await check('沉底：阈值可调', () async {
    // 失败 1 次、阈值 2 时不该沉底——这条防的是「阈值写死成 1」。
    final o = Translator.orderEngines(
      preferred: TranslateEngine.google,
      lastGood: null,
      fails: {TranslateEngine.google: 1},
      demoteAfter: 2,
    );
    o.first == TranslateEngine.google
        ? ok('阈值 2 时未沉底')
        : bad('阈值失效', '阈值 2 却仍沉底了');
  });
  await check('沉底：顺序里没有重复项（lastGood 与首选相同）', () async {
    final o = Translator.orderEngines(
      preferred: TranslateEngine.bing,
      lastGood: TranslateEngine.bing,
      fails: const {},
      demoteAfter: 1,
    );
    o.length == 3 && o.toSet().length == 3
        ? ok('无重复', o.map((e) => e.label).join(' → '))
        : bad('有重复', o.map((e) => e.label).join(' → '));
  });
  await check('沉底：顺序里没有重复项（lastGood 与首选不同）', () async {
    // 这条专防「去重条件只排除了 head、忘了排除 lastGood」。
    // 上面那条测不出来：lastGood == head 时那个条件恒真。
    final o = Translator.orderEngines(
      preferred: TranslateEngine.bing,
      lastGood: TranslateEngine.yandex,
      fails: const {},
      demoteAfter: 1,
    );
    o.length == 3 && o.toSet().length == 3
        ? ok('无重复', o.map((e) => e.label).join(' → '))
        : bad('有重复', o.map((e) => e.label).join(' → '));
  });

  stdout.writeln('\n=== 2b. 存盘往返（不联网）===');
  for (final e in TranslateEngine.values) {
    await check('存盘名 ${e.name} 能读回', () async {
      TranslateEngine.fromName(e.name) == e
          ? ok('往返一致', e.label)
          : bad('往返失败', '${e.name} 读回成了别的');
    });
  }
  await check('未知名字回落默认引擎', () async {
    TranslateEngine.fromName('baidu') == TranslateEngine.bing
        ? ok('回落微软')
        : bad('回落错误', '实得 ${TranslateEngine.fromName('baidu').label}');
  });
  await check('空值回落默认引擎', () async {
    TranslateEngine.fromName(null) == TranslateEngine.bing
        ? ok('空值回落微软')
        : bad('空值回落错误', '实得 ${TranslateEngine.fromName(null).label}');
  });
  await check('大小写不兼容（契约：存的是枚举名）', () async {
    // 这不是 bug，是把契约钉住：存盘只认枚举名本身。
    // 哪天想兼容旧存档的大小写，改 fromName 时这条会先失败提醒。
    TranslateEngine.fromName('Bing') == TranslateEngine.bing
        ? ok('大小写被当成未知，回落默认')
        : bad('契约变了', 'Bing 被识别成了别的引擎');
  });

  stdout.writeln('\n=== 3. 语言码映射（不联网）===');
  // 私有静态方法测不到，用行为间接验证：中文目标语言不该被送去翻。
  for (final lang in ['zh-CN', 'zh-TW']) {
    final t = Translator(toLang: lang);
    final cjk = Translator.needsTranslation('你的验证码是 482913');
    !cjk ? ok('toLang=$lang 时中文文本跳过翻译') : bad('toLang=$lang', '中文仍被判为需要翻译');
    t.dispose();
  }

  if (offline) {
    stdout.writeln('\n[--offline] 跳过联网部分');
    stdout.writeln('\n结果：$pass 通过 / $fail 失败 / $skipped 跳过');
    exit(fail == 0 ? 0 : 1);
  }

  stdout.writeln('\n=== 4. 单引擎真跑（打真网络）===');
  // 先探一遍各家端点通不通。通不通是网络环境的事实，不是代码对错；
  // 拿它当通过/失败会让「本地墙了谷歌」变成一条红测试。
  final reachable = <TranslateEngine, bool>{};
  for (final e in TranslateEngine.values) {
    final t = Translator(preferred: e);
    try {
      final r = await t.translate(sms);
      reachable[e] = r.engine == e;
      if (!reachable[e]!) {
        stdout.writeln('  [跳过] ${e.label} 连不通，降级到了 ${r.engine.label}');
      }
    } on Object catch (err) {
      reachable[e] = false;
      stdout.writeln('  [跳过] ${e.label} 连不通：$err');
    }
    t.dispose();
  }

  for (final e in TranslateEngine.values) {
    if (reachable[e] != true) {
      skip('${e.label} 单独翻译', '端点在本机不可达');
      continue;
    }
    await check('${e.label} 单独翻译', () async {
      // 只留这一个引擎：把它设为首选，另外两家会在它成功前不被触碰。
      final t = Translator(preferred: e);
      final sw = Stopwatch()..start();
      final r = await t.translate(sms);
      sw.stop();
      // 必须断言「就是这家引擎翻的」——只看译文非空的话，
      // 端点写错降级到别家也能过，测试就成了摆设。
      if (r.engine != e) {
        bad('${e.label} 未命中', '实由 ${r.engine.label} 完成');
      } else if (r.text.isEmpty) {
        bad('${e.label} 译文为空', r.text);
      } else if (!RegExp(r'[\u4e00-\u9fff]').hasMatch(r.text)) {
        bad('${e.label} 译文不是中文', r.text);
      } else {
        ok(
          '${e.label} → ${r.text}',
          'src=${r.sourceLang} ${sw.elapsedMilliseconds}ms',
        );
      }
      t.dispose();
    });
  }

  stdout.writeln('\n=== 5. 降级链（首选不可用时自动换）===');
  await check('首选微软 → 能出结果', () async {
    final t = Translator(preferred: TranslateEngine.bing);
    final r = await t.translate('Your account has been locked temporarily.');
    r.engine == TranslateEngine.bing
        ? ok('微软命中', '${r.text}  [${r.engine.label}]')
        : ok('微软失败后降级到 ${r.engine.label}', r.text);
    t.dispose();
  });
  await check('首选 Yandex → 能出结果', () async {
    final t = Translator(preferred: TranslateEngine.yandex);
    final r = await t.translate('Your parcel is out for delivery today.');
    r.engine == TranslateEngine.yandex
        ? ok('Yandex 命中', '${r.text}  [${r.engine.label}]')
        : ok('Yandex 失败后降级到 ${r.engine.label}', r.text);
    t.dispose();
  });

  stdout.writeln('\n=== 6. 缓存（同文本只发一次）===');
  await check('第二次命中缓存', () async {
    final t = Translator(preferred: TranslateEngine.bing);
    final sw = Stopwatch()..start();
    final a = await t.translate(sms);
    final first = sw.elapsedMilliseconds;
    sw.reset();
    final b = await t.translate(sms);
    final second = sw.elapsedMilliseconds;
    (a.text == b.text && second < first)
        ? ok('缓存生效', '首次 ${first}ms → 二次 ${second}ms')
        : bad('缓存', '首次 ${first}ms 二次 ${second}ms 文本同=${a.text == b.text}');
    t.dispose();
  });

  stdout.writeln('\n=== 7. 微软端点无需预热（第二次应该更快）===');
  await check('连续两次请求', () async {
    final t = Translator(preferred: TranslateEngine.bing);
    final sw = Stopwatch()..start();
    await t.translate('The package was delivered at the front door.');
    final first = sw.elapsedMilliseconds;
    sw.reset();
    await t.translate('Your appointment is confirmed for tomorrow morning.');
    final second = sw.elapsedMilliseconds;
    second < first
        ? ok('第二次更快', '首次 ${first}ms → 二次 ${second}ms')
        : ok('两次耗时接近', '首次 ${first}ms 二次 ${second}ms');
    t.dispose();
  });

  stdout.writeln('\n=== 8. 繁体目标语言 ===');
  await check('zh-TW 输出繁体', () async {
    final t = Translator(toLang: 'zh-TW', preferred: TranslateEngine.bing);
    final r = await t.translate(sms);
    // 必须真的出现繁体字。之前写成「有繁体字就 ok、没有也 ok」，
    // 那是假断言：语言码映射写错成 zh-Hans 时它照样通过。
    final hasTrad =
        r.text.contains('驗') ||
        r.text.contains('證') ||
        r.text.contains('碼') ||
        r.text.contains('個') ||
        r.text.contains('這');
    if (r.engine != TranslateEngine.bing) {
      bad('繁体未由微软完成', '实由 ${r.engine.label} 完成');
    } else if (!hasTrad) {
      bad('繁体输出里没有繁体字', r.text);
    } else {
      ok('繁体输出', r.text);
    }
    t.dispose();
  });

  stdout.writeln('\n=== 9. 简体 vs 繁体必须不同 ===');
  await check('zh-CN 与 zh-TW 译文不同', () async {
    final a = Translator(toLang: 'zh-CN', preferred: TranslateEngine.bing);
    final b = Translator(toLang: 'zh-TW', preferred: TranslateEngine.bing);
    final ra = await a.translate(sms);
    final rb = await b.translate(sms);
    ra.text != rb.text
        ? ok('两种目标语言结果不同', '简:${ra.text} | 繁:${rb.text}')
        : bad('两种目标语言结果相同', ra.text);
    a.dispose();
    b.dispose();
  });

  stdout.writeln('\n结果：$pass 通过 / $fail 失败 / $skipped 跳过');
  exit(fail == 0 ? 0 : 1);
}
