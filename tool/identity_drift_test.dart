// 「一个代理一个身份」的回归测试。
//
// 曾经的 bug：plan() 的 rotate 分支无条件 mint 一个新 UA；commit() 合并时
// openedNumbers 取 base（老绑定），但 userAgent 取 binding（新 mint 的）。
// 于是老出口上原来的设备身份被顶掉，同一个 IP 上出现两个「设备」。
//
// 现在本地不再按额度换出口（见 `identity_ledger.dart` 文件头），
// `plan()` 只在「这条出口上还没有身份」时才 mint。换出口走
// `nextUsableProxy` + `IdentityRotator`，那条路径**只挑出口，不改身份**。
// 这个测试守的就是「挑出口时绝不铸造新身份、也绝不顶掉已有的」。

import 'dart:io';

import 'package:fus_inbox/core/proxy/identity_ledger.dart';
import 'package:fus_inbox/core/proxy/proxy_config.dart';

int passed = 0;
int failed = 0;

void check(String name, bool ok, [String extra = '']) {
  if (ok) {
    passed++;
    print('  ok   $name  $extra');
  } else {
    failed++;
    print('  FAIL $name  $extra');
  }
}

ProxyConfig p(String host, int port) => ProxyConfig(
  id: 'socks5://$host:$port',
  scheme: ProxyScheme.socks5,
  host: host,
  port: port,
);

void main() {
  final pool = [p('10.0.0.1', 1), p('10.0.0.2', 2), p('10.0.0.3', 3)];

  // 当前身份（P0 上那个）的 UA —— plan() 的 mintUserAgent 就返回这个。
  const currentUa =
      'Mozilla/5.0 (Linux; Android 14; SM-S918B) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/134.0.0.0 Mobile Safari/537.36';
  // P1 上早就绑好的那个身份的 UA —— 跟当前身份不同。
  const p1OwnUa =
      'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36';

  final led = IdentityLedger();

  // P0 用满 3 个。
  for (final n in ['a1', 'a2', 'a3']) {
    led.commit(
      pool[0].id,
      n,
      IdentityBinding(
        proxyId: pool[0].id,
        userAgent: currentUa,
        model: 'SM-S918B',
        chromeMajor: '134',
        openedNumbers: const [],
        createdAtMs: 0,
      ),
    );
  }

  // P1 之前已经看过 1 个号，用它自己的 UA。
  led.commit(
    pool[1].id,
    'b1',
    IdentityBinding(
      proxyId: pool[1].id,
      userAgent: p1OwnUa,
      model: 'Pixel 7',
      chromeMajor: '131',
      openedNumbers: const [],
      createdAtMs: 0,
    ),
  );

  // P2 也占 1 个 —— 逼着轮转只能落到 P1 上（新规则优先挑完全没绑过的，
  // 不先把 P2 占掉的话会直接跳到 P2，测不到「复用已有身份」那条）。
  led.commit(
    pool[2].id,
    'c1',
    IdentityBinding(
      proxyId: pool[2].id,
      userAgent: 'UA-C',
      model: 'MODEL-C',
      chromeMajor: '135',
      openedNumbers: const [],
      createdAtMs: 0,
    ),
  );

  check(
    'P0 看过 3 个号',
    led.usedFor(pool[0].id) == 3,
    '(got=${led.usedFor(pool[0].id)})',
  );
  check(
    'P1 已用 1',
    led.usedFor(pool[1].id) == 1,
    '(got=${led.usedFor(pool[1].id)})',
  );

  // 换出口（站点报限额时 `IdentityRotator` 走这条）：
  // 三条出口都绑过身份了，只能落到绑过的 —— 但**绝不铸造新身份**。
  final next = led.nextUsableProxy(pool, pool[0].id);
  check(
    '挑出了别的出口',
    next != null && next.id != pool[0].id,
    '(got=${next?.displayName})',
  );
  check('没落到当前这条 P0 上', next!.id != pool[0].id, '(got=${next.displayName})');

  final picked = led.forProxy(next.id)!;
  check(
    '目标出口自己的身份没被顶掉',
    picked.userAgent != currentUa,
    '(got=${picked.userAgent.substring(0, 52)}…)',
  );

  print('');
  print('  P1 原本自己的 UA : ${p1OwnUa.substring(0, 52)}…');
  print('  P1 现在记的 UA   : ${picked.userAgent.substring(0, 52)}…');
  print('  P1 现在记的机型  : ${picked.model} / Chrome ${picked.chromeMajor}');
  print('');
  check('【回归】P1 保住自己的身份，没被 P0 的顶掉', picked.userAgent == p1OwnUa);
  check('【回归】机型没串', picked.model == 'Pixel 7', '(got=${picked.model})');
  check(
    '【回归】Chrome 版本没串',
    picked.chromeMajor == '131',
    '(got=${picked.chromeMajor})',
  );
  check('【回归】号数没被挑改动', picked.used == 1, '(got=${picked.used})');

  print('');
  print('$passed passed, $failed failed');
  if (failed > 0) exit(1);
}
