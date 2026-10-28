/// 当前代理的生效状态，以及给 `dart:io` 的出口指令。
///
/// 这两样都是**纯值 / 纯推导**：[ActiveProxy] 只有字段，
/// [nativeEgressDirective] 只吃一个 [ActiveProxy] 吐一个字符串。引擎类里
/// 则全是带副作用的操作（起桥、调原生通道、写 `_active`）。分开后，号码
/// 目录的泄漏测试（`tool/findproxy_failclosed_test.dart` 那条链路）和 UI
/// 显示都能只拿值对象说话，不用为了一句指令把整个引擎拉起来。
library;

import 'package:fus_inbox/core/proxy/proxy_config.dart';

/// 当前代理的实际生效状态。
///
/// 四样东西缺一不可：`config` 说走哪条出口、`bridgePort` 说 Dart 侧该指向
/// 哪个本地端口、`ok` 说这次到底成没成、`detail` 是给人看的一句话。
class const ActiveProxy({
  required this.config,
  required this.bridgePort,
  required this.ok,
  required this.detail,
}) {
  final ProxyConfig config;

  /// 本地桥监听的端口。0 表示没起桥（直连或 HTTP 代理直通）。
  final int bridgePort;

  /// 是否真的生效了。
  final bool ok;

  /// 给人看的一句话（中文，能照着做）。
  final String detail;
}

/// 给 `dart:io` 的 `HttpClient.findProxy` 用的出口指令。
///
/// `ProxyController`（原生）只管 WebView 的网络栈。号码目录、收录时间这些
/// 走 `dart:io HttpClient` 的请求由 Dart VM 直接发 socket，**完全绕过代理**
/// —— 而且没有任何报错，只有「IP 没变」这一个事实。实测：不挂 `findProxy`
/// 时请求能正常拿到响应，SOCKS5 侧的连接数始终是 0。泄漏是静默的。
///
/// 返回值只有三种：
///
/// - `DIRECT`：当前确实配的就是直连
/// - `PROXY host:port`：走本地桥（SOCKS5）或直通 HTTP 代理
/// - `null`：**当前没有可用出口**。调用方必须让请求失败，绝不能退化成
///   直连 —— 见 `NumbersRepository` 的 `_findProxy`。
///
/// 注意 `findProxy` 只认 `DIRECT` / `PROXY host:port` 两种写法，
/// **不支持 SOCKS5**（Dart SDK 的硬限制）。这就是必须经过本地桥的原因：
/// 桥把 HTTP 代理协议翻译成 SOCKS5。
String? nativeEgressDirective(ActiveProxy? active) {
  if (active == null) return null;
  final config = active.config;
  if (config.isDirectProxy) return 'DIRECT';
  // SOCKS5：桥已经起来了，Dart 侧指向它，出口由桥的上游决定。
  if (active.bridgePort != 0) return 'PROXY 127.0.0.1:${active.bridgePort}';
  // HTTP/HTTPS 代理：WebView 直通，Dart 也直通同一个地址。
  return 'PROXY ${config.host}:${config.port}';
}
