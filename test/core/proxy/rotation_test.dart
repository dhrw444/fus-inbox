import 'package:flutter_test/flutter_test.dart';
import 'package:fus_inbox/core/proxy/identity_ledger.dart';
import 'package:fus_inbox/core/proxy/proxy_config.dart';
import 'package:fus_inbox/core/proxy/proxy_pool_ops.dart';
import 'package:fus_inbox/core/proxy/proxy_probe.dart';
import 'package:fus_inbox/core/proxy/proxy_state.dart';

ProxyConfig mk(String host) => ProxyConfig(
  id: 'socks5://$host:1081',
  scheme: ProxyScheme.socks5,
  host: host,
  port: 1081,
);

/// 一个在 [p] 上已经看满 [used] 个号的账本。
IdentityLedger filled(ProxyConfig p, {int used = 3}) => IdentityLedger(
  bindings: {
    p.id: IdentityBinding(
      proxyId: p.id,
      userAgent: 'UA',
      model: 'Pixel 8',
      chromeMajor: '141',
      openedNumbers: [for (var i = 0; i < used; i++) 'n$i'],
      createdAtMs: 1,
    ),
  },
  owners: {for (var i = 0; i < used; i++) 'n$i': p.id},
);

void main() {
  group('pickRotation 绝不在同一 IP 上换身份', () {
    test('池里只有一条 → 返回 null，不是「选回自己再清身份」', () {
      final a = mk('1.1.1.1');
      final ledger = filled(a);
      final choice = pickRotation(
        all: [a],
        results: const {},
        ledger: ledger,
        currentId: a.id,
      );
      // 旧实现会 `?? candidates.first` 选回 a，然后因为 a 已满而清掉它的
      // 身份 —— 同一个 IP 上重置浏览器身份，比不换更可疑。
      expect(choice, isNull);
    });

    test('两条、另一条可用 → 换到另一条', () {
      final a = mk('1.1.1.1');
      final b = mk('2.2.2.2');
      final ledger = filled(a);
      final choice = pickRotation(
        all: [a, b],
        results: const {},
        ledger: ledger,
        currentId: a.id,
      );
      expect(choice, isNotNull);
      expect(choice!.next.id, b.id);
    });

    test('另一条判死 → 返回 null（不是退回当前那条）', () {
      final a = mk('1.1.1.1');
      final b = mk('2.2.2.2');
      final ledger = filled(a);
      final choice = pickRotation(
        all: [a, b],
        results: {b.id: ProxyProbeResult(proxy: b, ok: false)},
        ledger: ledger,
        currentId: a.id,
      );
      // b 判死 → usable 为空 → 全池当候选 → 剔掉当前那条 a 之后为空。
      expect(choice, isNull);
    });

    test('目标出口没有绑定 → 需要铸新身份', () {
      final a = mk('1.1.1.1');
      final b = mk('2.2.2.2');
      final ledger = filled(a);
      final choice = pickRotation(
        all: [a, b],
        results: const {},
        ledger: ledger,
        currentId: a.id,
      );
      expect(choice!.clearBinding, isTrue);
    });
  });

  group('canRotate 与 pickRotation 用同一判据', () {
    test('只有一条 → 不能轮换', () {
      final a = mk('1.1.1.1');
      final state = ProxyState(pool: [a], currentId: a.id, ledger: filled(a));
      expect(state.canRotate, isFalse);
    });

    test('有另一条 → 可以轮换', () {
      final a = mk('1.1.1.1');
      final b = mk('2.2.2.2');
      final state = ProxyState(
        pool: [a, b],
        currentId: a.id,
        ledger: filled(a),
      );
      expect(state.canRotate, isTrue);
    });
  });

  group('ProxyConfig 值相等覆盖凭据', () {
    test('只改密码也算换了一条（否则桥会静默继续打旧出口）', () {
      final a = ProxyConfig(
        id: 'socks5://1.1.1.1:1081',
        scheme: ProxyScheme.socks5,
        host: '1.1.1.1',
        port: 1081,
        username: 'u',
        password: 'p1',
      );
      final b = ProxyConfig(
        id: 'socks5://1.1.1.1:1081',
        scheme: ProxyScheme.socks5,
        host: '1.1.1.1',
        port: 1081,
        username: 'u',
        password: 'p2',
      );
      expect(a == b, isFalse);
    });

    test('label 不参与相等（只是显示名）', () {
      final a = ProxyConfig(
        id: 'socks5://1.1.1.1:1081',
        scheme: ProxyScheme.socks5,
        host: '1.1.1.1',
        port: 1081,
        username: 'u',
        password: 'p',
        label: 'x',
      );
      final b = ProxyConfig(
        id: 'socks5://1.1.1.1:1081',
        scheme: ProxyScheme.socks5,
        host: '1.1.1.1',
        port: 1081,
        username: 'u',
        password: 'p',
        label: 'y',
      );
      expect(a == b, isTrue);
    });
  });

  group('换出口 = 给离开的那条留烧痕，不再把它切回来', () {
    /// 一条出口撞了额度墙之后留的烧痕。
    void burn(IdentityLedger ledger, ProxyConfig p) => ledger.burn(
      p.id,
      untilMs: DateTime.now().millisecondsSinceEpoch + 60000,
    );

    OpenPlan open(IdentityLedger ledger, List<ProxyConfig> pool, String cur) =>
        ledger.plan(
          pool: pool,
          currentProxyId: cur,
          numberId: 'n1',
          mintUserAgent: () => 'UA',
          mintModel: () => 'Pixel 8',
          mintChromeMajor: () => '141',
        );

    test('归属出口烧掉之后不再被切回去', () {
      final a = mk('1.1.1.1');
      final b = mk('2.2.2.2');
      // a 上看过 n0/n1/n2，`owners` 里那三个号都写着归 a。
      final ledger = filled(a);
      // 用户在 a 上被站点拒了 → rotateToNext 换到 b 并给 a 留烧痕。
      burn(ledger, a);

      final plan = open(ledger, [a, b], b.id);
      // 旧行为是 restore → a：界面写着换了出口，实际回到烧掉的那条。
      expect(plan.action, isNot(OpenAction.restore));
      expect(plan.proxy.id, b.id);
    });

    test('烧痕过期之后归属又能切回去', () {
      final a = mk('1.1.1.1');
      final b = mk('2.2.2.2');
      final ledger = filled(a);
      ledger.burn(
        a.id,
        untilMs: DateTime.now().millisecondsSinceEpoch - 1,
      );
      expect(ledger.isBurned(a.id), isFalse);

      // 站点那边额度恢复了、烧痕也跟着过期 —— 这时切回 a 是对的：
      // a 上那台设备才认得 n1。剔得太狠会把这条正路也堵死。
      final plan = open(ledger, [a, b], b.id);
      expect(plan.action, OpenAction.restore);
      expect(plan.proxy.id, a.id);
    });

    test('挑下一条出口时跳过烧着的', () {
      final a = mk('1.1.1.1');
      final b = mk('2.2.2.2');
      final c = mk('3.3.3.3');
      final ledger = filled(a);
      burn(ledger, b);
      // 按顺序本该挑 b，但 b 刚被拒过 —— 挑 c。
      expect(ledger.nextUsableProxy([a, b, c], a.id)?.id, c.id);
    });

    test('烧痕落盘再读回来还在', () {
      final a = mk('1.1.1.1');
      final ledger = filled(a);
      burn(ledger, a);
      final back = IdentityLedger.fromJson(ledger.toJson());
      // 不落盘的话重启就把烧痕抹了，点同一个号又被拉回那条出口。
      expect(back.isBurned(a.id), isTrue);
    });

    test('直连（空 id）不记烧痕', () {
      final ledger = IdentityLedger();
      ledger.burn('', untilMs: DateTime.now().millisecondsSinceEpoch + 1000);
      // 直连没有「换一条出口」这回事，烧了它等于把整池都剔掉。
      expect(ledger.isBurned(''), isFalse);
      expect(ledger.burnedNow(), isEmpty);
    });
  });
}
