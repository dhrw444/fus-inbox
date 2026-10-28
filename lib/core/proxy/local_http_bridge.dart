/// 本机 HTTP 代理 → SOCKS5 隧道：常驻监听，上游可热切换。
///
/// ## 这个文件存在的理由
///
/// **旧注释是错的**，而「要不要动这个文件」的判断恰恰依赖它。旧注释说
/// 「`ProxyController.setProxyOverride` 只接受 HTTP / HTTPS，给它
/// `socks5://` 会被静默忽略」。查官方 `ProxyConfig` 的规则串语法，写的是
/// `[scheme://]host[:port]`，scheme 可以是 HTTP / HTTPS / **SOCKS**
/// （SOCKS 默认端口 1080）。「WebView 用不了 SOCKS」这个前提站不住。
///
/// 桥真正站得住的理由只有一条：**规则串语法里没有 userinfo 位。**
/// 本仓内置的 589 条代理**全部带账号密码**，`addProxyRule` 没办法把凭据
/// 带出去；而 `SocksTunnel` 是按 RFC 1929 做用户名/密码认证的，能认。
/// 所以「SOCKS5 + 认证」这条必须过桥。
///
/// 唯一没亲手验证的是 WebView 的**运行时**行为（本机没有 Android）。
/// 所以：**别**因为「WebView 不支持 socks5」这句话去删这个文件 —— 那句是
/// 错的；真要动它，先按上面前提重新验一遍。
///
/// 早先这里还写着「代理挂了会静默回退直连，那是 `ProxyControllerBridge.kt`
/// 里 `.addDirect()` 的锅」：那份手写的 Kotlin 桥**整个文件都已经删掉**，
/// 原生代理现在走 `flutter_inappwebview` 自带的 `ProxyController`
/// （见 `native_proxy.dart`）。那条备注只留作历史，与桥无关。
///
/// 链路：
///
/// ```
///   WebView
///     │  HTTP CONNECT / 绝对 URI 的明文请求
///     ▼
///   127.0.0.1:<本机端口>        ← 这个文件
///     │  SOCKS5 握手（含 RFC 1929 用户名/密码）
///     ▼
///   远端 SOCKS5 代理
///     │
///     ▼
///   freeussms.com
/// ```
///
/// WebView 看到的永远是「一个 HTTP 代理」，它乐意接受；实际出口由
/// SOCKS5 决定。
///
/// ## 支持什么
///
/// - `CONNECT host:port` —— HTTPS 全靠这条，是主路径
/// - 绝对 URI 的明文 HTTP（`GET http://host/path HTTP/1.1`）
///
/// 不支持代理认证：监听在回环上，不需要。
///
/// ## 文件边界
///
/// 报文怎么解析、怎么重写、状态行怎么回，在 `bridge_requests.dart`；
/// 字节通道抽象在 `bridge_io.dart`。这里只管**连接的生命周期**：
/// 接客户端、按当前出口连上游、双向泵字节、换上游、关桥。
library;

import 'dart:convert';
import 'dart:io';

import 'package:fus_inbox/core/proxy/bridge_io.dart';
import 'package:fus_inbox/core/proxy/bridge_requests.dart';
import 'package:fus_inbox/core/proxy/proxy_config.dart';
import 'package:fus_inbox/core/proxy/socket_reader.dart';
import 'package:fus_inbox/core/proxy/socks5_client.dart';

export 'package:fus_inbox/core/proxy/bridge_io.dart'
    show BridgePipe, SocketPipe, TunnelPipe;

class LocalProxyBridge._(this._server, this._upstream) {
  final ServerSocket _server;

  /// 当前出口。`null` = 直连。
  ///
  /// **可空是有意的，不是「还没设」**：Windows 上 WebView2 从进程启动就
  /// 一直指向这条桥，用户完全可能一条代理都不配 —— 那时桥必须自己直连
  /// 出去，而不是拒绝服务。换句话说，这条桥的语义是「按当前出口转发」，
  /// 而不是「一条 SOCKS5 隧道」。
  ProxyConfig? _upstream;

  /// 出口变了多少次。只用于测试和排查。
  int get upstreamSwitches => _switches;
  int _switches = 0;

  ProxyConfig? get upstream => _upstream;

  int get port => _server.port;

  /// 起一条桥。
  ///
  /// [port] 为 0 时由系统分配（Android 用得上，因为端口不用提前知道）。
  /// Windows 必须传一个固定端口 —— WebView2 的代理设置是进程级的，
  /// 端口一变就得重建。
  /// 端口被占用会抛，调用方自己决定退到哪个端口。
  static Future<LocalProxyBridge> start({
    ProxyConfig? upstream,
    int port = 0,
  }) async {
    // 只绑回环。绑 0.0.0.0 会让同一 WiFi 下的其他设备也能借道出去，
    // 那是个不该开的口子。
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
    final bridge = LocalProxyBridge._(server, upstream);
    // 单个 accept 失败（客户端连上就断之类）不该把整个监听关掉。
    server.listen(bridge._handle, onError: (Object _) {});
    return bridge;
  }

  /// 换出口。只影响**之后建立**的连接；已经在传的隧道不动
  /// （中途换掉会把正在收的短信截断）。
  ///
  /// `null` = 直连。同一条代理（id 相同）重复设不算切换，不累加计数。
  void setUpstream(ProxyConfig? next) {
    if (identical(next, _upstream) || next?.id == _upstream?.id) return;
    _upstream = next;
    _switches++;
  }

