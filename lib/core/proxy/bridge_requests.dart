/// 桥收到的请求：解析请求行、拆 CONNECT 目标、重写绝对 URI、回状态行。
///
/// 这些是**报文的形状**：一行字节进来，出去的是「方法 + 目标 + 版本」、
/// 「重写完的请求头」或「一条错误响应」。它们不知道桥的存在、不碰 socket
/// 生命周期，输入输出都是纯数据。所以和桥本体（`local_http_bridge.dart`
/// 的连接泵、上游切换）分开：改报文规则不用读转发逻辑，反之亦然。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// 请求头的结束标记。读头阶段一直读到它出现为止。
const crlfCrlf = <int>[13, 10, 13, 10];

/// 桥收到的一条请求行（`METHOD target HTTP/x.y`）。
class const BridgeRequest(this.method, this.target, this.version) {
  /// 大写后的方法。`CONNECT` / `GET` / `POST` …
  final String method;

  /// 原样取自请求行第二段：CONNECT 下是 `host:port`，
  /// 明文 HTTP 下是绝对 URI。
  final String target;

  /// 形如 `HTTP/1.1`。回状态行时原样带回去。
  final String version;

  /// 从请求头第一行解析。段数不足 3 或首行为空返回 null ——
  /// 这里只认形状，不做语义（方法认不认识、目标能不能拆，由调用方管）。
  static BridgeRequest? parse(String headerText) {
    final lines = const LineSplitter().convert(headerText);
    if (lines.isEmpty) return null;
    final parts = lines.first.split(' ');
    if (parts.length < 3) return null;
    return BridgeRequest(parts[0].toUpperCase(), parts[1], parts[2]);
  }

  /// CONNECT 目标 `host:port` / `[v6]:port` → (host, port)。
  ///
  /// CONNECT 不允许只给 host（没端口没法连），拆不出来或端口越界都是坏请求。
  static (String, int)? splitConnectTarget(String s) {
    if (s.startsWith('[')) {
      final close = s.indexOf(']');
      if (close < 0) return null;
      final host = s.substring(1, close);
      final rest = s.substring(close + 1);
      if (!rest.startsWith(':')) return null;
      final port = _parsePort(rest.substring(1));
      return port == null ? null : (host, port);
    }
    final colon = s.lastIndexOf(':');
    if (colon <= 0) return null;
    final port = _parsePort(s.substring(colon + 1));
    if (port == null) return null;
    return (s.substring(0, colon), port);
  }

  /// 绝对 URI（`GET http://host/path`）拆出出口：(host, port, 重写后的请求头)。
  ///
  /// 返回 null = 目标不是能用的绝对 URI。三件事都在这里：
  ///
  /// - 拆 host/port（端口省略按 scheme 补默认）；
  /// - 请求行从绝对 URI 重写成路径 —— 源服务器不认绝对 URI；
  /// - 删掉 `Proxy-Connection` / `Proxy-Authorization` —— 这两个是**本跳**
  ///   的头，只有代理读，转给源服务器会让它困惑。
  ///
  /// 反过来，`Connection` / `Host` 一律原样保留：它们对源服务器有意义，
  /// 删了就是改了客户端的意图。
  ///
  /// 连上出口、把剩余字节（POST body 之类）接在后面，这些是**传输**的事，
  /// 不在这里。
  static (String, int, Uint8List)? buildForwardRequest(
    BridgeRequest req,
    String headerText,
  ) {
    final uri = Uri.tryParse(req.target);
    if (uri == null || uri.host.isEmpty) return null;
    final port = uri.hasPort ? uri.port : (uri.scheme == 'https' ? 443 : 80);
    if (!_portInRange(port)) return null;

    final path = uri.hasQuery ? '${uri.path}?${uri.query}' : uri.path;
    final lines = const LineSplitter().convert(headerText);
    final rest = lines.length > 1 ? lines.sublist(1) : const <String>[];
    final rebuilt = StringBuffer()
      ..write('${req.method} ${path.isEmpty ? '/' : path} ${req.version}\r\n');
    for (final line in rest) {
      // 空行会提前把头部终结掉，绝不能让客户端塞进正文里的空行进报文。
      if (line.isEmpty) continue;
      final lower = line.toLowerCase();
      if (lower.startsWith('proxy-connection:') ||
          lower.startsWith('proxy-authorization:')) {
        continue;
      }
      rebuilt.write('$line\r\n');
    }
    rebuilt.write('\r\n');
    return (uri.host, port, utf8.encode(rebuilt.toString()));
  }
}

int? _parsePort(String s) {
  final p = int.tryParse(s);
  return (p != null && _portInRange(p)) ? p : null;
}

bool _portInRange(int p) => p > 0 && p <= 65535;

/// 给客户端回一条**带说明的**状态行。
///
/// 失败要说清楚：502 比「连接被重置」有用得多。
/// [version] 不是 `HTTP` 开头时（坏请求行）按 HTTP/1.1 回。
///
/// ## reason phrase 不能省
///
/// 状态行是 `HTTP/1.1 <码> <短语>`，三段都要有。以前这里第三段写的是
/// 一个字面量 `X` —— `HTTP/1.1 502 X`。虽然 RFC 7230 之后客户端**不
/// 应当**解析短语（只看码），但把它写成 X 等于在报文里留了个占位符：
/// 抓包、日志、以及那些确实会读短语的老客户端看到的都是坏数据。
///
/// 按码查表给短语；表里没有的码回 `Error` —— 仍然是个合法短语，
/// 只是不如具体的准确。
Future<void> sendHttpStatus(
  Socket client,
  String version,
  int code,
  String message,
) async {
  final body = utf8.encode(message);
  final head = StringBuffer()
    ..write(
      '${version.startsWith('HTTP') ? version : 'HTTP/1.1'} '
      '$code ${_reasonPhrase(code)}\r\n',
    )
    ..write('Content-Type: text/plain; charset=utf-8\r\n')
    ..write('Content-Length: ${body.length}\r\n')
    // 这个桥每条连接只用一次：回完状态就关，不 keep-alive。
    ..write('Connection: close\r\n\r\n');
  client
    ..add(utf8.encode(head.toString()))
    ..add(body);
  await client.flush();
}

/// 这个桥自己会回的状态码对应的标准短语。
///
/// 只列用得到的：400（请求行/目标拆不出来）、502（上游代理连不上或
/// 握手失败）。加新码时在这里补一行，别让它落到兜底上。
String _reasonPhrase(int code) => switch (code) {
  400 => 'Bad Request',
  502 => 'Bad Gateway',
  _ => 'Error',
};
