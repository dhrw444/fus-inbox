/// 把「代理池 → 本地桥 → WebView」这一串接起来。
///
/// ## 整体链路
///
/// ```
/// WebView
///   │  ProxyController 指向 127.0.0.1:<桥端口>   （只认 HTTP）
///   ▼
/// LocalProxyBridge（本机 HTTP 代理）
///   │  CONNECT 转 SOCKS5 握手
///   ▼
/// 远端 SOCKS5
/// ```
///
/// 为什么绕这一圈，见 [LocalProxyBridge] 的注释 —— 一句话：
/// Android WebView 不认 SOCKS5，传进去静默失效。
///
/// ## 一个代理一个身份
///
/// 身份绑定和轮换规则在 [IdentityLedger] 里。这里只负责在切换代理
/// 时把三样东西一起换掉，缺一样都等于没换：
///
/// 1. 出口 IP（桥换上游）
/// 2. 浏览器身份（UA / client hints / 垫片数据）
/// 3. 站点存储（localStorage / IndexedDB / cookie）
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:fus_inbox/core/proxy/identity_ledger.dart';
import 'package:fus_inbox/core/proxy/local_http_bridge.dart';
import 'package:fus_inbox/core/proxy/proxy_config.dart';

/// 原生代理通道。
const _channel = MethodChannel('fusinbox/webview');

/// 当前代理的实际生效状态。
class ActiveProxy {
  const ActiveProxy({
    required this.config,
    required this.bridgePort,
    required this.ok,
    required this.detail,
  });

  final ProxyConfig config;

  /// 本地桥监听的端口。0 表示没起桥（直连或 HTTP 代理直通）。
  final int bridgePort;

  /// 是否真的生效了。
  final bool ok;

  /// 给人看的一句话。
  final String detail;
}

/// 管理「当前走哪个代理」。
class ProxyEngine {
  ProxyEngine();

  LocalProxyBridge? _bridge;
  ActiveProxy? _active;

  ActiveProxy? get active => _active;

  bool get isRunning => _bridge != null;

  /// 内核支持不支持代理覆盖。
  Future<bool> supportsProxy() async {
    try {
      final ok = await _channel.invokeMethod<bool>('supportsProxy');
      return ok ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// 让 WebView 走 [config]。
  ///
  /// 返回的结果里 `ok=false` 表示没设上 —— 上层应当把它当「直连」处理，
  /// 而不是当作成功继续跑（那会静默泄漏真实 IP）。
  Future<ActiveProxy> apply(ProxyConfig config) async {
    // 先把上一条拆干净，否则会留下两个桥。
    await stop();

    if (config.isDirectProxy) {
      await _clearNative();
      final out = ActiveProxy(
        config: config,
        bridgePort: 0,
        ok: true,
        detail: '直连',
      );
      _active = out;
      return out;
    }

    // HTTP/HTTPS 代理可以直通，WebView 原生支持。
    if (!config.needsBridge) {
      final ok = await _applyNative(config.host, config.port);
      final out = ActiveProxy(
        config: config,
        bridgePort: 0,
        ok: ok,
        detail: ok
            ? '${config.displayName}（直通）'
            : '${config.displayName} 设置失败，内核可能不支持',
      );
      _active = out;
      return out;
    }

    // SOCKS5：本机起 HTTP 桥，WebView 指向它。
    try {
      final bridge = await LocalProxyBridge.start(config);
      _bridge = bridge;
      final ok = await _applyNative('127.0.0.1', bridge.port);
      final out = ActiveProxy(
        config: config,
        bridgePort: bridge.port,
        ok: ok,
        detail: ok
            ? '${config.displayName}（经本地桥 ${bridge.port}）'
            : '${config.displayName} 桥已起，但 WebView 设置代理失败',
      );
      _active = out;
      return out;
    } catch (e) {
      // 桥起不来（端口被占、代理地址非法）就当直连，别让用户
      // 以为还在走代理。
      final out = ActiveProxy(
        config: config,
        bridgePort: 0,
        ok: false,
        detail: '${config.displayName} 起桥失败：$e',
      );
      _active = out;
      return out;
    }
  }

  /// 拆掉当前代理，恢复直连。
  Future<void> stop() async {
    final bridge = _bridge;
    _bridge = null;
    if (bridge != null) {
      try {
        await bridge.stop();
      } catch (e) {
        debugPrint('停桥失败：$e');
      }
    }
    _active = null;
  }

  /// 完全清除：拆桥 + 清原生代理。
  Future<void> clear() async {
    await stop();
    await _clearNative();
  }

  Future<bool> _applyNative(String host, int port) async {
    try {
      final ok = await _channel.invokeMethod<bool>('applyProxy', {
        'host': host,
        'port': port,
        // 回环必须绕过，否则桥自己的连接会绕回自己形成死循环。
        'bypass': const ['127.0.0.1', 'localhost', '*'],
      });
      return ok ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException catch (e) {
      debugPrint('设置代理失败：$e');
      return false;
    }
  }

  Future<void> _clearNative() async {
    try {
      await _channel.invokeMethod<void>('clearProxy');
    } on MissingPluginException {
      // 非 Android 平台，忽略。
    } on PlatformException catch (e) {
      debugPrint('清代理失败：$e');
    }
  }
}

/// 一个代理是否真的能用 —— 起桥后本地握手一次。
///
/// 用户配代理时最容易填错 host/port/账号密码。这里不做真实外网请求
/// （那会把用户的代理额度烧掉），只做 TCP 连通 + SOCKS5 握手。
Future<String?> probeProxy(ProxyConfig config) async {
  if (config.isDirectProxy) return null;
  try {
    final socket = await Socket.connect(
      config.host,
      config.port,
      timeout: const Duration(seconds: 8),
    );
    socket.destroy();
    return null;
  } on SocketException catch (e) {
    return '连不上 ${config.host}:${config.port} — ${e.message}';
  } catch (e) {
    return '连不上 ${config.host}:${config.port} — $e';
  }
}
