/// SOCKS5 客户端。
///
/// ## 为什么要自己写
///
/// Android WebView 的 `ProxyController` **只接受 HTTP/HTTPS 代理**，
/// 传 socks 进去系统会静默忽略 —— 页面看起来正常打开，实际走的是
/// 直连。这是最难查的一类失败：没有报错，IP 却根本没换。
///
/// 所以架构是「本机 HTTP 代理 → SOCKS5 隧道」：WebView 把流量发给
/// `127.0.0.1:port`（它只认这个），那个本机代理再把每条 CONNECT
/// 转成 SOCKS5 握手发到远端。这个文件负责后半段。
///
/// ## 只实现需要的部分
///
/// RFC 1928 + RFC 1929（用户名密码认证）。不做 BIND / UDP ASSOCIATE ——
/// 浏览器只要 CONNECT。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fus_inbox/core/proxy/proxy_config.dart';

/// SOCKS5 握手失败。
class SocksException implements Exception {
  const SocksException(this.message, {this.replyCode});

  final String message;

  /// 服务器回的 REP 字段（RFC 1928 §6）。null 表示没走到那一步。
  final int? replyCode;

  @override
  String toString() =>
      'SocksException($message${replyCode == null ? '' : ', rep=$replyCode'})';
}

/// REP 码翻译。查日志时比看数字有用。
String describeSocksReply(int code) => switch (code) {
  0x00 => '成功',
  0x01 => 'SOCKS 服务器内部错误',
  0x02 => '规则不允许该连接',
  0x03 => '网络不可达',
  0x04 => '主机不可达',
  0x05 => '连接被拒绝',
  0x06 => 'TTL 过期',
  0x07 => '不支持的命令',
  0x08 => '不支持的地址类型',
  _ => '未知错误 0x${code.toRadixString(16)}',
};

/// 一条已经完成 SOCKS5 握手的隧道。
///
/// 对外只暴露「读目标服务器的字节」和「写目标服务器的字节」，
/// 让上层（HTTP 桥）完全不用关心 SOCKS5 协议。
class SocksTunnel {
  SocksTunnel._(this._socket, this._reader, this._replay);

  final Socket _socket;
  final _SocketReader _reader;

  /// 握手响应之后紧跟的残留字节。
  ///
  /// 目标服务器有可能在 CONNECT 响应到达的同一批数据里就开始发内容
  /// （HTTP/1.0 响应、或 TLS 之前的明文协议）。这段数据已经被我们
  /// 从 socket 读进缓冲区了，丢掉会让上层收到残缺的流。
  Uint8List? _replay;

  /// 打开一条隧道。
  ///
  /// [proxy] 里 scheme 决定域名解析放在哪边：
  /// `socks5h` 交给代理（本地不泄漏域名），`socks5` 本地解析。
  static Future<SocksTunnel> open(
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

    final reader = _SocketReader(socket);
    try {
      await _handshake(socket, reader, proxy, host, port, timeout);
      // 握手完成：reader 从「按需切定长」切成「整块转发」。
      // 这一步不能是「取消订阅再重新 listen」—— Socket 是单订阅流，
      // 取消之后就再也接不回来了，隧道会看起来永远没有数据。
      final leftover = reader.handshakeDone();
      return SocksTunnel._(socket, reader, leftover);
    } catch (e) {
      await reader.stop();
      socket.destroy();
      rethrow;
    }
  }

