import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fus_inbox/core/proxy/proxy_config.dart';
import 'package:fus_inbox/core/proxy/socks5_client.dart';

/// 一条代理的实测结果。
class const ProxyProbeResult({
  required this.proxy,
  required this.ok,
  this.latencyMs = 0,
  this.egressIp = '',
  this.failure = '',
}) {
  /// 没测出东西就判死的快捷构造，给外面兜异常用。
  factory ProxyProbeResult.dead(ProxyConfig proxy, String reason) =>
      ProxyProbeResult(proxy: proxy, ok: false, failure: reason);

  final ProxyConfig proxy;
  final bool ok;
  final int latencyMs;

  /// 出口 IP。配额按 IP 算，所以这个字段比延迟重要得多 ——
  /// 同一个 IP 的代理再多，能看的号也只有 3 个。
  final String egressIp;
  final String failure;

  /// 链路通了但出口没读到。这种算活，只是不知道它跟谁撞 IP。
  bool get egressUnknown => ok && egressIp.isEmpty;

  String get summary {
    if (!ok) return failure;
    if (egressIp.isEmpty) return '$latencyMs ms  出口未知';
    return '$latencyMs ms  出口 $egressIp';
  }
}

/// 连通性检测。
///
/// 不是探 TCP 端口 —— 那只能证明端口开着。实测这批代理里，
/// TCP 通的有 616 条，真能走 SOCKS5 握手并连到站点的只有 589 条。
/// 所以这里做两件事：
///
/// 1. 完整 SOCKS5 握手 + 认证（RFC 1928/1929）
/// 2. 经隧道真连一次目标，证明链路是通的
///
/// 再取一次出口 IP，用来判断这条代理的 IP 是不是跟别的重复。
class ProxyProbe({this.timeout = const Duration(seconds: 10)}) {
  final Duration timeout;

  /// 用来验链路的目标。选一个轻量且稳定的 HTTPS 端点。
  static const defaultTargetHost = 'freeussms.com';
  static const defaultTargetPort = 443;

  /// 取出口 IP 的端点。纯文本回一个 IP，没有别的内容。
  ///
  /// 注意是 https 的写法，但真连的时候走 80 明文 —— 见 [_fetchEgressIp]。
  static const egressEndpoint = 'https://api.ipify.org';

  /// 测一条。
  ///
  /// [checkEgress] 默认开着 —— 出口 IP 是这套东西的核心数据：
  /// 配额按 IP 算，两条代理如果出口同一个 IP，等于一条。
  /// 代价是多开一条到 80 端口的隧道，值得。
  Future<ProxyProbeResult> probeOne(
    ProxyConfig proxy, {
    bool checkEgress = true,
  }) async {
    final started = DateTime.now();
    SocksTunnel? tunnel;
    try {
      // open() 收整个 ProxyConfig —— 账号密码、超时都从里面读。
      // open() 已经做完 SOCKS5 握手并返回可用的隧道，
      // 不需要再 connect 一次（那会多开一条连接）。
      tunnel = await SocksTunnel.open(
        proxy,
        defaultTargetHost,
        defaultTargetPort,
        timeout: timeout,
      ).timeout(timeout);

      final latency = DateTime.now().difference(started).inMilliseconds;

      if (!checkEgress) {
        return ProxyProbeResult(proxy: proxy, ok: true, latencyMs: latency);
      }

      // 出口 IP 单独一条隧道。刚才那条是 443，在它上面发明文 HTTP
      // 只会收到 TLS 握手失败 —— 这个坑踩过。
      //
      // 出口读不到不等于代理是死的：有的代理会拦掉 ipify。
      // 所以这里单独兜异常，只把 IP 留空，不动 ok。
      String ip = '';
      String note = '';
      try {
        ip = await _fetchEgressIp(proxy).timeout(timeout);
      } on Object catch (e) {
        note = _describe(e);
      }
      return ProxyProbeResult(
        proxy: proxy,
        ok: true,
        latencyMs: latency,
        egressIp: ip,
        failure: note,
      );
    } on Object catch (e) {
      return ProxyProbeResult(proxy: proxy, ok: false, failure: _describe(e));
    } finally {
      try {
        tunnel?.close();
      } on Object catch (_) {}
    }
  }

