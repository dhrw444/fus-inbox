// 收件箱搜索的匹配与排序。
//
// 纯逻辑，不碰网络、不碰 Flutter。
//
// 为什么要测：搜索是「用户输入什么、看到什么」的判定，判错的方式很隐蔽 ——
// 比如时间戳参与了匹配，用户搜「2026」会把整页消息都命中，而他只会觉得
// 「这搜索是坏的」。
import 'package:fus_inbox/features/inbox/domain/inbox_message.dart';
import 'package:fus_inbox/features/inbox/domain/inbox_search.dart';

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

InboxMessage msg({
  String id = 'a',
  String text = '',
  String code = '',
  String sender = '',
  String receivedAt = '2026-10-25T21:31:46',
  String phone = '',
}) => InboxMessage(
  id: id,
  text: text,
  code: code,
  sender: sender,
  receivedAt: receivedAt,
  phone: phone,
);

void main() {
  final google = msg(
    id: 'g',
    text: 'G-123456 is your Google verification code.',
    code: '123456',
    sender: 'Google',
    phone: '14197797678',
  );
  final shop = msg(
    id: 's',
    text: '订单 12345678 已发货，快递单号 SF1234567890',
    sender: '淘宝',
    phone: '17373889497',
  );
  final plain = msg(
    id: 'p',
    text: 'Your package has been delivered.',
    sender: 'USPS',
    // 和 google 那条**不同**的号：同一个号两条会让「按号码搜只命中一条」
    // 这个断言失去意义（我第一版就写重了，被测试当场打回来）。
    phone: '14195551234',
  );
  final all = [google, shop, plain];

  print('=== 1. 空查询：命中一切 ===');
  {
    eq(filterInboxMessages(all, query: '').length, 3, '空串全过');
    eq(filterInboxMessages(all, query: '   ').length, 3, '只有空白也算空');
  }

  print('');
  print('=== 2. 按验证码命中 ===');
  {
    final r = filterInboxMessages(all, query: '123456');
    ok(r.any((m) => m.id == 'g'), '命中验证码 123456');
  }

  print('');
  print('=== 3. 按发送方命中（大小写不敏感）===');
  {
    ok(
      filterInboxMessages(all, query: 'google').any((m) => m.id == 'g'),
      '小写 google 命中 Google',
    );
    ok(
      filterInboxMessages(all, query: 'GOOGLE').any((m) => m.id == 'g'),
      '大写也对',
    );
    ok(filterInboxMessages(all, query: '淘宝').any((m) => m.id == 's'), '中文发送方');
  }

  print('');
  print('=== 4. 按正文命中 ===');
  {
    ok(
      filterInboxMessages(all, query: 'delivered').any((m) => m.id == 'p'),
      '正文里的词',
    );
  }

  print('');
  print('=== 5. 按号码命中（多号同时开着时区分是哪个号）===');
  {
    final r = filterInboxMessages(all, query: '9779');
    eq(r.length, 1, '只命中这个号');
    eq(r.single.id, 'g', '命中的是 google 那条');

    // 反过来：另一个号只有一条。
    final r2 = filterInboxMessages(all, query: '17373889497');
    eq(r2.length, 1, '另一个号也只有一条');
    eq(r2.single.id, 's', '是淘宝那条');
  }

  print('');
  print('=== 6. 【关键】时间戳不参与匹配 ===');
  {
    // receivedAt 是 ISO 串，里面全是数字。它要是参与匹配，用户搜「2026」
    // 会把整页消息都命中 —— 而他只会觉得搜索坏了。
    final r = filterInboxMessages(all, query: '2026');
    eq(r.length, 0, '搜 2026 不该命中任何一条');
    final r2 = filterInboxMessages(all, query: '21:31');
    eq(r2.length, 0, '搜时间片段也不命中');
  }

  print('');
  print('=== 7. 「只看验证码」筛子 ===');
  {
    final r = filterInboxMessages(all, query: '', codeOnly: true);
    eq(r.length, 1, '只有一条带码');
    eq(r.single.id, 'g', '就是 google 那条');
  }

  print('');
  print('=== 8. 两个筛子是「与」的关系 ===');
  {
    // 只看验证码 + 搜发送方：google 那条既是验证码又是 Google → 命中。
    eq(
      filterInboxMessages(all, query: 'google', codeOnly: true).length,
      1,
      '验证码 + google → 1 条',
    );
    // 只看验证码 + 搜淘宝：淘宝那条没码 → 空。
    eq(
      filterInboxMessages(all, query: '淘宝', codeOnly: true).length,
      0,
      '验证码 + 淘宝 → 0 条',
    );
  }

  print('');
  print('=== 9. 纯数字查询：验证码命中的排前面 ===');
  {
    // 「123456」在两个地方出现：google 的 code 是 123456，
    // 淘宝那条正文里有 12345678（含这串数字）。用户敲数字时意图是找码。
    final r = filterInboxMessages(all, query: '123456');
    eq(r.length, 2, '两条都命中');
    eq(r.first.id, 'g', '验证码那条排第一，正文撞上的排后面');
    eq(r.last.id, 's', '正文撞上的在后');
  }

  print('');
  print('=== 10. 非数字查询：保持原序 ===');
  {
    // 顺序不该被搜索打乱（列表本来就是新的在前）。
    // 三条都含「e」之类太宽，用「o」：google 正文有，淘宝无，USPS 的
    // delivered 也没有 → 只命中一条，验不出顺序。换成能命中两条的词。
    final m1 = msg(id: '1', text: 'alpha', sender: 'A');
    final m2 = msg(id: '2', text: 'beta', sender: 'B');
    final r = filterInboxMessages([m1, m2], query: 'a');
    eq(r.length, 2, '两条都含 a');
    eq(r.map((m) => m.id).join(','), '1,2', '原序不变');
  }

  print('');
  print('=== 11. 空白归一化 ===');
  {
    final t = msg(id: 't', text: 'Hello   World', sender: 'X');
    ok(filterInboxMessages([t], query: 'hello world').isNotEmpty, '查询里压空白后能命中');
    ok(filterInboxMessages([t], query: '  hello  ').isNotEmpty, '查询首尾空白无所谓');
  }

  print('');
  print('=== 12. 没命中就是空，不是全部 ===');
  {
    eq(filterInboxMessages(all, query: 'zzzzz').length, 0, '不存在的东西 → 空');
    eq(filterInboxMessages(const [], query: 'x').length, 0, '空列表 → 空');
  }

  print('');
  print('$pass passed, $fail failed');
  if (fail > 0) throw StateError('$fail failed');
}