  /// 按当前出口连到 `host:port`。
  ///
  /// 每次连接都现读一次 [_upstream]（不是启动时抓的快照）——
  /// 换号是热切换，抓快照就等于永远停在第一条出口上。
  Future<BridgePipe> _connect(String host, int port) async {
    final up = _upstream;
    if (up == null || up.isDirectProxy) {
      // 直连也要超时：DNS 卡住或对端黑洞时，不设超时就是永久占一条
      // 客户端连接 + 一个 fd。
      return SocketPipe(
        await Socket.connect(host, port, timeout: _connectTimeout),
      );
    }
    return TunnelPipe(await SocksTunnel.open(up, host, port));
  }

  Future<void> stop() async {
    await _server.close();
  }

  Future<void> _handle(Socket client) async {
    client.setOption(SocketOption.tcpNoDelay, true);
    final head = SocketReader(client);
    BridgePipe? pipe;

    try {
      final raw = await head.readUntil(crlfCrlf, timeout: _headTimeout);
      if (raw == null) {
        // 读头超时，或者对端灌了超长垃圾（`readUntil` 有 64KB 上限）。
        //
        // 必须显式收掉这条连接，不能直接 `return`：那样 reader 的订阅还
        // 挂着，客户端之后发什么都进缓冲没人消费 —— fd 不释放、内存无上限涨。
        //
        // 实测：5 个「连上就不发请求」的客户端，21 秒后 fd 仍是 +10；
        // 客户端断开后服务端那 5 个进 CLOSE_WAIT，再没人关。
        await head.close();
        client.destroy();
        return;
      }
      final headerText = utf8.decode(raw, allowMalformed: true);
      final request = BridgeRequest.parse(headerText);
      if (request == null) {
        await sendHttpStatus(client, 'HTTP/1.1', 400, '无法解析的请求行');
        await head.close();
        client.destroy();
        return;
      }

      if (request.method == 'CONNECT') {
        final hostPort = BridgeRequest.splitConnectTarget(request.target);
        if (hostPort == null) {
          await sendHttpStatus(
            client,
            request.version,
            400,
            'CONNECT 目标不是 host:port',
          );
          await head.close();
          client.destroy();
          return;
        }
        pipe = await _connect(hostPort.$1, hostPort.$2);

        // `Socket.write` 返回 void，不能 await —— 写完单独 flush。
        client.write(
          '${request.version} 200 Connection Established\r\n'
          'Proxy-Agent: fus-bridge\r\n\r\n',
        );
        await client.flush();
      } else {
        // 绝对 URI 的明文 HTTP：拆出口 + 重写报文都在那边做，
        // 这里只管连上、把重写完的报文发出去。
        final fwd = BridgeRequest.buildForwardRequest(request, headerText);
        if (fwd == null) {
          await sendHttpStatus(client, request.version, 400, '目标不是可用的绝对 URI');
          await head.close();
          client.destroy();
          return;
        }
        pipe = await _connect(fwd.$1, fwd.$2);
        pipe.write(fwd.$3);
        await pipe.flush();
      }

      await _pump(client, head, pipe);
    } catch (e) {
      // 失败要把话说清楚：502 比「连接被重置」有用得多。
      try {
        await sendHttpStatus(client, 'HTTP/1.1', 502, '上游代理连接失败：$e');
      } catch (_) {
        // 连「告诉你 502」都失败了 —— 客户端已经断了。没有补救动作，
        // 下面照样 destroy，不留这条连接。
      }
      // 走到这里说明 _pump 没接手，pipe 要么没建起来、要么建起来就废了。
      pipe?.close();
      client.destroy();
    } finally {
      // _pump 成功时它自己会收尾（两条 listen 的 onDone），这里只兜
      // 「压根没进泵」的情况：读者还握着 socket 订阅，必须放掉。
      if (pipe == null) await head.close();
    }
  }

  /// 双向对接。客户端剩下的字节（POST body 之类）先送过去。
  ///
  /// 客户端 → 隧道这段**不能**再 `client.listen(...)` —— Socket 是单订阅
  /// 流，SocketReader 已经订阅了，第二次 listen 直接抛「Stream has already
  /// been listened to」。改成让 reader 自己切到转发模式。
  static Future<void> _pump(
    Socket client,
    SocketReader head,
    BridgePipe t,
  ) async {
    final pending = head.takeBuffer();
    if (pending.isNotEmpty) {
      t.write(pending);
      await t.flush();
    }

    head.forward();
    head.incoming.listen(
      (chunk) {
        try {
          t.write(chunk);
        } catch (_) {
          // 隧道已经关了（对端先断），继续写只会一直抛。
          _shutdown(t, client);
        }
      },
      onError: (Object _) => _shutdown(t, client),
      onDone: () => _shutdown(t, client),
    );

    // 隧道 → 客户端
    t.incoming.listen(
      (chunk) {
        try {
          client.add(chunk);
        } catch (_) {
          // 客户端已经断了，把隧道也收掉，别留半条。
          _shutdown(t, client);
        }
      },
      onError: (Object _) => _shutdown(t, client),
      onDone: () => _shutdown(t, client),
      cancelOnError: true,
    );
  }

  /// 一边断了就把两边都收掉。半开的隧道没有任何用处，只会占 fd。
  static void _shutdown(BridgePipe t, Socket client) {
    t.close();
    client.destroy();
  }

  /// 读请求头的上限。20 秒足够慢网络发完一行请求头，再久就是对面不说话。
  static const _headTimeout = Duration(seconds: 20);

  /// 连上游/直连的超时。SocksTunnel 内部自己也有超时，这里管直连那条。
  static const _connectTimeout = Duration(seconds: 12);
}
