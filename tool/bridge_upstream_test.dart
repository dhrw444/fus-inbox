// 常驻桥 + 上游热切换。
//
// ## 这条行为为什么必须测
//
// Windows 上 WebView2 的代理**只能在创建环境时**定一次
// （`--proxy-server=127.0.0.1:<端口>`），之后改不了。所以整个 App 的
// 「按号换出口」只能落在一条**常驻固定端口**的桥身上：WebView 永远指向
// 它，换号换的是桥的上游。
//
// Android 同理受益：不必每换一次号就重启桥、重握一次 SOCKS5。
//
// 判据只有一条 —— **同一端口、不重建桥，流量真的换了出口**：
//
//   上游 = 假SOCKS5 #1   →  连接数落在 #1 上
//   setUpstream(#2)      →  连接数落在 #2 上，#1 不再增加
//   setUpstream(null)    →  直连，两条 SOCKS5 都不再增加

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fus_inbox/core/proxy/local_http_bridge.dart';
import 'package:fus_inbox/core/proxy/proxy_config.dart';

int pass = 0;
int fail = 0;

void ok(bool c, String name, [String extra = '']) {
  if (c) {
    pass++;
    print('  ok   $name  $extra');
  } else {
    fail++;
    print('  FAIL $name  $extra');
  }
}

class _R {
  // ignore: use_primary_constructors
  _R(Socket s) {
    s.listen(
      (c) {
        if (_sink != null) {
          _sink!(c);
          return;
        }
        _buf.addAll(c);
      },
      onError: (Object _) {},
      cancelOnError: false,
    );
  }

  final List<int> _buf = [];
  void Function(Uint8List)? _sink;

  Future<Uint8List> read(int n) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (_buf.length < n) {
      if (DateTime.now().isAfter(deadline)) {
        throw StateError('读超时 ${_buf.length}/$n');
      }
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    final out = Uint8List.fromList(_buf.sublist(0, n));
    _buf.removeRange(0, n);
    return out;
  }

  void forwardTo(void Function(Uint8List) sink) {
    _sink = sink;
    if (_buf.isNotEmpty) {
      sink(Uint8List.fromList(_buf));
      _buf.clear();
    }
  }
}

/// 假 SOCKS5：握手后接到真实目标，只数连接。
class FakeSocks {
  FakeSocks(this.name);
  final String name;
  late ServerSocket _srv;
  int get port => _srv.port;
  int connections = 0;

  Future<void> start() async {
    _srv = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _srv.listen(_handle);
  }

  Future<void> stop() async => _srv.close();

  Future<void> _handle(Socket s) async {
    connections++;
    final r = _R(s);
    try {
      final g = await r.read(2);
      final m = await r.read(g[1]);
      if (!m.contains(0x00)) {
        s.destroy();
        return;
      }
      s.add(Uint8List.fromList([0x05, 0x00]));
      await s.flush();
      final h = await r.read(4);
      String host;
      if (h[3] == 0x03) {
        final l = await r.read(1);
        host = utf8.decode(await r.read(l[0]));
      } else if (h[3] == 0x01) {
        host = (await r.read(4)).join('.');
      } else {
        host = InternetAddress.fromRawAddress(await r.read(16)).address;
      }
      final pb = await r.read(2);
      final port = (pb[0] << 8) | pb[1];
      final up = await Socket.connect(host, port);
      s.add(
        Uint8List.fromList([0x05, 0x00, 0x00, 0x01, 127, 0, 0, 1, 0x1F, 0x90]),
      );
      await s.flush();
      r.forwardTo(up.add);
      up.listen(
        s.add,
        onError: (Object _) => s.destroy(),
        onDone: () => s.destroy(),
        cancelOnError: true,
      );
    } catch (_) {
      s.destroy();
    }
  }
}

