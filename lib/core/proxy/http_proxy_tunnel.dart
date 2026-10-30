/// HTTP 代理的 CONNECT 隧道。
///
/// 为什么需要它：Windows 上没法给 WebView2 设原生代理（环境参数只在
/// 创建时读一次），所以**所有平台都必须走本地桥**。而桥原来只支持
/// SOCKS5 上游和直连 —— 用户在 Windows 上选一条 http 代理时，桥里
/// 没有对应实现，`proxy_engine` 就走「原生直通」那条分支，
/// `WindowsNativeProxy.apply` 恒返回 true，于是界面报「成功」，
/// 而 WebView 的流量从真实 IP 出去。这是最坏的一种失败：看起来成功了。
///
/// 有了这条隧道，桥就能把 http/https 代理也接上，
/// 「Windows 必须走桥」这件事才有实现基础。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fus_inbox/core/proxy/proxy_config.dart';
import 'package:fus_inbox/core/proxy/socket_reader.dart';

/// 一条已建立 CONNECT 隧道的 HTTP 代理连接。
class HttpProxyTunnel._(this._socket, this._reader, this._replay) {
  final Socket _socket;
  final SocketReader _reader;

  /// CONNECT 响应之后紧跟的残留字节。
  ///
  /// 和 SOCKS5 那边同一个理由：目标可能在响应到达的同一批数据里就开始
  /// 发内容，那段已经被读进缓冲区了，丢掉会让上层收到残缺的流。
  Uint8List? _replay;

  static Future<HttpProxyTunnel> open(
    ProxyConfig proxy,
    String host,
    int port, {
    Duration timeout = const Duration(seconds: 12),
  }) async {
    final socket = await Socket.connect(
      proxy.host,
      proxy.port,
      timeout: timeout,
    );
    socket.setOption(SocketOption.tcpNoDelay, true);

    final reader = SocketReader(socket);
    try {
      await _negotiate(socket, reader, proxy, host, port, timeout);
      final leftover = reader.takeBuffer();
      // 同 SOCKS5 那边：不能「取消订阅再重新 listen」，Socket 是单订阅流，
      // 取消之后就再也接不回来了，隧道会看起来永远没有数据。
      reader.forward();
      return HttpProxyTunnel._(socket, reader, leftover);
    } catch (e) {
      await reader.close();
      socket.destroy();
      rethrow;
    }
  }

  /// 发 CONNECT，等 2xx。
  static Future<void> _negotiate(
    Socket socket,
    SocketReader reader,
    ProxyConfig proxy,
    String host,
    int port,
    Duration timeout,
  ) async {
    final authority = '$host:$port';
    final head = StringBuffer()
      ..write('CONNECT $authority HTTP/1.1\r\n')
      ..write('Host: $authority\r\n');
    // 凭据按 RFC 7617 的 Basic，只在这条 CONNECT 上用一次，不会出现在
    // 后续任何请求里（隧道建立后我们只搬字节）。
    if (proxy.hasAuth) {
      final raw = '${proxy.username}:${proxy.password}';
      final token = base64.encode(utf8.encode(raw));
      head.write('Proxy-Authorization: Basic $token\r\n');
    }
    head.write('Proxy-Connection: keep-alive\r\n');
    head.write('User-Agent: fus-inbox\r\n');
    head.write('\r\n');

    socket.add(utf8.encode(head.toString()));
    await socket.flush();

    final response = await reader.readUntil(const [
      0x0D,
      0x0A,
      0x0D,
      0x0A,
    ], timeout: timeout);
    if (response == null) {
      throw const HttpProxyException('HTTP 代理没有返回 CONNECT 响应');
    }
    final text = utf8.decode(response, allowMalformed: true);
    final statusLine = text.split('\r\n').first.trim();
    // 期望形如 `HTTP/1.1 200 Connection established`。
    final parts = statusLine.split(' ');
    if (parts.length < 2) {
      throw HttpProxyException('CONNECT 响应无法解析：$statusLine');
    }
    final code = int.tryParse(parts[1]);
    if (code == null) {
      throw HttpProxyException('CONNECT 响应状态码无法解析：$statusLine');
    }
    if (code < 200 || code >= 300) {
      // 407 单独说清楚 —— 「代理要账号密码」和「代理坏了」是两件事，
      // 用户能做的事完全不同。
      if (code == 407) {
        throw const HttpProxyException('HTTP 代理要求认证（407），检查账号密码');
      }
      throw HttpProxyException('HTTP 代理拒绝 CONNECT：$statusLine');
    }
  }

  /// 目标发回来的字节。单订阅 —— 只能 listen 一次。
  Stream<Uint8List> get incoming {
    final replay = _replay;
    final rest = _reader.incoming;
    _replay = null;
    if (replay == null || replay.isEmpty) return rest;
    return _prepend(replay, rest);
  }

  void write(List<int> data) => _socket.add(data);

  /// 隧道模式下 flush 不能抛。
  ///
  /// 理由同 `SocksTunnel.flush`：对端已经关掉时 `flush` 会抛，
  /// 而这时候隧道已经建立了（上层已经回过 200），抛出去只会让
  /// 上层往一条已建立的隧道里写 502 明文。这里选择静默 —— 对端
  /// 真死了的话，读方向的流会正常结束，上层照样能收到关闭信号。
  Future<void> flush() async {
    try {
      await _socket.flush();
    } catch (_) {
      // 见上。
    }
  }

  void close() {
    unawaited(_reader.close());
    _socket.destroy();
  }

  static Stream<Uint8List> _prepend(
    Uint8List head,
    Stream<Uint8List> rest,
  ) async* {
    yield head;
    yield* rest;
  }
}

/// HTTP 代理握手失败。
class const HttpProxyException(this.message) implements Exception {
  final String message;

  @override
  String toString() => message;
}
