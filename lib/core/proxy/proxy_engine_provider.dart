/// 全 App 唯一的那条出口。
///
/// ## 为什么要提到 app 级
///
/// 原来 [ProxyEngine] 是 `_InboxScreenState` 的一个字段 —— 桥只在
/// 「打开某个号的收件页」这段时间里活着。这带来三个问题：
///
/// 1. **号码目录拿不到出口**。目录页是另一个页签，进它的时候收件页
///    还没建起来。目录和收件本来就该共用同一条出口（同一个节点），
///    分成两个实例就意味着两条桥、两个出口，还会互相覆盖
///    `ProxyController` 的全局设置。
/// 2. **桥会泄漏**。离开收件页时 `dispose()` 不拆引擎，桥的
///    `ServerSocket` 和原生代理覆盖都留着；再进一次又起一个。
/// 3. **出口不是全局的**，但 `ProxyController.setProxyOverride` 是
///    全局的 —— 两个引擎会互相覆盖对方的原生设置。
///
/// 提到这里之后，App 里所有出网流量共用同一条链：
///
/// ```
///   WebView ──ProxyController──┐
///                              ├─→ LocalProxyBridge ─→ SOCKS5 ─→ 站点
///   dart:io HttpClient ─findProxy─┘
/// ```
///
/// 这也是加 Windows 支持的前提：Windows 没有 `ProxyController`，
/// 但 `HttpClient.findProxy` 和本地桥都是纯 Dart，跨平台一样用。
/// 把出口收敛到一个地方，换平台时才只有一处要改。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fus_inbox/core/proxy/proxy_engine.dart';

/// 全 App 共享的代理引擎。
///
/// 用 `Provider` 而不是全局单例变量：测试里每个用例能拿到干净的实例，
/// 而且 `ref.onDispose` 保证热重载 / 退出时把桥拆掉。
final proxyEngineProvider = Provider<ProxyEngine>((ref) {
  final engine = ProxyEngine();
  // 引擎持有 ServerSocket 和原生通道状态，必须显式收尾。
  ref.onDispose(() => unawaitedClear(engine));
  return engine;
});

/// 把一个**已经在外面建好的**引擎塞进容器。
///
/// 启动时要在 `runApp` 之前就把桥起好（Windows 的 WebView2 环境参数要它
/// 的端口），所以那个实例是 `main()` 建的，不能等 provider 懒加载。用
/// override 交进容器，其余代码照常 `ref.read(proxyEngineProvider)`。
/// `ref.onDispose` 收的是同步回调，拆桥是异步的。
///
/// 这里不 `await` 是有意的：dispose 阶段等不了异步（调用方已经在拆
/// widget 树了），而桥的 `ServerSocket.close()` 本身不会失败到需要重试
/// 的程度。拆不掉最坏是留一个回环端口，进程退出时内核会回收。
void unawaitedClear(ProxyEngine engine) {
  engine.clear().catchError((Object _) {});
}
