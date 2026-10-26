/// 号码搜索过滤回归测试。
///
/// 曾经的 bug：`digits` 为空时 `n.areaCode.contains('')` 恒真，
/// 于是输入任何非数字词（如 `ohio`）都会把全部号码放出来。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:fus_inbox/features/numbers/domain/available_number.dart';

/// 与 `NumbersState.visibleFor` 里的过滤逻辑保持一致。
List<AvailableNumber> applyQuery(List<AvailableNumber> items, String query) {
  var out = items;
  final q = query.trim().toLowerCase();
  if (q.isNotEmpty) {
    final digits = q.replaceAll(RegExp(r'[^\d]'), '');
    out = out.where((n) {
      if (digits.isNotEmpty) {
        if (n.number.contains(digits)) return true;
        if (n.areaCode.isNotEmpty && n.areaCode.contains(digits)) return true;
      }
      return n.state.toLowerCase().contains(q);
    }).toList();
  }
  return out;
}

AvailableNumber number({
  required String number,
  required String areaCode,
  required String state,
}) => AvailableNumber(
  id: '0123456789abcdef0123456789abcdef',
  number: number,
  areaCode: areaCode,
  state: state,
  lastTextAt: '2026-10-25T21:31:46',
);

void main() {
  final all = <AvailableNumber>[
    number(number: '+14197797678', areaCode: '419', state: 'Ohio'),
    number(number: '+15022408008', areaCode: '502', state: 'Kentucky'),
    number(number: '+19453852836', areaCode: '945', state: 'Texas'),
  ];

  group('搜索过滤', () {
    test('非数字词只按州名筛，不会带出全部号码', () {
      final r = applyQuery(all, 'ohio');
      expect(r.length, 1);
      expect(r.single.state, 'Ohio');
    });

    test('无匹配返回空列表', () {
      expect(applyQuery(all, 'zzz'), isEmpty);
    });

    test('纯数字按号码或区号筛', () {
      expect(applyQuery(all, '419').single.state, 'Ohio');
      expect(applyQuery(all, '502').single.state, 'Kentucky');
    });

    test('空查询返回全部', () {
      expect(applyQuery(all, '').length, 3);
      expect(applyQuery(all, '   ').length, 3);
    });

    test('州名前缀可命中', () {
      final r = applyQuery(all, 'ken');
      expect(r.single.state, 'Kentucky');
    });
  });
}
