// 号码目录这条链路的出口行为：直连 / 走代理 / 拒绝直连。
//
// ## 为什么这个测试必须存在
//
// 这一层是 `dart:io` 原生 HTTP，**不经过 WebView 的 `ProxyController`**。
// 挂了 `findProxy` 才会走代理，不挂就是直连 —— 而且从外部看不出任何
// 区别：请求照样成功、状态码照样 200、没有一行报错。
//
// 所以判据不能是「有没有成功」，只能是「流量到底有没有穿过 SOCKS5」。
// 这个测试盯的就是假 SOCKS5 上的连接数：
//
//   直连      → 连接数不变
//   走代理    → 连接数 +1
//   拒绝直连  → 连接数不变，**而且目标服务器一次都没被访问**
//
// 最后一条是重点：它证明「拿不到出口」时请求是真的没发出去，而不是
// 悄悄走了直连。

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fus_inbox/core/proxy/local_http_bridge.dart';
import 'package:fus_inbox/core/proxy/proxy_config.dart';
import 'package:fus_inbox/features/numbers/data/numbers_repository.dart';

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

/// 最小定长读取器。Socket 只能 listen 一次，读完要切转发。
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

/// 假 SOCKS5：握手成功后接到真实目标。只数连接，不做别的。
class FakeSocks5 {
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
      // 问候包是 [ver, nmethods, methods...]。必须把 methods 一起读掉，
      // 否则它们留在缓冲里会让后面的 CONNECT 整体错位一字节。
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

      Socket up;
      try {
        up = await Socket.connect(
          host,
          port,
          timeout: const Duration(seconds: 4),
        );
      } catch (_) {
        s.add(Uint8List.fromList([0x05, 0x05, 0x00, 0x01, 0, 0, 0, 0, 0, 0]));
        await s.flush();
        s.destroy();
        return;
      }
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

/// 假站点：只回一个不含号码卡片的空页面。
///
/// 不能回真的目录页 —— 那要靠站点模板，模板一变测试就跟着红。
/// 这里要验的是**请求走哪条出口**，跟页面内容无关，所以越简单越好。
Future<(ServerSocket, List<int>)> startFakeSite() async {
  final srv = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final hits = <int>[];
  srv.listen((s) async {
    hits.add(1);
    final r = _R(s);
    try {
      final buf = <int>[];
      while (true) {
        final c = await r.read(1);
        buf.add(c[0]);
        if (buf.length >= 4 &&
            buf[buf.length - 4] == 13 &&
            buf[buf.length - 3] == 10 &&
            buf[buf.length - 2] == 13 &&
            buf[buf.length - 1] == 10) {
          break;
        }
      }
      const body = '<!doctype html><html><body><p>no cards</p></body></html>';
      s.write(
        'HTTP/1.1 200 OK\r\n'
        'Content-Type: text/html; charset=utf-8\r\n'
        'Content-Length: ${body.length}\r\n'
        'Connection: close\r\n\r\n$body',
      );
      await s.flush();
      await s.close();
    } catch (_) {
      s.destroy();
    }
  });
  return (srv, hits);
}

Future<void> main() async {
  final socks = FakeSocks5();
  await socks.start();
  final (site, hits) = await startFakeSite();
  final base = 'http://127.0.0.1:${site.port}';

  // 桥：HTTP 代理 → SOCKS5。这就是生产里 WebView 用的那条，
  // 目录要挂出口时也应该走同一个东西。
  final proxy = parseProxyLine('socks5h://127.0.0.1:${socks.port}')!;
  final bridge = await LocalProxyBridge.start(upstream: proxy);
  print('假 SOCKS5 :${socks.port} / 假站点 :${site.port} / 桥 :${bridge.port}');

  // ---------- 1. 没注入 egress = 直连 ----------
  print('');
  print('=== 1. 直连（默认） ===');
  {
    hits.clear();
    final before = socks.connections;
    final repo = NumbersRepository(base: base);
    try {
      await repo.fetchPage(1);
    } catch (e) {
      ok(false, '直连抓页', '$e');
    }
    ok(hits.isNotEmpty, '请求到了目标站', '(hits=${hits.length})');
    ok(
      socks.connections == before,
      '没碰 SOCKS5 —— 确认是直连',
      '(delta=${socks.connections - before})',
    );
    repo.dispose();
  }

  // ---------- 2. 要代理但拿不到 → 拒绝直连 ----------
  print('');
  print('=== 2. 出口拿不到时拒绝直连 ===');
  {
    hits.clear();
    final before = socks.connections;
    final repo = NumbersRepository(base: base, egress: () => null);
    var msg = '';
    try {
      await repo.fetchPage(1);
    } catch (e) {
      msg = '$e';
    }
    ok(msg.isNotEmpty, '请求失败了', '(${msg.split('\n').first})');
    ok(msg.contains('出口没起来'), '错误说清了原因');
    ok(hits.isEmpty, '**目标站一次都没被访问** —— 没有悄悄直连');
    ok(socks.connections == before, '也没碰 SOCKS5', '');
    repo.dispose();
  }

  // ---------- 3. 给了出口 → 真的穿过 SOCKS5 ----------
  print('');
  print('=== 3. 走代理 ===');
  {
    hits.clear();
    final before = socks.connections;
    final repo = NumbersRepository(
      base: base,
      egress: () => 'PROXY 127.0.0.1:${bridge.port}',
    );
    try {
      await repo.fetchPage(1);
    } catch (e) {
      ok(false, '经桥抓页', '$e');
    }
    ok(hits.isNotEmpty, '页面照样拿到了', '(hits=${hits.length})');
    ok(
      socks.connections > before,
      '流量真的穿过了 SOCKS5',
      '(delta=${socks.connections - before})',
    );
    repo.dispose();
  }

  // ---------- 4. 出口指向桥，但桥后面 SOCK5 不可用 → 失败而非直连 ----------
  print('');
  print('=== 4. 桥后面挂了也不能退回直连 ===');
  {
    hits.clear();
    final dead = parseProxyLine('socks5h://127.0.0.1:1')!;
    final deadBridge = await LocalProxyBridge.start(upstream: dead);
    final repo = NumbersRepository(
      base: base,
      egress: () => 'PROXY 127.0.0.1:${deadBridge.port}',
    );
    var threw = false;
    try {
      await repo.fetchPage(1);
    } catch (_) {
      threw = true;
    }
    ok(threw, '上游代理不可用时请求失败');
    ok(hits.isEmpty, '失败而不是退回直连 —— 没泄漏真实 IP');
    repo.dispose();
    await deadBridge.stop();
  }

  await bridge.stop();
  await socks.stop();
  await site.close();

  print('');
  print('$pass passed, $fail failed');
  // **无条件**退出。这个文件**不在** gate.dart 的 import 列表里，CI 单独跑它。
  // 跑完 VM 不会自己结束（未取消的 socket 订阅吊着事件循环），
  // 不 exit 的话 CI 那一步会一直挂到 job 超时。
  exit(fail == 0 ? 0 : 1);
}