  /// 批量测。并发上限别开太大 —— 手机内存和 NAT 表都吃不消。
  ///
  /// [onProgress] 每完成一条回调一次，界面用它刷进度。
  Future<List<ProxyProbeResult>> probeAll(
    List<ProxyConfig> proxies, {
    int concurrency = 24,
    bool checkEgress = true,
    void Function(int done, int total, ProxyProbeResult last)? onProgress,
  }) async {
    final results = <ProxyProbeResult>[];
    var index = 0;
    var done = 0;

    Future<void> worker() async {
      while (true) {
        final i = index++;
        if (i >= proxies.length) return;
        final r = await probeOne(proxies[i], checkEgress: checkEgress);
        results.add(r);
        done++;
        onProgress?.call(done, proxies.length, r);
      }
    }

    await Future.wait(List.generate(concurrency.clamp(1, 64), (_) => worker()));
    return results;
  }

  Future<String> _fetchEgressIp(ProxyConfig proxy) async {
    // 明文 HTTP 走 80。用 https 端点会多一层 TLS，没必要。
    final uri = Uri.parse(egressEndpoint);
    final tunnel = await SocksTunnel.open(
      proxy,
      uri.host,
      uri.hasPort ? uri.port : 80,
      timeout: timeout,
    ).timeout(timeout);
    try {
      return await _fetchOverTunnel(tunnel);
    } finally {
      tunnel.close();
    }
  }

  Future<String> _fetchOverTunnel(SocksTunnel tunnel) async {
    final uri = Uri.parse(egressEndpoint);
    tunnel.write(
      utf8.encode(
        'GET / HTTP/1.1\r\n'
        'Host: ${uri.host}\r\n'
        'User-Agent: curl/8.0\r\n'
        'Accept: */*\r\n'
        'Connection: close\r\n\r\n',
      ),
    );

    final bytes = await _readUntilClose(tunnel);
    final text = utf8.decode(bytes, allowMalformed: true);
    final idx = text.indexOf('\r\n\r\n');
    if (idx < 0) throw const SocketException('出口检测没有响应体');
    final ip = text.substring(idx + 4).trim();
    // 只接受像 IP 的东西，防止端点换了返回 HTML 被当成 IP。
    if (!RegExp(r'^[0-9a-fA-F:.]+$').hasMatch(ip)) {
      throw SocketException(
        '出口检测返回的不是 IP: ${ip.substring(0, ip.length.clamp(0, 40))}',
      );
    }
    return ip;
  }

  Future<List<int>> _readUntilClose(SocksTunnel tunnel) async {
    final out = <int>[];
    final completer = Completer<void>();
    late final StreamSubscription<List<int>> sub;
    // 读不完就别等了 —— 有的代理不回 FIN。计时器必须自己收掉，
    // 否则每条代理留一个活 Timer，589 条就是 589 个。
    final guard = Timer(timeout, () {
      if (!completer.isCompleted) completer.complete();
    });
    sub = tunnel.incoming.listen(
      out.addAll,
      onError: (Object _) {
        if (!completer.isCompleted) completer.complete();
      },
      onDone: () {
        if (!completer.isCompleted) completer.complete();
      },
      cancelOnError: false,
    );
    try {
      await completer.future;
    } finally {
      guard.cancel();
      await sub.cancel();
    }
    return out;
  }

  static String _describe(Object e) {
    final s = e.toString();
    // 去掉 "Exception: " 之类的前缀，界面上直接给人看。
    return s.replaceFirst(RegExp(r'^\w*(Exception|Error):\s*'), '');
  }
}
