/// 把「代理池 → 本地桥 → WebView」这一串接起来。
///
/// ## 整体链路
///
/// ```
/// WebView
///   │  ProxyController 指向 127.0.0.1:<桥端口>   （一条 HTTP 规则串）
///   ▼
/// LocalProxyBridge（本机 HTTP 代理）
///   │  CONNECT 转 SOCKS5 握手
///   ▼
/// 远端 SOCKS5
/// ```
///
/// 为什么绕这一圈，见 [LocalProxyBridge] 的注释 —— 一句话：规则串语法里
/// 没有 userinfo 位，带账号密码的 SOCKS5 出不去，必须过桥。
///
/// ## 一个代理一个身份
///
/// 身份绑定和轮换规则在 [IdentityLedger] 里。这里只负责在切换代理
/// 时把三样东西一起换掉，缺一样都等于没换：
///
/// 1. 出口 IP（桥换上游）
/// 2. 浏览器身份（UA / client hints / 垫片数据）
/// 3. 站点存储（localStorage / IndexedDB / cookie）
///
/// `ActiveProxy`（活动出口的值对象）和 `nativeEgressDirective()`（给
/// `dart:io` 的出口指令，纯函数）家在 `active_proxy.dart` —— 值/推导可以
/// 不拉起整个引擎就单独测。本文件转出去，老引用方 import 这里照常能用。
library;

import 'dart:async';

import 'package:fus_inbox/core/log.dart';
import 'package:fus_inbox/core/proxy/active_proxy.dart';
import 'package:fus_inbox/core/proxy/identity_ledger.dart';
import 'package:fus_inbox/core/proxy/local_http_bridge.dart';
import 'package:fus_inbox/core/proxy/native_proxy.dart';
import 'package:fus_inbox/core/proxy/proxy_config.dart';

// 值对象和纯函数从 active_proxy.dart 转出去：老引用方只 import 本文件。
export 'package:fus_inbox/core/proxy/active_proxy.dart';

/// 顶层纯函数的替身。类里有个**同名实例 getter**，在 getter 体内裸调
/// `nativeEgressDirective(...)` 会解析到 getter 自己 —— 无限递归。
/// 在类外先把函数 tear-off 存住，getter 里用这个。
const _egressDirective = nativeEgressDirective;

/// 常驻桥优先绑这个端口。
///
/// 为什么不是一个随机端口：Windows 上 WebView2 的代理是**环境创建参数**
/// （`--proxy-server=127.0.0.1:<端口>`），必须在建 WebView 之前就写死，
/// 之后改不了。所以要有一个「默认就在这儿」的稳定端口。
/// 被占用时退到系统分配（Android 无所谓，Windows 上会退化成
/// 「本次运行的端口」，仍然全程一致）。
const _preferredBridgePort = 47811;

/// 管理「当前走哪个代理」。
class ProxyEngine() {
  LocalProxyBridge? _bridge;
  ActiveProxy? _active;

  ActiveProxy? get active => _active;

  /// 给 `dart:io` 的 `HttpClient.findProxy` 用的出口指令。
  ///
  /// 规则在 `active_proxy.dart` 的 `nativeEgressDirective()`（纯函数，测试
  /// 直接喂值），这里只是接到当前活动出口上。返回 null = 当前没有可用出口，
  /// 调用方必须让请求失败，绝不能退化成直连（会静默泄漏真实 IP）。
  String? get nativeEgressDirective => _egressDirective(_active);

  /// 平台代理通道。Android 是运行时接口，Windows 是空实现（见它的注释）。
  final NativeProxy _native = nativeProxy();

  /// 起那条**常驻**桥。
  ///
  /// Windows 上必须在建 WebView **之前**调它 —— WebView2 的代理是环境
  /// 创建参数，端口要在那一刻就定下来。Android 上早调晚调都行。
  ///
  /// 幂等：桥已经在了就原样返回端口。
  Future<int> ensureBridge() async {
    final existing = _bridge;
    if (existing != null) return existing.port;
    try {
      _bridge = await LocalProxyBridge.start(port: _preferredBridgePort);
    } catch (_) {
      // 首选端口被占（别的程序、或上一次没退干净的自己）——
      // 退到系统分配。Windows 上仍然全程一致，只是不再是那个固定值。
      _bridge = await LocalProxyBridge.start();
    }
    return _bridge!.port;
  }

