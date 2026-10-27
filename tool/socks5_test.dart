/// 假 SOCKS5 服务器 + 假目标服务器，验证客户端的协议实现。
///
/// 不连真实代理 —— 那需要账号。这里自建一个按 RFC 1928/1929 说话的
/// 服务端，逐字节核对客户端发出的内容。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'proxy_config.dart';
import 'socks5_client.dart';

int pass = 0, fail = 0;
void ok(bool c, String label) {
  if (c) { pass++; } else { fail++; print('FAIL  $label'); }
}
void eq(Object? a, Object? b, String label) {
  if (a == b) { pass++; } else { fail++; print('FAIL  $label  got=$a want=$b'); }
}

/// 假 SOCKS5 服务器。记录收到的字节，按预设回复。
class FakeSocks5 {
  FakeSocks5({
    this.requireAuth = false,
    this.goodUser = 'u',
    this.goodPass = 'p',
    this.replyCode = 0x00,
    this.bndAtyp = 0x01,
  });

  final bool requireAuth;
  final String goodUser;
  final String goodPass;
  final int replyCode;
  final int bndAtyp;

  late ServerSocket _server;
  int get port => _server.port;

  /// 客户端发来的全部字节，按阶段记录。
  final List<int> greeting = [];
  final List<int> authBytes = [];
  final List<int> connectReq = [];
  String requestedHost = '';
  int requestedPort = 0;
  bool sawResolveRemotely = false;

  Future<void> start() async {
    _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen(_handle);
  }

  Future<void> stop() async => _server.close();

  Future<void> _handle(Socket s) async {
    final it = _Reader(s);
    try {
      final g = await it.read(2);
      greeting.addAll(g);
      final n = g[1];
      final methods = await it.read(n);
      greeting.addAll(methods);

      if (requireAuth) {
        if (!methods.contains(0x02)) {
          s.add(Uint8List.fromList([0x05, 0xFF]));
          await s.flush();
          s.destroy();
          return;
        }
        s.add(Uint8List.fromList([0x05, 0x02]));
        await s.flush();

        final ah = await it.read(2);
        authBytes.addAll(ah);
        final ulen = ah[1];
        final u = await it.read(ulen);
        authBytes.addAll(u);
        final plenB = await it.read(1);
        authBytes.addAll(plenB);
        final p = await it.read(plenB[0]);
        authBytes.addAll(p);

        final user = utf8.decode(u);
        final pw = utf8.decode(p);
        if (user != goodUser || pw != goodPass) {
          s.add(Uint8List.fromList([0x01, 0x01]));
          await s.flush();
          s.destroy();
          return;
        }
        s.add(Uint8List.fromList([0x01, 0x00]));
        await s.flush();
      } else {
        if (!methods.contains(0x00)) {
          s.add(Uint8List.fromList([0x05, 0x02]));
          await s.flush();
          s.destroy();
          return;
        }
        s.add(Uint8List.fromList([0x05, 0x00]));
        await s.flush();
      }

      final ch = await it.read(4);
      connectReq.addAll(ch);
      final atyp = ch[3];
      if (atyp == 0x01) {
        final a = await it.read(4);
        connectReq.addAll(a);
        requestedHost = a.join('.');
        sawResolveRemotely = false;
      } else if (atyp == 0x03) {
        final l = await it.read(1);
        connectReq.addAll(l);
        final d = await it.read(l[0]);
        connectReq.addAll(d);
        requestedHost = utf8.decode(d);
        sawResolveRemotely = true;
      } else if (atyp == 0x04) {
        final a = await it.read(16);
        connectReq.addAll(a);
        requestedHost = InternetAddress.fromRawAddress(
          Uint8List.fromList(a),
        ).address;
        sawResolveRemotely = false;
      }
      final pb = await it.read(2);
      connectReq.addAll(pb);
      requestedPort = (pb[0] << 8) | pb[1];

      // 回复
      final bnd = bndAtyp == 0x04
          ? [0x04, ...List.filled(16, 0)]
          : [0x01, 127, 0, 0, 1];
      s.add(Uint8List.fromList([0x05, replyCode, 0x00, ...bnd, 0x1F, 0x90]));
      await s.flush();

      if (replyCode != 0x00) {
        s.destroy();
        return;
      }

      // 握手成功后立刻推一段数据，测「残留字节」处理。
      s.add(Uint8List.fromList(utf8.encode('HELLO-FROM-TARGET')));
      await s.flush();
      // 再等一下推第二段，测流是否连续。
      await Future<void>.delayed(const Duration(milliseconds: 80));
      s.add(Uint8List.fromList(utf8.encode('|SECOND')));
      await s.flush();
    } catch (e) {
      // 客户端中途断开是正常的测试路径。
    }
  }
}