  static Future<void> _handshake(
    Socket socket,
    _SocketReader reader,
    ProxyConfig proxy,
    String host,
    int port,
    Duration timeout,
  ) async {
    // ---- 1. 方法协商 ----
    //
    // 有凭据就同时提供 0x00（免认证）和 0x02（用户名密码）。
    // 只提供 0x02 的话，那些「配了账号但其实不校验」的代理会拒绝 ——
    // 自建代理里这种情况很常见。
    final wantAuth = proxy.hasAuth;
    final methods = wantAuth ? const [0x00, 0x02] : const [0x00];
    final greet = Uint8List(2 + methods.length)
      ..[0] = 0x05
      ..[1] = methods.length;
    for (var i = 0; i < methods.length; i++) {
      greet[2 + i] = methods[i];
    }
    socket.add(greet);
    await socket.flush();

    final vm = await reader.read(2, timeout);
    if (vm[0] != 0x05) {
      throw SocksException('代理不是 SOCKS5（版本字节 0x${vm[0].toRadixString(16)}）');
    }
    if (vm[1] == 0xFF) {
      throw const SocksException('代理不接受任何认证方式');
    }

    // ---- 2. 用户名密码认证（RFC 1929）----
    if (vm[1] == 0x02) {
      if (!wantAuth) {
        throw const SocksException('代理要求账号密码，但配置里没有');
      }
      final u = utf8.encode(proxy.username);
      final p = utf8.encode(proxy.password);
      if (u.length > 255 || p.length > 255) {
        throw const SocksException('账号或密码超过 255 字节');
      }
      final auth = Uint8List(3 + u.length + p.length)
        ..[0] = 0x01
        ..[1] = u.length;
      auth.setRange(2, 2 + u.length, u);
      auth[2 + u.length] = p.length;
      auth.setRange(3 + u.length, 3 + u.length + p.length, p);
      socket.add(auth);
      await socket.flush();

      final ar = await reader.read(2, timeout);
      if (ar[1] != 0x00) {
        throw const SocksException('账号或密码被代理拒绝');
      }
    } else if (vm[1] != 0x00) {
      throw SocksException('代理选了不支持的认证方式 0x${vm[1].toRadixString(16)}');
    }

    // ---- 3. CONNECT ----
    final addr = await encodeSocksAddress(
      host,
      resolveRemotely: proxy.scheme == ProxyScheme.socks5h,
    );
    // 长度：VER+CMD+RSV+ATYP（4）+ 地址本体（addr.length - 1）+ 端口（2）。
    // 注意 addr 是 [ATYP, ...本体]，ATYP 已经单独放在 req[3] 了，
    // 所以本体只占 addr.length - 1 字节。多算 1 会让端口整体后移一位，
    // 443 被写成 0x01 0x00 —— 服务端读到端口 256。
    final req = Uint8List(4 + (addr.length - 1) + 2)
      ..[0] = 0x05
      ..[1] =
          0x01 // CONNECT
      ..[2] =
          0x00 // RSV
      ..[3] = addr[0]; // ATYP
    req.setRange(4, 4 + (addr.length - 1), addr, 1);
    req[req.length - 2] = (port >> 8) & 0xFF;
    req[req.length - 1] = port & 0xFF;
    socket.add(req);
    await socket.flush();

    final head = await reader.read(4, timeout);
    if (head[0] != 0x05) {
      throw SocksException('CONNECT 响应版本错误 0x${head[0].toRadixString(16)}');
    }
    if (head[1] != 0x00) {
      throw SocksException(
        '代理拒绝连接：${describeSocksReply(head[1])}',
        replyCode: head[1],
      );
    }

    // 读掉 BND.ADDR + BND.PORT。不读会把它们留在流里，
    // 目标服务器发的第一段数据就错位了。
    switch (head[3]) {
      case 0x01:
        await reader.read(4 + 2, timeout);
      case 0x03:
        final l = await reader.read(1, timeout);
        await reader.read(l[0] + 2, timeout);
      case 0x04:
        await reader.read(16 + 2, timeout);
      default:
        throw SocksException('CONNECT 响应地址类型未知 0x${head[3].toRadixString(16)}');
    }
  }

  /// 目标服务器发来的数据。握手残留会自动排在前面。
  Stream<Uint8List> get incoming {
    final replay = _replay;
    final rest = _reader.stream;
    if (replay == null || replay.isEmpty) return rest;
    _replay = null;
    return _prepend(replay, rest);
  }

  /// 写数据给目标服务器。
  void write(List<int> data) => _socket.add(data);

  Future<void> flush() async {
    try {
      await _socket.flush();
    } catch (_) {
      // 连接可能已经被对端关掉了，flush 失败不该往上抛。
    }
  }

  void close() {
    _reader.stop();
    _socket.destroy();
  }
}

Stream<Uint8List> _prepend(Uint8List first, Stream<Uint8List> rest) async* {
  yield first;
  yield* rest;
}

/// 把目标地址编码成 SOCKS5 的 `ATYP + ADDR`（不含端口）。
Future<Uint8List> encodeSocksAddress(
  String host, {
  required bool resolveRemotely,
}) async {
  // 已经是 IP 就直接用，省一次解析。
  final parsed = InternetAddress.tryParse(host);
  if (parsed != null) {
    return Uint8List.fromList([
      parsed.type == InternetAddressType.IPv6 ? 0x04 : 0x01,
      ...parsed.rawAddress,
    ]);
  }

  if (resolveRemotely) {
    final bytes = utf8.encode(host);
    if (bytes.length > 255) {
      throw const SocksException('域名超过 255 字节');
    }
    return Uint8List.fromList([0x03, bytes.length, ...bytes]);
  }

  final resolved = await InternetAddress.lookup(host);
  if (resolved.isEmpty) {
    throw SocksException('本地解析不到 $host');
  }
  final addr = resolved.first;
  return Uint8List.fromList([
    addr.type == InternetAddressType.IPv6 ? 0x04 : 0x01,
    ...addr.rawAddress,
  ]);
}