  /// 让 WebView 走 [config]。
  ///
  /// `ok=false` 表示没设上 —— 上层必须把它当「直连」处理，不能当作成功
  /// 继续跑（那会静默泄漏真实 IP）。
  ///
  /// ## 换出口**不再重建桥**
  ///
  /// 桥是常驻的、端口固定：WebView 从进程启动就指向它，换的是桥的上游
  /// （[LocalProxyBridge.setUpstream]）。以前每换一次号就 `stop()` + 重建，
  /// 在 Android 上要多握一次 SOCKS5，在 Windows 上**根本做不到** ——
  /// WebView2 的环境参数改不了。这条改动是 Windows 支持的前提。
  Future<ActiveProxy> apply(ProxyConfig config) async {
    // 直连：桥留着（Windows 的 WebView 还指着它），只是不再有上游。
    if (config.isDirectProxy) {
      await ensureBridge();
      _bridge!.setUpstream(null);
      // 桥自己就能直连，所以 WebView 依然指向桥即可；但 Android 上
      // 更干净的做法是把原生代理清掉 —— 少一跳，也少一个可能出错的环节。
      await _native.clear();
      final out = ActiveProxy(
        config: config,
        bridgePort: 0,
        ok: true,
        detail: '直连',
      );
      _active = out;
      return out;
    }

    // HTTP/HTTPS 代理：Android 可以原生直通；Windows 走不了桥
    // （桥只做 SOCKS5 和直连两种上游），如实标出来而不是假装成功。
    if (!config.needsBridge) {
      final ok = await _native.apply(host: config.host, port: config.port);
      final out = ActiveProxy(
        config: config,
        bridgePort: 0,
        ok: ok,
        detail: ok
            ? '${config.displayName}（直通）'
            : await _failDetail(config, '设置失败'),
      );
      _active = out;
      return out;
    }

    // SOCKS5：桥常驻，上游换成它。
    try {
      final port = await ensureBridge();
      _bridge!.setUpstream(config);
      final ok = await _native.apply(host: '127.0.0.1', port: port);
      final out = ActiveProxy(
        config: config,
        bridgePort: port,
        ok: ok,
        detail: ok
            ? '${config.displayName}（经本地桥 $port）'
            : await _failDetail(config, '桥已起，但 WebView 设置代理失败'),
      );
      _active = out;
      return out;
    } catch (e) {
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

  /// 代理没设上时，给一句**能照着做**的话。
  ///
  /// 内核支持与否必须分开说：不支持时用户会一条一条换代理试下去，
  /// 而其实换多少条都没用。
  Future<String> _failDetail(ProxyConfig config, String base) async {
    if (await _native.supported()) {
      // 内核支持，那就是这条代理/这次设置的问题，换一条确实可能管用。
      return '${config.displayName} $base，换一条试试';
    }
    final version = await _native.engineVersion();
    return '${config.displayName} 用不了：这个系统的 WebView 不支持代理覆盖'
        '（当前 WebView $version，需要较新的版本）。换代理没用 —— '
        '要么更新 WebView，要么别用代理。';
  }

  /// 拆掉桥并恢复直连。
  ///
  /// 只在 App 退出时调。**每次换号不要调这个** —— 见 [apply]。
  Future<void> stop() async {
    final bridge = _bridge;
    _bridge = null;
    if (bridge != null) {
      try {
        await bridge.stop();
      } catch (e) {
        logLine('停桥失败：$e');
      }
    }
    _active = null;
  }

  /// 完全清除：拆桥 + 清原生代理。
  Future<void> clear() async {
    await stop();
    await _native.clear();
  }
}