class _Reader {
  _Reader(Socket s) {
    _sub = s.listen((c) {
      _buf.addAll(c);
      _pump();
    }, onError: (Object _) {}, onDone: () {});
  }
  late final StreamSubscription<Uint8List> _sub;
  final List<int> _buf = [];
  Completer<Uint8List>? _w;
  int _n = 0;

  void _pump() {
    final w = _w;
    if (w == null || _buf.length < _n) return;
    final out = Uint8List.fromList(_buf.sublist(0, _n));
    _buf.removeRange(0, _n);
    _w = null;
    w.complete(out);
  }

  Future<Uint8List> read(int n) {
    if (_buf.length >= n) {
      final out = Uint8List.fromList(_buf.sublist(0, n));
      _buf.removeRange(0, n);
      return Future.value(out);
    }
    final c = Completer<Uint8List>();
    _w = c;
    _n = n;
    return c.future.timeout(const Duration(seconds: 5));
  }
}

/// 收集隧道里收到的全部数据。
Future<String> drain(SocksTunnel t, {int maxMs = 900}) async {
  final out = <int>[];
  final sub = t.incoming.listen(out.addAll, onError: (Object _) {});
  await Future<void>.delayed(Duration(milliseconds: maxMs));
  await sub.cancel();
  return utf8.decode(out, allowMalformed: true);
}

