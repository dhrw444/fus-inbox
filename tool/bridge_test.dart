/// 端到端：本机 HTTP 桥 → SOCKS5 → 目标服务器。
///
/// 三段都是真的：真 ServerSocket、真 HTTP 解析、真 SOCKS5 握手。
/// 唯一假的是「远端代理」—— 本地起一个按 RFC 说话的假服务端。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'proxy_config.dart';
import 'local_http_bridge.dart';

int pass = 0, fail = 0;
void ok(bool c, String label) {
  if (c) { pass++; } else { fail++; print('FAIL  $label'); }
}
void eq(Object? a, Object? b, String label) {
  if (a == b) { pass++; } else { fail++; print('FAIL  $label  got=$a want=$b'); }
}

class _R {
  _R(Socket s) {
    _sub = s.listen((c) { _b.addAll(c); _p(); }, onError: (Object _) {}, onDone: () {});
  }
  late final StreamSubscription<Uint8List> _sub;
  final List<int> _b = [];
  Completer<Uint8List>? _w;
  int _n = 0;
  void _p() {
    final w = _w;
    if (w == null || _b.length < _n) return;
    final o = Uint8List.fromList(_b.sublist(0, _n));
    _b.removeRange(0, _n);
    _w = null;
    w.complete(o);
  }
  Future<Uint8List> read(int n) {
    if (_b.length >= n) {
      final o = Uint8List.fromList(_b.sublist(0, n));
      _b.removeRange(0, n);
      return Future.value(o);
    }
    final c = Completer<Uint8List>();
    _w = c; _n = n;
    return c.future.timeout(const Duration(seconds: 5));
  }
}

/// 假 SOCKS5：握手成功后把连接接到真正的目标服务器上。
class FakeSocks5 {
  late ServerSocket _srv;
  int get port => _srv.port;
  String lastHost = '';
  int lastPort = 0;

  Future<void> start() async {
    _srv = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _srv.listen(_handle);
  }
  Future<void> stop() async => _srv.close();

  Future<void> _handle(Socket s) async {
    final r = _R(s);
    try {
      final g = await r.read(2);
      final m = await r.read(g[1]);
      if (!m.contains(0x00)) { s.destroy(); return; }
      s.add(Uint8List.fromList([0x05, 0x00]));
      await s.flush();

      final h = await r.read(4);
      String host;
      if (h[3] == 0x03) {
        final l = await r.read(1);
        final d = await r.read(l[0]);
        host = utf8.decode(d);
      } else if (h[3] == 0x01) {
        final a = await r.read(4);
        host = a.join('.');
      } else {
        final a = await r.read(16);
        host = InternetAddress.fromRawAddress(Uint8List.fromList(a)).address;
      }
      final pb = await r.read(2);
      final port = (pb[0] << 8) | pb[1];
      lastHost = host;
      lastPort = port;

      // 真的连过去
      Socket up;
      try {
        up = await Socket.connect(host, port, timeout: const Duration(seconds: 4));
      } catch (_) {
        s.add(Uint8List.fromList([0x05, 0x05, 0x00, 0x01, 0, 0, 0, 0, 0, 0]));
        await s.flush();
        s.destroy();
        return;
      }
      s.add(Uint8List.fromList([0x05, 0x00, 0x00, 0x01, 127, 0, 0, 1, 0x1F, 0x90]));
      await s.flush();

      // 双向转发
      s.listen(up.add, onError: (Object _) => up.destroy(),
          onDone: () => up.destroy(), cancelOnError: true);
      up.listen(s.add, onError: (Object _) => s.destroy(),
          onDone: () => s.destroy(), cancelOnError: true);
    } catch (_) {
      s.destroy();
    }
  }
}

