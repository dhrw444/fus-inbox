/// SOCKS5 客户端的对外门面：打开一条隧道、读写、关闭。
///
/// ## 为什么要自己写
///
/// 不是因为 WebView 不支持 socks —— 官方 `ProxyConfig` 的规则串语法里
/// scheme 是可以写 SOCKS 的。真正的障碍是**认证**：规则串没有 userinfo 位，
/// 而本仓内置的代理全部带账号密码，`addProxyRule` 带不出凭据；
/// 这里按 RFC1929 做用户名/密码认证。
///
/// 所以架构是「本机 HTTP 代理 → SOCKS5 隧道」：WebView 把流量发给
/// `127.0.0.1:port`（它只认这个），那个本机代理再把每条 CONNECT
/// 转成 SOCKS5 握手发到远端。这个文件负责后半段。
///
/// ## 只实现需要的部分
///
/// RFC 1928 + RFC 1929（用户名密码认证）。不做 BIND / UDP ASSOCIATE ——
/// 浏览器只要 CONNECT。
///
/// ## 文件边界
///
/// 协议对话在 `socks5_handshake.dart`，地址编码在 `socks5_address.dart`，
/// 异常和 REP 翻译在 `socks5_exception.dart`。这里只管**隧道的生命周期**：
/// 连 socket、转交握手、把 reader 切成转发模式、对外暴露读写字节。
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:fus_inbox/core/proxy/proxy_config.dart';
import 'package:fus_inbox/core/proxy/socket_reader.dart';
import 'package:fus_inbox/core/proxy/socks5_handshake.dart';

export 'package:fus_inbox/core/proxy/socks5_address.dart'
    show encodeSocksAddress;
export 'package:fus_inbox/core/proxy/socks5_exception.dart'
    show SocksException, describeSocksReply;

/// 一条已经完成 SOCKS5 握手的隧道。
///
/// 对外只暴露「读目标服务器的字节」和「写目标服务器的字节」，
/// 让上层（HTTP 桥）完全不用关心 SOCKS5 协议。
class SocksTunnel._(this._socket, this._reader, this._replay) {
  final Socket _socket;
  final SocketReader _reader;

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

    final reader = SocketReader(socket);
    try {
      await Socks5Handshake.run(socket, reader, proxy, host, port, timeout);
      // 握手完成：reader 从「按需切定长」切成「整块转发」。
      // 这一步不能是「取消订阅再重新 listen」—— Socket 是单订阅流，
      // 取消之后就再也接不回来了，隧道会看起来永远没有数据。
      final leftover = reader.takeBuffer();
      reader.forward();
      return SocksTunnel._(socket, reader, leftover);
    } catch (e) {
      await reader.close();
      socket.destroy();
      rethrow;
    }
  }

  /// 目标服务器发来的数据。握手残留会自动排在前面。
  Stream<Uint8List> get incoming {
    final replay = _replay;
    final rest = _reader.incoming;
    if (replay == null || replay.isEmpty) return rest;
    _replay = null;
    return _prepend(replay, rest);
  }

  /// 写数据给目标服务器。
  ///
  /// 对端已关时 `add` 会抛 —— 让它抛出去，由桥的 catch 变成 502。
  /// 静默吞掉的后果是客户端永远等不到响应（见 [flush]）。
  void write(List<int> data) => _socket.add(data);

  /// 把已写入的数据推出去。
  ///
  /// **不吞异常。** 旧实现 `catch (_) {}` 让这个 await 永不以失败告终，
  /// 于是「报文已交给出口」在隧道出口下不可能失败：对端已经死了的时候，
  /// 客户端既不收到 502、也等不到响应，一直挂到自己的超时。
  ///
  /// 同一个 bug 在直连出口（`SocketPipe.flush`）会正常抛 → 502，
  /// 在隧道出口却静默挂死 —— 两条出口对外行为完全不同，最难查的一种。
  /// 抛出去让桥统一处理：回过 200 的隧道只能断开，没回过的写 502。
  Future<void> flush() => _socket.flush();

  void close() {
    unawaited(_reader.close());
    _socket.destroy();
  }
}

Stream<Uint8List> _prepend(Uint8List first, Stream<Uint8List> rest) async* {
  yield first;
  yield* rest;
}