/// 通过桥发一个明文 HTTP 请求，返回响应首行。
Future<String> throughBridge(
  int bridgePort,
  String targetHost,
  int targetPort,
) async {
  final c = await Socket.connect('127.0.0.1', bridgePort);
  c.write(
    'GET http://$targetHost:$targetPort/ HTTP/1.1\r\n'
    'Host: $targetHost\r\n'
    'Connection: close\r\n\r\n',
  );
  await c.flush();
  final r = _R(c);
  final deadline = DateTime.now().add(const Duration(seconds: 6));
  final buf = <int>[];
  try {
    while (DateTime.now().isBefore(deadline)) {
      final b = await r.read(1);
      buf.add(b[0]);
      if (buf.length >= 12) break;
    }
  } catch (_) {}
  c.destroy();
  return utf8.decode(buf, allowMalformed: true);
}

Future<void> main() async {
  final socks1 = FakeSocks('1');
  final socks2 = FakeSocks('2');
  await socks1.start();
  await socks2.start();

  var hits = 0;
  final site = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  site.listen((s) async {
    hits++;
    try {
      s.write(
        'HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK',
      );
      await s.flush();
      await s.close();
    } catch (_) {
      s.destroy();
    }
  });

  final p1 = parseProxyLine('socks5h://127.0.0.1:${socks1.port}')!;
  final p2 = parseProxyLine('socks5h://127.0.0.1:${socks2.port}')!;

  // 固定端口起一条桥（Windows 的形态）。
  final fixed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final fixedPort = fixed.port;
  await fixed.close();

  final bridge = await LocalProxyBridge.start(upstream: p1, port: fixedPort);
  print('  桥固定在端口 ${bridge.port}（请求的 $fixedPort）');
  ok(bridge.port == fixedPort, '桥绑在指定端口上');

  print('');
  print('=== 1. 初始上游 #1 ===');
  hits = 0;
  final c1 = socks1.connections;
  final c2 = socks2.connections;
  await throughBridge(bridge.port, '127.0.0.1', site.port);
  ok(hits > 0, '请求到了目标站');
  ok(socks1.connections > c1, '走了上游 #1', '(#1 +${socks1.connections - c1})');
  ok(socks2.connections == c2, '没碰上游 #2');

  print('');
  print('=== 2. 热切换到上游 #2（不重建桥）===');
  hits = 0;
  final c1b = socks1.connections;
  final c2b = socks2.connections;
  bridge.setUpstream(p2);
  ok(bridge.port == fixedPort, '端口没变 —— 桥没被重建');
  ok(bridge.upstreamSwitches == 1, '记录了一次切换');
  await throughBridge(bridge.port, '127.0.0.1', site.port);
  ok(hits > 0, '请求仍然到了目标站');
  ok(socks2.connections > c2b, '改走上游 #2', '(#2 +${socks2.connections - c2b})');
  ok(socks1.connections == c1b, '上游 #1 不再增加', '(零新增)');

  print('');
  print('=== 3. 切到直连（upstream = null）===');
  hits = 0;
  final c1c = socks1.connections;
  final c2c = socks2.connections;
  bridge.setUpstream(null);
  await throughBridge(bridge.port, '127.0.0.1', site.port);
  ok(hits > 0, '直连也照样到目标站 —— 桥能自己出网');
  ok(socks1.connections == c1c && socks2.connections == c2c, '两条上游都没动');

  print('');
  print('=== 4. 切回上游 #1 ===');
  hits = 0;
  final c1d = socks1.connections;
  bridge.setUpstream(p1);
  await throughBridge(bridge.port, '127.0.0.1', site.port);
  ok(hits > 0, '又回到目标站');
  ok(socks1.connections > c1d, '重新走 #1');
  ok(bridge.port == fixedPort, '全程端口一致');

  await bridge.stop();
  await socks1.stop();
  await socks2.stop();
  await site.close();

  print('');
  print('$pass passed, $fail failed');
  exit(fail > 0 ? 1 : 0);
}