Future<void> main() async {
  final socks = FakeSocks5();
  await socks.start();
  final proxy = parseProxyLine('socks5h://127.0.0.1:${socks.port}')!;

  // ---------- 目标服务器：一个真的 HTTP 服务 ----------
  final target = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final targetPort = target.port;
  final seen = <String>[];
  target.listen((s) async {
    final r = _R(s);
    try {
      final b = await r.read(4);
      // 简单读一段直到 \r\n\r\n
      final buf = <int>[...b];
      while (true) {
        final c = await r.read(1);
        buf.addAll(c);
        if (buf.length >= 4 &&
            buf[buf.length - 4] == 13 && buf[buf.length - 3] == 10 &&
            buf[buf.length - 2] == 13 && buf[buf.length - 1] == 10) break;
      }
      final req = utf8.decode(buf);
      seen.add(req);
      s.add(utf8.encode(
        'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n'
        'Content-Length: 11\r\nConnection: close\r\n\r\nhello-world'));
      await s.flush();
      s.destroy();
    } catch (_) { s.destroy(); }
  });

  final bridge = await LocalProxyBridge.start(proxy);
  print('bridge port ${bridge.port}');

  // ---------- 1. CONNECT 隧道（HTTPS 主路径）----------
  {
    final c = await Socket.connect('127.0.0.1', bridge.port);
    c.write('CONNECT 127.0.0.1:$targetPort HTTP/1.1\r\n'
        'Host: 127.0.0.1:$targetPort\r\n\r\n');
    await c.flush();
    final r = _R(c);
    final resp = <int>[];
    while (true) {
      final b = await r.read(1);
      resp.addAll(b);
      if (resp.length >= 4 &&
          resp[resp.length - 4] == 13 && resp[resp.length - 3] == 10 &&
          resp[resp.length - 2] == 13 && resp[resp.length - 1] == 10) break;
    }
    final head = utf8.decode(resp);
    ok(head.startsWith('HTTP/1.1 200'), 'CONNECT returns 200');

    // 隧道通了，发一个真 HTTP 请求穿过去
    c.write('GET / HTTP/1.1\r\nHost: x\r\n\r\n');
    await c.flush();
    final body = <int>[];
    final sub = c.listen(body.addAll, onDone: () {});
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await sub.cancel();
    final text = utf8.decode(body, allowMalformed: true);
    ok(text.contains('hello-world'), 'CONNECT tunnel carries real HTTP');
    eq(socks.lastPort, targetPort, 'SOCKS5 got right target port');
    c.destroy();
  }

  // ---------- 2. 明文 HTTP 绝对 URI ----------
  {
    seen.clear();
    final c = await Socket.connect('127.0.0.1', bridge.port);
    c.write('GET http://127.0.0.1:$targetPort/path?q=1 HTTP/1.1\r\n'
        'Host: 127.0.0.1:$targetPort\r\n'
        'Proxy-Connection: keep-alive\r\n\r\n');
    await c.flush();
    final body = <int>[];
    final sub = c.listen(body.addAll, onDone: () {});
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await sub.cancel();
    final text = utf8.decode(body, allowMalformed: true);
    ok(text.contains('hello-world'), 'absolute URI reaches target');
    ok(seen.isNotEmpty, 'target saw the request');
    if (seen.isNotEmpty) {
      ok(seen.first.startsWith('GET /path?q=1 HTTP/1.1'),
          'request line rewritten to path: ${seen.first.split('\r\n').first}');
      ok(!seen.first.toLowerCase().contains('proxy-connection'),
          'proxy-connection stripped');
    }
    c.destroy();
  }

  // ---------- 3. 坏 CONNECT ----------
  {
    final c = await Socket.connect('127.0.0.1', bridge.port);
    c.write('CONNECT nonsense HTTP/1.1\r\n\r\n');
    await c.flush();
    final b = <int>[];
    final sub = c.listen(b.addAll, onDone: () {});
    await Future<void>.delayed(const Duration(milliseconds: 400));
    await sub.cancel();
    ok(utf8.decode(b, allowMalformed: true).contains('400'),
        'bad CONNECT gives 400');
    c.destroy();
  }

  // ---------- 4. 上游代理死了 → 502 ----------
  {
    final deadProxy = parseProxyLine('socks5://127.0.0.1:1')!;
    final deadBridge = await LocalProxyBridge.start(deadProxy);
    final c = await Socket.connect('127.0.0.1', deadBridge.port);
    c.write('CONNECT example.com:443 HTTP/1.1\r\n\r\n');
    await c.flush();
    final b = <int>[];
    final sub = c.listen(b.addAll, onDone: () {});
    await Future<void>.delayed(const Duration(milliseconds: 900));
    await sub.cancel();
    final text = utf8.decode(b, allowMalformed: true);
    ok(text.contains('502'), 'dead upstream gives 502');
    c.destroy();
    await deadBridge.stop();
  }

  await bridge.stop();
  await socks.stop();
  await target.close();
  print('\n$pass passed, $fail failed');
  exit(0);
}
