// 验证 loaded 语义：空池在 loaded=false 和 loaded=true 时代表两件不同的事。
//
// 只测 ProxyState 这个纯值类 —— ProxyNotifier 依赖 flutter_riverpod 与
// shared_preferences，纯 Dart 环境编译不了（沙箱没有 Flutter SDK）。
// 所以这里验的是「值语义对不对」，notifier 的行为靠 code review。
//
// 跑法：cd /tmp/h && /tmp/dartsdk/dart-sdk/bin/dart run tool/loaded_probe.dart
import 'package:fus_inbox/core/proxy/identity_ledger.dart';
import 'package:fus_inbox/core/proxy/proxy_config.dart';
import 'package:fus_inbox/core/proxy/proxy_state.dart';

var pass = 0;
var fail = 0;

void ok(bool cond, String label, [String extra = '']) {
  if (cond) {
    pass++;
    print('  ok   $label  $extra');
  } else {
    fail++;
    print('  FAIL $label  $extra');
  }
}

ProxyConfig p(String host, int port) => ProxyConfig(
  id: '$host:$port',
  label: '$host:$port',
  scheme: ProxyScheme.socks5,
  host: host,
  port: port,
);

void main() {
  print('=== 1. 默认状态：loaded=false（还没读盘） ===');
  final blank = ProxyState();
  ok(blank.loaded == false, '新建的 ProxyState.loaded 是 false');
  ok(blank.pool.isEmpty, 'pool 空');
  ok(blank.builtin.isEmpty, 'builtin 空');
  ok(blank.all.isEmpty, 'all 空 —— 这就是「看起来没配代理」的原因');

  print('');
  print('=== 2. 同一个空池，但读盘已完成 ===');
  final loadedEmpty = ProxyState(loaded: true);
  ok(loadedEmpty.loaded == true, 'loaded 可以显式置真');
  ok(loadedEmpty.pool.isEmpty, 'pool 仍然空（用户真的没配）');
  ok(
    blank.all.length == loadedEmpty.all.length,
    '两者 all 长度相同 —— 只能靠 loaded 区分',
    '(都是 ${blank.all.length})',
  );

  print('');
  print('=== 3. copyWith 能带上 loaded，且不丢其他字段 ===');
  final flipped = blank.copyWith(loaded: true);
  ok(flipped.loaded == true, 'copyWith(loaded: true) 生效');
  final kept = flipped.copyWith(probing: true);
  ok(kept.loaded == true, 'copyWith 其他字段时 loaded 保持');
  ok(kept.probing == true, 'probing 确实改了');

  print('');
  print('=== 4. 有池子时计划该用代理，不是直连 ===');
  final pool = [p('10.0.0.1', 1080), p('10.0.0.2', 1080)];
  final withPool = ProxyState(pool: pool, loaded: true);
  ok(withPool.all.length == 2, 'all 有两条');
  ok(withPool.all.every((e) => !e.isDirectProxy), '都不是直连');

  final led = IdentityLedger();
  // `currentProxyId` 必须给一条**真实的出口**。
  //
  // 空串的含义是「用户在设置里选了直连」—— `plan()` 有一条专门分支照着它
  // 返回直连，压根不走候选层（见 `identity_plan.dart` 那段，以及账本测试里
  // 「直连是合法选择，不能被『校正』掉」）。这里原来传的是空串，于是这条
  // 断言测的是直连，不是「有池子该用代理」；它从空串语义定下来那天起就一直
  // 挂着，而 `loaded.main` 只打印不抛 —— gate 一路上没看见（现在收尾会抛）。
  final plan = led.plan(
    pool: withPool.all,
    currentProxyId: '10.0.0.1:1080',
    numberId: 'n1',
    unusable: const <String>{},
    mintUserAgent: () => 'UA-NEW',
    mintModel: () => 'Pixel 7',
    mintChromeMajor: () => '131',
  );
  ok(!plan.proxy.isDirectProxy, '有池子 → 计划用代理', '(proxy=${plan.proxy.id})');

  print('');
  print('=== 5. 空池 → 计划必然是直连，这正是必须拦下的 ===');
  final emptyPlan = led.plan(
    pool: blank.all,
    currentProxyId: '',
    numberId: 'n1',
    unusable: const <String>{},
    mintUserAgent: () => 'UA-NEW',
    mintModel: () => 'Pixel 7',
    mintChromeMajor: () => '131',
  );
  ok(emptyPlan.proxy.isDirectProxy, '空池 → 直连计划（危险）');
  print('       ↑ 所以 _startUp 必须在 loaded=false 时停下，不能执行它');

  print('');
  print('=== 6. 有池子但全不可用 → 回退用池子，绝不退直连 ===');
  final allBad = led.plan(
    pool: withPool.all,
    // 同上：要测「全判死也不退直连」这条 fail-closed 规则，就得站在一条
    // 真实的出口上 —— 空串会被直连分支提前返回，测不到候选层
    // （`identity_plan.dart` 里 `usable.isNotEmpty ? usable : pool` 那句）。
    currentProxyId: '10.0.0.1:1080',
    numberId: 'n1',
    unusable: {'10.0.0.1:1080', '10.0.0.2:1080'},
    mintUserAgent: () => 'UA-NEW',
    mintModel: () => 'Pixel 7',
    mintChromeMajor: () => '131',
  );
  // identity_ledger.dart:223 `usable.isNotEmpty ? usable : pool`
  // —— 全判死时回退到完整池子，不是退直连。宁可赌一条判死的代理，
  // 也不把真实 IP 露出去。这是有意的设计。
  ok(
    !allBad.proxy.isDirectProxy,
    '全判死 → 仍用代理，不回退直连',
    '(proxy=${allBad.proxy.id})',
  );

  print('');
  print('$pass passed, $fail failed');
  // **有失败就抛。**
  //
  // gate 判定「这一段过没过」靠的是异常（`tool/gate.dart` 的注释：「一段
  // 检查。抛异常 = 这段失败」）。原来这里只打印 —— 于是这一段的失败 gate
  // 一次都没看见过：上面那两条从空串语义定下来那天起就一直挂着（
  // `currentProxyId: ''` 走的是直连分支），而 gate 每次都报「全部通过」。
  // 打印不等于判据，这段自己也得是判据。
  //
  // 不用 `exit(1)`：那会把整条 gate 一起杀掉，后面几段就不跑了。
  if (fail > 0) throw StateError('$fail failed');
}
