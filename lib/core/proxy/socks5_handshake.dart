/// SOCKS5 握手：方法协商 → RFC1929 认证 → CONNECT → 清完响应尾巴。
///
/// ## 为什么单独一个文件
///
/// 握手是**纯协议对话**：给它 socket、读头器和意图，它按 RFC 1928/1929
/// 把话说完。它不持有隧道（那是 `socks5_client.dart` 的事）、不做地址
/// 编码（`socks5_address.dart`）、不管字节怎么攒（`socket_reader.dart`）。
/// 挤在隧道类里时，这三步是 `open()` 中间的一段 130 行静态方法 —— 改协议
/// 和改生命周期要翻同一个文件。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fus_inbox/core/proxy/proxy_config.dart';
import 'package:fus_inbox/core/proxy/socks5_address.dart';
import 'package:fus_inbox/core/proxy/socks5_exception.dart';
import 'package:fus_inbox/core/proxy/socket_reader.dart';

/// 按协议把一条 SOCKS5 连接握手到「可以直通字节」的状态。
///
/// 全静态方法的命名空间类。末尾 `()` 是主构造器的空标记（本仓统一写法）。
abstract final class Socks5Handshake() {
  /// 完整握手。失败抛 [SocksException]，socket 由调用方收尾。
  static Future<void> run(
    Socket socket,
    SocketReader reader,
    ProxyConfig proxy,
    String host,
    int port,
    Duration timeout,
  ) async {
    final chosen = await _negotiateMethod(socket, reader, proxy, timeout);
    if (chosen == 0x02) {
      await _authenticate(socket, reader, proxy, timeout);
    }
    await _connect(socket, reader, proxy, host, port, timeout);
  }

  /// ---- 1. 方法协商 ----
  ///
  /// 有凭据就同时提供 0x00（免认证）和 0x02（用户名密码）。
  /// 只提供 0x02 的话，那些「配了账号但其实不校验」的代理会拒绝 ——
  /// 自建代理里这种情况很常见。选中的方式原样返回（0x00 或 0x02），
  /// [run] 据此决定要不要走第二步。
  static Future<int> _negotiateMethod(
    Socket socket,
    SocketReader reader,
    ProxyConfig proxy,
    Duration timeout,
  ) async {
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

    final vm = await reader.read(2, timeout: timeout);
    if (vm[0] != 0x05) {
      throw SocksException('代理不是 SOCKS5（版本字节 0x${vm[0].toRadixString(16)}）');
    }
    if (vm[1] == 0xFF) {
      throw const SocksException('代理不接受任何认证方式');
    }
    if (vm[1] != 0x00 && vm[1] != 0x02) {
      throw SocksException('代理选了不支持的认证方式 0x${vm[1].toRadixString(16)}');
    }
    // 没给凭据时代理却点名要认证 —— 原版走到下面 auth 段才报
    // 「配置里没有」，语义一样；在这里拦只是让「方法协商失败」都
    // 归同一个入口。
    if (vm[1] == 0x02 && !wantAuth) {
      throw const SocksException('代理要求账号密码，但配置里没有');
    }
    return vm[1];
  }

  /// ---- 2. 用户名密码认证（RFC 1929）----
  static Future<void> _authenticate(
    Socket socket,
    SocketReader reader,
    ProxyConfig proxy,
    Duration timeout,
  ) async {
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

    final ar = await reader.read(2, timeout: timeout);
    // RFC 1929 的响应是 VER(0x01) + STATUS。版本字节要判 ——
    // 上面方法协商那一步判了（`vm[0] != 0x05`），这里不判就不对称：
    // 对端要是回了一段别的东西，只看 ar[1] 会把它当成「认证成功」。
    if (ar[0] != 0x01) {
      throw SocksException(
        '认证响应版本错误 0x${ar[0].toRadixString(16)}（应当 RFC 1929 的 0x01）',
      );
    }
    if (ar[1] != 0x00) {
      throw const SocksException('账号或密码被代理拒绝');
    }
  }

  /// ---- 3. CONNECT + 清完 BND.ADDR / BND.PORT ----
  ///
  /// 不读掉 BND 段会把它们留在流里，目标服务器发的第一段数据就错位了。
  static Future<void> _connect(
    Socket socket,
    SocketReader reader,
    ProxyConfig proxy,
    String host,
    int port,
    Duration timeout,
  ) async {
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

    final head = await reader.read(4, timeout: timeout);
    if (head[0] != 0x05) {
      throw SocksException('CONNECT 响应版本错误 0x${head[0].toRadixString(16)}');
    }
    if (head[1] != 0x00) {
      throw SocksException(
        '代理拒绝连接：${describeSocksReply(head[1])}',
        replyCode: head[1],
      );
    }

    switch (head[3]) {
      case 0x01:
        await reader.read(4 + 2, timeout: timeout);
      case 0x03:
        final l = await reader.read(1, timeout: timeout);
        await reader.read(l[0] + 2, timeout: timeout);
      case 0x04:
        await reader.read(16 + 2, timeout: timeout);
      default:
        throw SocksException('CONNECT 响应地址类型未知 0x${head[3].toRadixString(16)}');
    }
  }
}