/// 从 Socket 里按需精确读固定字节数，握手后转为整块转发。
///
/// 为什么要这么绕：Socket 是**单订阅流**，`listen` 只能来一次。
/// 握手阶段需要「读定长」，握手之后需要「原样转发」，两者都得用
/// 同一个订阅 —— 中途 cancel 再 listen 是不可能的。
///
/// 所以这里始终只订阅一次：握手期间数据攒进 `_buffer` 供 `read(n)` 切，
/// `handshakeDone()` 之后新数据直接进 `_out` 给上层。
class _SocketReader {
  _SocketReader(Socket socket) {
    // 控制器必须在构造体里建：它的 onPause/onResume 要引用 _sub，
    // 而字段初始化器里读不到 this。
    _out = StreamController<Uint8List>(
      sync: true,
      onPause: () => _sub.pause(),
      onResume: () => _sub.resume(),
    );
    _sub = socket.listen(
      (chunk) {
        if (_forwarding) {
          _out.add(chunk);
          return;
        }
        _buffer.addAll(chunk);
        _pump();
      },
      onError: _fail,
      onDone: _finish,
      cancelOnError: false,
    );
  }

  late final StreamSubscription<Uint8List> _sub;

  /// 转发用。`onPause` / `onResume` 映射到 socket 订阅，
  /// 让上层（HTTP 桥）能真的对 TCP 施加背压，而不是无限缓冲。
  late final StreamController<Uint8List> _out;

  final List<int> _buffer = [];
  Completer<Uint8List>? _waiting;
  int _wanted = 0;
  Object? _error;
  bool _forwarding = false;
  bool _closed = false;

  Stream<Uint8List> get stream => _out.stream;

  void _pump() {
    final w = _waiting;
    if (w == null || _buffer.length < _wanted) return;
    final out = Uint8List.fromList(_buffer.sublist(0, _wanted));
    _buffer.removeRange(0, _wanted);
    _waiting = null;
    w.complete(out);
  }

  void _fail(Object e) {
    _error = e;
    final w = _waiting;
    if (w != null && !w.isCompleted) {
      _waiting = null;
      w.completeError(e);
    }
    // 没人监听时塞 error 只会进缓冲，等 close 之后变成
    // 「未处理的异步错误」，把整个 App 的 zone 打红。
    if (!_out.isClosed && _out.hasListener) _out.addError(e);
  }

  void _finish() {
    _closed = true;
    final w = _waiting;
    if (w != null && !w.isCompleted) {
      _waiting = null;
      w.completeError(const SocksException('代理在握手途中断开'));
    }
    if (!_out.isClosed) _out.close();
  }

  Future<Uint8List> read(int n, Duration timeout) {
    if (_closed) return Future.error(const SocksException('连接已断开'));
    final err = _error;
    if (err != null) return Future.error(err);
    if (_buffer.length >= n) {
      final out = Uint8List.fromList(_buffer.sublist(0, n));
      _buffer.removeRange(0, n);
      return Future.value(out);
    }
    final c = Completer<Uint8List>();
    _waiting = c;
    _wanted = n;
    // 握手阶段超时要主动失败，否则这条连接一直挂着占 fd。
    return c.future.timeout(
      timeout,
      onTimeout: () {
        _waiting = null;
        throw const SocksException('SOCKS5 握手超时');
      },
    );
  }

  /// 握手结束：切到转发模式，返回缓冲区里还没消费的字节。
  ///
  /// 这段字节必须交出去 —— 目标服务器有可能在 CONNECT 响应的同一批
  /// 数据里就开始发内容，丢掉就是「隧道通了但第一屏是空的」。
  Uint8List handshakeDone() {
    _forwarding = true;
    final rest = Uint8List.fromList(_buffer);
    _buffer.clear();
    return rest;
  }

  Future<void> stop() async {
    _forwarding = true;
    _closed = true;
    await _sub.cancel();
    // ⚠️ 不能 `await _out.close()`。
    //
    // StreamController.close() 返回的 done future 要等**监听者把
    // 事件消费完**才完成。握手失败时上层从来没 listen 过 `_out`，
    // 这个 future 就永远不完成 —— 整个 open() 的 catch 挂死，
    // 表现为「代理连不上时 App 卡住」。实测踩过一次。
    if (!_out.isClosed) unawaited(_out.close());
  }
}
