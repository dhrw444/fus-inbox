import 'package:flutter_test/flutter_test.dart';
import 'package:fus_inbox/core/proxy/active_proxy.dart';
import 'package:fus_inbox/core/proxy/proxy_config.dart';
import 'package:fus_inbox/features/numbers/data/numbers_repository.dart';

ProxyConfig _config(ProxyScheme scheme, {int port = 1080}) => ProxyConfig(
  id: buildProxyId(scheme, '10.0.0.1', port),
  scheme: scheme,
  host: '10.0.0.1',
  port: port,
);

ActiveProxy _active(
  ProxyConfig config, {
  required int bridgePort,
  bool ok = true,
}) =>
    ActiveProxy(config: config, bridgePort: bridgePort, ok: ok, detail: 'test');

void main() {
  group('nativeEgressDirective', () {
    test('没有当前出口 → null', () {
      expect(nativeEgressDirective(null), isNull);
    });

    test('直连 → DIRECT', () {
      final direct = _config(ProxyScheme.direct);
      expect(nativeEgressDirective(_active(direct, bridgePort: 0)), 'DIRECT');
    });

    test('桥起来了 → 指向桥的端口，不是上游的端口', () {
      final socks = _config(ProxyScheme.socks5, port: 1081);
      expect(
        nativeEgressDirective(_active(socks, bridgePort: 47123)),
        'PROXY 127.0.0.1:47123',
      );
    });

    // 这一条是本次改动锁住的回归点。
    //
    // 旧实现在桥没起来时返回 `PROXY 上游host:上游port`。对 SOCKS5 来说
    // 那是个 SOCKS 端口，而 findProxy 只认 HTTP 代理 —— 指令要么不通，
    // 要么退化成直连。两种情况都不是「走代理」，而且外面看不出来。
    test('桥没起来 → null（让请求失败），绝不给上游地址', () {
      final socks = _config(ProxyScheme.socks5, port: 1081);
      expect(nativeEgressDirective(_active(socks, bridgePort: 0)), isNull);

      final http = _config(ProxyScheme.http, port: 8080);
      expect(nativeEgressDirective(_active(http, bridgePort: 0)), isNull);
    });

    test('ok=false 但桥在 → 仍然指向桥（桥自己会回 502）', () {
      final socks = _config(ProxyScheme.socks5);
      expect(
        nativeEgressDirective(_active(socks, bridgePort: 47123, ok: false)),
        'PROXY 127.0.0.1:47123',
      );
    });
  });

  group('directoryEgressUsable', () {
    test('没有当前出口 → 不可用', () {
      expect(directoryEgressUsable(null), isFalse);
    });

    test('直连 → 不可用（不搭直连的顺风车）', () {
      final direct = _config(ProxyScheme.direct);
      expect(directoryEgressUsable(_active(direct, bridgePort: 0)), isFalse);
    });

    test('任何代理、桥起来了 → 可用', () {
      for (final scheme in [
        ProxyScheme.socks5,
        ProxyScheme.socks5h,
        ProxyScheme.http,
        ProxyScheme.https,
      ]) {
        expect(
          directoryEgressUsable(_active(_config(scheme), bridgePort: 47123)),
          isTrue,
          reason: '$scheme 经桥应该可用',
        );
      }
    });

    // 回归点：旧实现让 HTTP/HTTPS 直接返回 true，不看桥在不在。
    // 桥起不来时目录照样往外打，而 WebView 那边已经走不通 ——
    // 同一个 App 两条链路走两个 IP。
    test('任何代理、桥没起来 → 不可用', () {
      for (final scheme in [
        ProxyScheme.socks5,
        ProxyScheme.socks5h,
        ProxyScheme.http,
        ProxyScheme.https,
      ]) {
        expect(
          directoryEgressUsable(_active(_config(scheme), bridgePort: 0)),
          isFalse,
          reason: '$scheme 桥没起来应该不可用',
        );
      }
    });
  });
}
