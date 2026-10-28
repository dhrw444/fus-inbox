// `ProxyState.canRotate` 的回归测试。
//
// 这条规则以前是「可用条数 > 1」，会误判两种情况（见 canRotate 的注释）：
//   1. 池里 2 条、死 1 条 → 可用只剩 1 条，`1 > 1` 为假 → 被判成「没得换」，
//      可那条根本不是当前出口，换过去完全有效。用户就此卡死在烂出口上。
//   2. 全池判死 → 可用 0 条 → 也报「没得换」，而 pickRotation 的规则是
//      「全判死也不剔，宁可用可疑代理」。
//
// 判据必须和 pickRotation 用同一条（都走 IdentityLedger.nextUsableProxy），
// 否则就是「说没有可换的，其实有」。
//
// 纯逻辑，不碰网络、不碰 Flutter。
import 'package:fus_inbox/core/proxy/identity_ledger.dart';
import 'package:fus_inbox/core/proxy/proxy_config.dart';
import 'package:fus_inbox/core/proxy/proxy_probe.dart';
import 'package:fus_inbox/core/proxy/proxy_state.dart';

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

ProxyConfig mk(String host, [int port = 1080]) =>
    parseProxyLine('socks5://$host:$port')!;

ProxyProbeResult bad(ProxyConfig p) => ProxyProbeResult.dead(p, 'refused');

void main() {
  print('=== 1. 空池：没得换 ===');
  {
    final s = ProxyState();
    ok(!s.canRotate, '空池不能换');
  }

  print('');
  print('=== 2. 只有一条：没得换（换它就是原地打转）===');
  {
    final a = mk('1.1.1.1');
    final s = ProxyState(pool: [a], currentId: a.id);
    ok(!s.canRotate, '一条可用且是当前出口 → 不能换');
  }

  print('');
  print('=== 3. 两条都在池里：能换 ===');
  {
    final a = mk('1.1.1.1');
    final b = mk('2.2.2.2');
    final s = ProxyState(pool: [a, b], currentId: a.id);
    ok(s.canRotate, '两条都在 → 能换');
  }

  print('');
  print('=== 4. 【回归】两条、死一条：剩下那条不是当前出口 → 必须能换 ===');
  {
    final a = mk('1.1.1.1');
    final b = mk('2.2.2.2');
    // a 被判死，当前出口是 a，b 健康。
    final s = ProxyState(
      pool: [a, b],
      currentId: a.id,
      results: {a.id: bad(a)},
    );
    ok(
      s.canRotate,
      '死的那条是当前出口、另一条健康 → 能换到健康的',
      '(旧规则 usable=1 → 1>1 假 → 会误报没得换)',
    );
  }

  print('');
  print('=== 5. 【回归】两条、死的那条不是当前出口 ===');
  {
    final a = mk('1.1.1.1');
    final b = mk('2.2.2.2');
    // b 死了，当前出口是 a，只剩 a 可用 —— 而 a 就是当前，确实没得换。
    final s = ProxyState(
      pool: [a, b],
      currentId: a.id,
      results: {b.id: bad(b)},
    );
    ok(!s.canRotate, '唯一可用的就是当前出口 → 确实没得换');
  }

  print('');
  print('=== 6. 【回归】全池判死：pickRotation 愿意换，canRotate 也得说能换 ===');
  {
    final a = mk('1.1.1.1');
    final b = mk('2.2.2.2');
    final s = ProxyState(
      pool: [a, b],
      currentId: a.id,
      results: {a.id: bad(a), b.id: bad(b)},
    );
    ok(s.canRotate, '全判死仍有别的出口 → 能换', '(规则是宁可用可疑代理，不裸奔直连)');
  }

  print('');
  print('=== 7. 全池判死且只有一条 → 没得换 ===');
  {
    final a = mk('1.1.1.1');
    final s = ProxyState(pool: [a], currentId: a.id, results: {a.id: bad(a)});
    ok(!s.canRotate, '只有一条且判死 → 没得换');
  }

  print('');
  print('=== 8. 内置 + 手加混着：候选要含两边 ===');
  {
    final a = mk('1.1.1.1');
    final b = mk('2.2.2.2');
    final s = ProxyState(builtin: [a], pool: [b], currentId: a.id);
    ok(s.canRotate, '内置在前、手加在后，当前是内置那条 → 能换到手加的');
  }

  print('');
  print('=== 9. 账本记满也一样能换（换的是出口，不是额度）===');
  {
    final a = mk('1.1.1.1');
    final b = mk('2.2.2.2');
    final ledger = IdentityLedger(
      bindings: {
        a.id: IdentityBinding(
          proxyId: a.id,
          userAgent: 'UA',
          model: 'M',
          chromeMajor: '141',
          openedNumbers: const ['x', 'y', 'z'],
          createdAtMs: 0,
        ),
      },
      maxPerIdentity: 3,
    );
    final s = ProxyState(pool: [a, b], currentId: a.id, ledger: ledger);
    ok(s.canRotate, '当前出口额度用满，池里还有别的 → 能换');
  }

  print('');
  print('$pass passed, $fail failed');
  if (fail > 0) throw StateError('$fail failed');
}
