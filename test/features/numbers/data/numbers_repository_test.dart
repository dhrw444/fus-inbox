/// 目录解析器测试。
///
/// 夹具 `test/fixtures/numbers_directory.html` 是从
/// https://freeussms.com/numbers/ 抓下来的真实响应（2026-10-26，121KB）。
/// 用它当基准，站点改模板时这些断言会立刻报警。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:fus_inbox/features/numbers/data/numbers_repository.dart';

void main() {
  late String html;

  setUpAll(() {
    html = File('test/fixtures/numbers_directory.html').readAsStringSync();
  });

  group('parseDirectory', () {
    test('一页能解析出全部号码卡片', () {
      final page = parseDirectory(html);
      expect(page.numbers, hasLength(24));
    });

    test('读得出页面自报的总数', () {
      final page = parseDirectory(html);
      expect(page.total, 102);
    });

    test('每张卡片的必填字段都不为空', () {
      final page = parseDirectory(html);
      for (final n in page.numbers) {
        expect(n.id, isNotEmpty, reason: '${n.number} 缺 id');
        expect(n.number, hasLength(11), reason: '${n.id} 号码长度不对');
        expect(n.number, startsWith('1'), reason: '${n.number} 不是美国号');
        expect(n.state, isNotEmpty, reason: '${n.number} 缺州名');
        expect(n.areaCode, hasLength(3), reason: '${n.number} 区号不对');
      }
    });

    test('号码不重复', () {
      final page = parseDirectory(html);
      final numbers = page.numbers.map((n) => n.number).toList();
      expect(numbers.toSet(), hasLength(numbers.length));
    });

    test('已知号码解析正确', () {
      final page = parseDirectory(html);
      final n = page.numbers.firstWhere((e) => e.number == '14197797678');
      expect(n.id, '28cb446d1be44ce0abae72f6d349dea4');
      expect(n.state, 'Ohio');
      expect(n.areaCode, '419');
      expect(n.messageCount, 93);
      expect(n.lastTextAt, '2026-10-25T21:31:46');
      expect(n.isFresh, isTrue);
    });

    test('另一个已知号码解析正确', () {
      final page = parseDirectory(html);
      final n = page.numbers.firstWhere((e) => e.number == '17373889497');
      expect(n.state, 'Texas');
      expect(n.areaCode, '737');
      expect(n.messageCount, 10);
    });

    test('有号码带短信条数统计', () {
      final page = parseDirectory(html);
      expect(page.numbers.where((n) => n.messageCount > 0), isNotEmpty);
    });

    test('格式化的展示串正确', () {
      final page = parseDirectory(html);
      final n = page.numbers.firstWhere((e) => e.number == '14197797678');
      expect(n.pretty, '+1 (419) 779-7678');
      // 界面上州名走中文映射（state_names.dart），Ohio -> 俄亥俄。
      expect(n.regionLabel, '俄亥俄 · 419');
    });

    test('空 HTML 得到空列表而不是崩溃', () {
      final page = parseDirectory('<html><body>nothing</body></html>');
      expect(page.numbers, isEmpty);
      expect(page.total, isNull);
    });

    test('半截 HTML（只有一张卡、缺字段）不崩溃', () {
      const broken =
          '<html><body>'
          '<article class="number-card is-fresh" data-live-card="abc12345">'
          '<a href="https://freeussms.com/numbers/14197797678/">x</a>'
          '</article>'
          '</body></html>';
      final page = parseDirectory(broken);
      expect(page.numbers, hasLength(1));
      final n = page.numbers.single;
      expect(n.number, '14197797678');
      expect(n.state, '');
      expect(n.messageCount, 0);
      expect(n.isFresh, isTrue);
    });
  });

  group('AvailableNumber', () {
    test('搜索用的 blob 包含号码/州/区号', () {
      final page = parseDirectory(html);
      final n = page.numbers.firstWhere((e) => e.number == '14197797678');
      expect(n.searchBlob, contains('14197797678'));
      expect(n.searchBlob, contains('ohio'));
      expect(n.searchBlob, contains('419'));
    });

    test('收件页 URL 正确', () {
      final page = parseDirectory(html);
      final n = page.numbers.firstWhere((e) => e.number == '14197797678');
      expect(n.inboxUrl, 'https://freeussms.com/numbers/14197797678/');
    });
  });
}
