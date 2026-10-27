/// 本机 HTTP 代理 → SOCKS5 隧道。
///
/// ## 这个文件存在的唯一理由
///
/// Android WebView 的 `ProxyController.setProxyOverride` **只接受
/// HTTP / HTTPS 代理**。给它一个 `socks5://` 地址，系统会静默忽略，
/// 页面照样打开、照样直连 —— 没有报错，没有异常，只有「IP 没变」
/// 这一个看不出来的事实。
///
/// 所以整个链路是：
///
/// ```
///   WebView
///     │  HTTP CONNECT / 普通请求
///     ▼
///   127.0.0.1:<本机端口>        ← 这个文件
///     │  SOCKS5 握手
///     ▼
///   远端 SOCKS5 代理
///     │
///     ▼
///   freeussms.com
/// ```
///
/// WebView 看到的永远是「一个 HTTP 代理」，它乐意接受；实际出口
/// 由 SOCKS5 决定。这是唯一能让 WebView 走 SOCKS5 的办法。
///
/// ## 支持什么
///
/// - `CONNECT host:port` —— HTTPS 全靠这条，是主路径
/// - 绝对 URI 的明文 HTTP（`GET http://host/path HTTP/1.1`）
///
/// 不支持代理认证（本机回环，不需要）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fus_inbox/core/proxy/proxy_config.dart';
import 'package:fus_inbox/core/proxy/socks5_client.dart';

/// 一条正在运行的桥。
class LocalProxyBridge {
  LocalProxyBridge._(this._server, this.proxy);

  final ServerSocket _server;

  /// 出口代理。换代理就是关掉重建，不在这里改。
  final ProxyConfig proxy;

  int get port => _server.port;

  /// WebView 要用的代理地址。
  ///
  /// 注意：只能写 `127.0.0.1`，不能写 `localhost` —— WebView 的
  /// proxy override 不做域名解析，写 localhost 会被当成一个
  /// 需要经代理解析的主机名，直接失败。
  String get webViewProxy => '127.0.0.1:$port';

  static Future<LocalProxyBridge> start(ProxyConfig proxy) async {
    // 绑回环即可。绑 0.0.0.0 会让同一 WiFi 下的其他设备也能用，
    // 那是个不该开的口子。
    final server = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
      shared: false,
    );
    final bridge = LocalProxyBridge._(server, proxy);
    server.listen(bridge._handle, onError: (Object _) {});
    return bridge;
  }

  Future<void> stop() async {
    await _server.close();
  }

  Future<void> _handle(Socket client) async {
    client.setOption(SocketOption.tcpNoDelay, true);
    final head = _ClientReader(client);
    SocksTunnel? tunnel;
    StreamSubscription<Uint8List>? down;

    try {
      final requestLine = await head.readHeaderBlock();
      if (requestLine == null) return;

      final lines = const LineSplitter().convert(requestLine);
      if (lines.isEmpty) return;
      final parts = lines.first.split(' ');
      if (parts.length < 3) return;

      final method = parts[0].toUpperCase();
      final target = parts[1];
      final version = parts[2];

      if (method == 'CONNECT') {
        // CONNECT host:port —— HTTPS 走这条
        final hostPort = _splitHostPort(target);
        if (hostPort == null) {
          await _sendStatus(client, version, 400, 'Bad CONNECT target');
          return;
        }
        tunnel = await SocksTunnel.open(proxy, hostPort.$1, hostPort.$2);

        // Socket.write 返回 void，不能 await —— 写完单独 flush。
        client.write(
          '$version 200 Connection Established\r\n'
          'Proxy-Agent: fus-bridge\r\n\r\n',
        );
        await client.flush();
      } else {
        // 绝对 URI 的明文 HTTP。把 URI 拆成 host:port + path，
        // 然后当成一次普通的源服务器请求发给它。
        final uri = Uri.tryParse(target);
        if (uri == null || uri.host.isEmpty) {
          await _sendStatus(client, version, 400, 'Bad request target');
          return;
        }
        final host = uri.host;
        final port = uri.hasPort ? uri.port : (uri.scheme == 'https' ? 443 : 80);
        tunnel = await SocksTunnel.open(proxy, host, port);

        // 重写请求行：绝对 URI → 路径。源服务器不认绝对 URI。
        final path = uri.hasQuery ? '${uri.path}?${uri.query}' : uri.path;
        final rest = lines.length > 1 ? lines.sublist(1) : const <String>[];
        final rebuilt = StringBuffer()
          ..write('${parts[0]} ${path.isEmpty ? '/' : path} $version\r\n');
        for (final line in rest) {
          // 逐跳头必须删掉：代理链路自己会用，转发给源服务器
          // 会让它困惑（尤其 Connection: close）。
          final lower = line.toLowerCase();
          if (lower.startsWith('proxy-connection:') ||
              lower.startsWith('proxy-authorization:')) {
            continue;
          }
          rebuilt.write('$line\r\n');
        }
        rebuilt.write('\r\n');
        tunnel.write(utf8.encode(rebuilt.toString()));
        await tunnel.flush();
      }

      // 双向对接。客户端剩下的字节（POST body 之类）先送过去。
      final pending = head.takeBuffer();
      if (pending.isNotEmpty) {
        tunnel.write(pending);
        await tunnel.flush();
      }

      final t = tunnel;
      // 客户端 → 隧道
      //
      // 不能再 `client.listen(...)` —— Socket 是单订阅流，_ClientReader
      // 已经订阅了，第二次 listen 直接抛「Stream has already been
      // listened to」。改成让 reader 自己切到转发模式。
      head.forwardTo(
        (chunk) {
          try {
            t.write(chunk);
          } catch (_) {
            t.close();
            client.destroy();
          }
        },
        onDone: () => t.close(),
      );

      // 隧道 → 客户端
      down = t.incoming.listen(
        (chunk) {
          try {
            client.add(chunk);
          } catch (_) {
            client.destroy();
          }
        },
        onError: (Object _) => client.destroy(),
        onDone: () => client.destroy(),
        cancelOnError: true,
      );
    } catch (e) {
      // 失败要把话说清楚：500 比「连接被重置」有用得多。
      try {
        await _sendStatus(
          client,
          'HTTP/1.1',
          502,
          'Upstream proxy failed: $e',
        );
      } catch (_) {}
      client.destroy();
    } finally {
      // 不在 finally 里主动关 tunnel —— 上面两条 listen 的 onDone
      // 会各自收尾。这里只在完全没建起来时兜一下。
      if (tunnel == null) {
        await down?.cancel();
      }
    }
  }

  Future<void> _sendStatus(
    Socket client,
    String version,
    int code,
    String message,
  ) async {
    final body = utf8.encode(message);
    final head = StringBuffer()
      ..write('${version.startsWith('HTTP') ? version : 'HTTP/1.1'} $code X\r\n')
      ..write('Content-Type: text/plain; charset=utf-8\r\n')
      ..write('Content-Length: ${body.length}\r\n')
      ..write('Connection: close\r\n\r\n');
    client
      ..add(utf8.encode(head.toString()))
      ..add(body);
    await client.flush();
  }

  /// `host:port` / `[v6]:port` → (host, port)。
  static (String, int)? _splitHostPort(String s) {
    if (s.startsWith('[')) {
      final close = s.indexOf(']');
      if (close < 0) return null;
      final host = s.substring(1, close);
      final rest = s.substring(close + 1);
      if (!rest.startsWith(':')) return null;
      final port = int.tryParse(rest.substring(1));
      return port == null ? null : (host, port);
    }
    final colon = s.lastIndexOf(':');
    if (colon <= 0) return null;
    final host = s.substring(0, colon);
    final port = int.tryParse(s.substring(colon + 1));
    if (port == null) return null;
    return (host, port);
  }
}

