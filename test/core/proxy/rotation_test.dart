import 'package:flutter_test/flutter_test.dart';
import 'package:fus_inbox/core/proxy/identity_ledger.dart';
import 'package:fus_inbox/core/proxy/proxy_config.dart';
import 'package:fus_inbox/core/proxy/proxy_pool_ops.dart';
import 'package:fus_inbox/core/proxy/proxy_probe.dart';
import 'package:fus_inbox/core/proxy/proxy_state.dart';

ProxyConfig mk(String host) =>
    ProxyConfig(id: 'socks5://$host:1081', scheme: ProxyScheme.socks5, host: host, port: 1081);

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
      final state = ProxyState(pool: [a, b], currentId: a.id, ledger: filled(a));
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
}
