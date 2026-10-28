/// 桥的字节通道抽象：一条到目标的双向管道，两种实现。
///
/// 和桥本体（`local_http_bridge.dart`）分开，是因为两者职责不同：那边是
/// **协议**（CONNECT 怎么处理、上游怎么热切换），这边是**字节搬运**
/// （裸 socket 长什么样、SOCKS5 隧道长什么样）。搬运这层没有代理知识，
/// 也不该有。
///
/// 桥不关心通道是裸 socket 还是 SOCKS5 隧道 —— 有了这层，双向转发那段
/// 只写一遍。
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:fus_inbox/core/proxy/socks5_client.dart';

/// 一条到目标的双向字节通道。
///
/// [close] 之后不能再 [write] / [flush]。
abstract interface class BridgePipe() {
  /// 目标发回来的字节。单订阅 —— 只能 listen 一次。
  Stream<Uint8List> get incoming;

  void write(List<int> data);

  /// `Socket.write` 是同步的，真要落地得单独 flush。
  Future<void> flush();

  void close();
}

/// 直连：一条裸 TCP socket。
final class const SocketPipe(this._s) implements BridgePipe {
  final Socket _s;

  @override
  Stream<Uint8List> get incoming => _s;

  @override
  void write(List<int> data) => _s.add(data);

  @override
  Future<void> flush() => _s.flush();

  /// 用 destroy 而不是 close：`close()` 会等对端读完再 FIN，遇到半开
  /// 连接就一直挂着；这里要的是立刻释放 fd。
  @override
  void close() => _s.destroy();
}

/// 走代理：一条已握手完成的 SOCKS5 隧道。
final class const TunnelPipe(this._t) implements BridgePipe {
  final SocksTunnel _t;

  @override
  Stream<Uint8List> get incoming => _t.incoming;

  @override
  void write(List<int> data) => _t.write(data);

  @override
  Future<void> flush() => _t.flush();

  @override
  void close() => _t.close();
}