/// 读到 `\r\n\r\n` 为止，之后转为整块转发。
///
/// 和 socks5_client 里的 `_SocketReader` 是同一个模式，理由也一样：
/// Socket 只能 listen 一次，握手/读头阶段要「读定长」，之后就变成
/// 「原样转发」，两件事必须共用同一个订阅。
class _ClientReader {
  _ClientReader(Socket socket) {
    _sub = socket.listen(
      (chunk) {
        if (_sink != null) {
          _sink!(chunk);
          return;
        }
        _buffer.addAll(chunk);
        _pump();
      },
      onError: (Object _) {},
      onDone: () {
        if (!_done.isCompleted) _done.complete(null);
        _onDone?.call();
      },
      cancelOnError: false,
    );
  }

  late final StreamSubscription<Uint8List> _sub;
  final List<int> _buffer = [];
  final Completer<String?> _done = Completer<String?>();
  void Function(Uint8List)? _sink;
  void Function()? _onDone;

  void _pump() {
    if (_done.isCompleted) return;
    final end = _findHeaderEnd();
    if (end < 0) return;
    final head = utf8.decode(_buffer.sublist(0, end), allowMalformed: true);
    _buffer.removeRange(0, end + 4);
    _done.complete(head);
  }

  int _findHeaderEnd() {
    for (var i = 0; i + 3 < _buffer.length; i++) {
      if (_buffer[i] == 13 &&
          _buffer[i + 1] == 10 &&
          _buffer[i + 2] == 13 &&
          _buffer[i + 3] == 10) {
        return i;
      }
    }
    return -1;
  }

  Future<String?> readHeaderBlock() => _done.future.timeout(
    const Duration(seconds: 20),
    onTimeout: () => null,
  );

  /// 取走读头之后残留的 body 字节。
  Uint8List takeBuffer() {
    final out = Uint8List.fromList(_buffer);
    _buffer.clear();
    return out;
  }

  /// 切到转发模式：之后来的字节直接交给 [sink]。
  void forwardTo(void Function(Uint8List) sink, {void Function()? onDone}) {
    _sink = sink;
    _onDone = onDone;
    // 转发开始前已经缓冲的字节要先送出去，否则就丢了。
    if (_buffer.isNotEmpty) {
      final pending = Uint8List.fromList(_buffer);
      _buffer.clear();
      sink(pending);
    }
  }
}