Future<void> main() async {
  // ---------- 1. 无认证 + 远端解析（socks5h）----------
  {
    final srv = FakeSocks5();
    await srv.start();
    final proxy = parseProxyLine('socks5h://127.0.0.1:${srv.port}')!;
    final t = await SocksTunnel.open(proxy, 'example.com', 443);
    eq(srv.greeting[0], 0x05, 'greeting version');
    eq(srv.greeting[1], 1, 'one method offered');
    eq(srv.greeting[2], 0x00, 'offers no-auth');
    eq(srv.connectReq[1], 0x01, 'CONNECT command');
    eq(srv.connectReq[3], 0x03, 'ATYP domain for socks5h');
    eq(srv.requestedHost, 'example.com', 'domain sent remotely');
    eq(srv.requestedPort, 443, 'port encoded');
    ok(srv.sawResolveRemotely, 'socks5h resolves remotely');

    final got = await drain(t);
    eq(got, 'HELLO-FROM-TARGET|SECOND', 'replay + stream both received');
    t.close();
    await srv.stop();
  }

  // ---------- 2. 本地解析（socks5）----------
  {
    final srv = FakeSocks5();
    await srv.start();
    final proxy = parseProxyLine('socks5://127.0.0.1:${srv.port}')!;
    // 直接给 IP，避免依赖真实 DNS。
    final t = await SocksTunnel.open(proxy, '93.184.216.34', 80);
    eq(srv.connectReq[3], 0x01, 'ATYP IPv4 for plain IP');
    eq(srv.requestedHost, '93.184.216.34', 'ipv4 host');
    eq(srv.requestedPort, 80, 'port 80');
    await drain(t, maxMs: 300);
    t.close();
    await srv.stop();
  }

  // ---------- 3. 认证成功 ----------
  {
    final srv = FakeSocks5(requireAuth: true, goodUser: 'alice', goodPass: 's3cret');
    await srv.start();
    final proxy = parseProxyLine('socks5://alice:s3cret@127.0.0.1:${srv.port}')!;
    final t = await SocksTunnel.open(proxy, '1.2.3.4', 8080);
    eq(srv.authBytes[0], 0x01, 'auth version');
    eq(srv.authBytes[1], 5, 'user len');
    eq(utf8.decode(srv.authBytes.sublist(2, 7)), 'alice', 'user sent');
    eq(srv.authBytes[7], 6, 'pass len');
    eq(utf8.decode(srv.authBytes.sublist(8, 14)), 's3cret', 'pass sent');
    final got = await drain(t, maxMs: 400);
    ok(got.startsWith('HELLO'), 'authed tunnel works');
    t.close();
    await srv.stop();
  }

  // ---------- 4. 认证失败 ----------
  {
    final srv = FakeSocks5(requireAuth: true, goodUser: 'alice', goodPass: 'right');
    await srv.start();
    final proxy = parseProxyLine('socks5://alice:wrong@127.0.0.1:${srv.port}')!;
    try {
      await SocksTunnel.open(proxy, '1.2.3.4', 80);
      ok(false, 'bad auth should throw');
    } on SocksException catch (e) {
      ok(e.message.contains('密码') || e.message.contains('账号'), 'bad auth message');
    }
    await srv.stop();
  }

  // ---------- 5. 代理拒绝 CONNECT ----------
  {
    final srv = FakeSocks5(replyCode: 0x05); // connection refused
    await srv.start();
    final proxy = parseProxyLine('socks5://127.0.0.1:${srv.port}')!;
    try {
      await SocksTunnel.open(proxy, '1.2.3.4', 80);
      ok(false, 'rep 0x05 should throw');
    } on SocksException catch (e) {
      eq(e.replyCode, 0x05, 'reply code captured');
      ok(e.message.contains('拒绝'), 'refused message');
    }
    await srv.stop();
  }

  // ---------- 6. BND.ADDR 是 IPv6 ----------
  {
    final srv = FakeSocks5(bndAtyp: 0x04);
    await srv.start();
    final proxy = parseProxyLine('socks5://127.0.0.1:${srv.port}')!;
    final t = await SocksTunnel.open(proxy, '1.2.3.4', 80);
    final got = await drain(t, maxMs: 400);
    ok(got.startsWith('HELLO'), 'ipv6 bnd addr parsed, stream intact');
    t.close();
    await srv.stop();
  }

  // ---------- 7. 连不上代理 ----------
  {
    final proxy = parseProxyLine('socks5://127.0.0.1:1')!;
    try {
      await SocksTunnel.open(
        proxy,
        '1.2.3.4',
        80,
        timeout: const Duration(milliseconds: 700),
      );
      ok(false, 'unreachable proxy should throw');
    } catch (e) {
      ok(e is SocketException || e is SocksException, 'unreachable throws');
    }
  }

  // ---------- 8. 地址编码 ----------
  {
    final v4 = await encodeSocksAddress('8.8.8.8', resolveRemotely: true);
    eq(v4[0], 0x01, 'v4 atyp');
    eq(v4.sublist(1).join('.'), '8.8.8.8', 'v4 bytes');

    final v6 = await encodeSocksAddress('::1', resolveRemotely: true);
    eq(v6[0], 0x04, 'v6 atyp');
    eq(v6.length, 17, 'v6 length');

    final dom = await encodeSocksAddress('a.b', resolveRemotely: true);
    eq(dom[0], 0x03, 'domain atyp');
    eq(dom[1], 3, 'domain len');
    eq(utf8.decode(dom.sublist(2)), 'a.b', 'domain bytes');
  }

  // ---------- 9. REP 码翻译 ----------
  {
    eq(describeSocksReply(0x00), '成功', 'rep 0 成功');
    ok(describeSocksReply(0x05).contains('拒绝'), 'rep 5 拒绝');
    ok(describeSocksReply(0x99).contains('未知'), 'rep unknown');
  }

  print('\n$pass passed, $fail failed');
}
