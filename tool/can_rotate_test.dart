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
import 'package:fus_inbox/core/proxy/proxy_pool_ops.dart';
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
  print('=== 9. 账本里有记录也一样能换（换的是出口，不是计数）===');
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
    );
    final s = ProxyState(pool: [a, b], currentId: a.id, ledger: ledger);
    ok(s.canRotate, '当前出口看过号，池里还有别的 → 能换');
  }

  print('');
  print('=== 10. 出口 IP：优先挑 IP 不同的那条 ===');
  {
    // 配额按出口 IP 算，不按代理条目。两条端口落到同一个出口 IP 时，
    // 换过去只是换了个条目名 —— 站点看到的 IP 和额度一点没变，
    // 用户看到的就是「点了换出口，IP 没变」。
    final a = mk('1.1.1.1');
    final same = mk('2.2.2.2');
    final other = mk('3.3.3.3');
    final results = {
      a.id: ProxyProbeResult(proxy: a, ok: true, egressIp: '1.1.1.1'),
      same.id: ProxyProbeResult(proxy: same, ok: true, egressIp: '1.1.1.1'),
      other.id: ProxyProbeResult(proxy: other, ok: true, egressIp: '7.7.7.7'),
    };
    final choice = pickRotation(
      all: [a, same, other],
      results: results,
      ledger: IdentityLedger(),
      currentId: a.id,
    );
    ok(
      choice?.next.id == other.id,
      '跳过同 IP 的条目，挑到不同 IP 的那条',
      '(挑的是 ${choice?.next.host})',
    );
  }

  print('');
  print('=== 11. 全都是同一个出口 IP：仍然要给出下一条 ===');
  {
    // 一条都不换 = 按钮死掉，那是这个函数要避免的失败模式。
    // 真换成同一个 IP 的话，由上层拿实测结果如实告诉用户。
    final a = mk('1.1.1.1');
    final b = mk('2.2.2.2');
    final results = {
      a.id: ProxyProbeResult(proxy: a, ok: true, egressIp: '1.1.1.1'),
      b.id: ProxyProbeResult(proxy: b, ok: true, egressIp: '1.1.1.1'),
    };
    final choice = pickRotation(
      all: [a, b],
      results: results,
      ledger: IdentityLedger(),
      currentId: a.id,
    );
    ok(choice?.next.id == b.id, '同 IP 也得给一条（不能让按钮死掉）');
    ok(
      ProxyState(pool: [a, b], currentId: a.id, results: results).canRotate,
      'canRotate 和 pickRotation 结论一致',
    );
  }

  print('');
  print('=== 12. 出口 IP 未知的不参与比较 ===');
  {
    // 没测过 = 不知道它跟谁撞 IP，既不能当它一样也不能当它不一样。
    // 两条候选：一条和当前同 IP，一条未知 —— 该挑未知的那条。
    final a = mk('1.1.1.1');
    final same = mk('2.2.2.2');
    final unknown = mk('3.3.3.3');
    final results = {
      a.id: ProxyProbeResult(proxy: a, ok: true, egressIp: '1.1.1.1'),
      same.id: ProxyProbeResult(proxy: same, ok: true, egressIp: '1.1.1.1'),
      unknown.id: ProxyProbeResult(proxy: unknown, ok: true),
    };
    final choice = pickRotation(
      all: [a, same, unknown],
      results: results,
      ledger: IdentityLedger(),
      currentId: a.id,
    );
    ok(
      choice?.next.id == unknown.id,
      '未知 IP 的排在「已知同 IP」前面',
      '(挑的是 ${choice?.next.host})',
    );
  }

  print('');
  print('=== 13. 当前出口的 IP 未知：不做任何偏好 ===');
  {
    final a = mk('1.1.1.1');
    final b = mk('2.2.2.2');
    final results = {
      a.id: ProxyProbeResult(proxy: a, ok: true),
      b.id: ProxyProbeResult(proxy: b, ok: true, egressIp: '7.7.7.7'),
    };
    final choice = pickRotation(
      all: [a, b],
      results: results,
      ledger: IdentityLedger(),
      currentId: a.id,
    );
    ok(choice?.next.id == b.id, '当前 IP 未知 → 照旧挑下一条');
  }

  print('');
  print('$pass passed, $fail failed');
  if (fail > 0) throw StateError('$fail failed');
}
