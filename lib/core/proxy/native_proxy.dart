/// 让 WebView 把流量交给本机桥。**「哪个出口」的平台分叉点只有这里。**
///
/// 全仓还有另外两处 `Platform.is*`，但它们不是「选出口」的分叉：
/// `webview2_bootstrap.dart` 是 Windows 上建 WebView2 环境的**前置条件**
/// （代理参数就在那儿写进去），`webview_info.dart` 是只读探测（默认 UA /
/// 运行时版本 / 平台名），都不参与任何决策。真正「同一件事两个平台两种
/// 做法」的只有这个文件。
///
/// ## 两个平台的差别
///
/// | | Android | Windows |
/// |---|---|---|
/// | 机制 | `ProxyController.setProxyOverride` | WebView2 环境参数 `--proxy-server` |
/// | 时机 | **运行时随时可改** | **创建环境时定一次，之后改不了** |
/// | 谁来设 | 我们自己调 | 起 WebView2 之前就得定好 |
///
/// 第二行是关键：Windows 上代理是**进程级**的，问不了「这个号用哪个出口」。
/// 所以架构上把「换出口」全部下沉到本机桥 —— WebView 永远指向桥，桥的
/// 上游按号热切换（见 `LocalProxyBridge`）。
///
/// 于是 Windows 的实现几乎是空的：环境参数里已经指向桥了，[apply] 只要
/// 记住「现在是哪条出口」就够了，不需要真的去动 WebView。
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// 把 WebView 指向 `host:port` 的能力。
///
/// 末尾的 `()` 是主构造器的空标记（本仓统一写法）：这个接口没有构造参数。
abstract interface class NativeProxy() {
  /// 让 WebView 之后的流量走 `host:port`。
  ///
  /// 返回 false = 这个平台/内核设不上。调用方**必须当真**，不能当成功
  /// 继续往下走 —— 那会拿真实 IP 去撞站点。
  Future<bool> apply({required String host, required int port});

  /// 恢复直连。
  Future<void> clear();

  /// 内核支持不支持代理覆盖。
  ///
  /// 不支持时该给「这个系统用不了代理」的明确提示，而不是让用户一条一条
  /// 换代理试下去 —— 换多少条都没用。
  Future<bool> supported();

  /// 内核版本号。只用于诊断（支持不了的时候要能说出当前是什么版本）。
  Future<String> engineVersion();

  /// 这台平台上，**所有**流量是不是必须经过本机桥。
  ///
  /// Android 是 false：HTTP 代理可以原生直通，只有 SOCKS5 需要桥。
  /// Windows 是 true：WebView2 的代理是环境创建参数，进程内只指向桥一次，
  /// 想走别的出口只能换桥的上游 —— 而桥只认 SOCKS5 和直连两种上游。
  ///
  /// 有了这个标记，遇到「这台平台做不到的代理类型」时能**如实报错**，
  /// 而不是返回一个看起来成功的 [apply] 让界面显示「已生效」。
  bool get allTrafficGoesThroughBridge;
}

/// 按当前平台选一个实现。非 Android / Windows 一律落到「不支持」。
NativeProxy nativeProxy() {
  if (kIsWeb) return const UnsupportedNativeProxy();
  if (Platform.isAndroid) return const AndroidNativeProxy();
  if (Platform.isWindows) return const WindowsNativeProxy();
  return const UnsupportedNativeProxy();
}

/// 非 Android / Windows：一律「做不到」，且如实说出来。
final class const UnsupportedNativeProxy() implements NativeProxy {
  @override
  Future<bool> apply({required String host, required int port}) async => false;

  @override
  Future<void> clear() async {}

  @override
  Future<bool> supported() async => false;

  @override
  Future<String> engineVersion() async => '未知';

  @override
  bool get allTrafficGoesThroughBridge => false;
}

/// Android：走 `androidx.webkit` 的 `ProxyController`。
///
/// 用的是 **`flutter_inappwebview` 自带的通道**，不是我们自己写的 Kotlin ——
/// 之前那份 `ProxyControllerBridge.kt` 干的是一模一样的事，但它只在 Android
/// 上有实现，加 Windows 时成了要维护的第二份。插件这条路两端共用一套 Dart
/// API，那份 Kotlin 因此删掉了。
final class const AndroidNativeProxy() implements NativeProxy {
  @override
  Future<bool> apply({required String host, required int port}) async {
    try {
      await ProxyController.instance().setProxyOverride(
        settings: ProxySettings(
          proxyRules: [ProxyRule(url: '$host:$port')],
          // 只绕过回环，**绝不能加 `*`**。
          //
          // 这里的规则是 Chrome 的 proxy-bypass-list 语法，按**目标主机**
          // 匹配，`*` 等于「所有目标都直连」—— 加上它整个代理就静默失效，
          // 一条流量都不走代理，而且没有任何报错。
          //
          // 代理服务器自己（127.0.0.1:桥端口）不受 bypass 影响：bypass
          // 只管「去哪个目标」，不管「怎么连到代理」。
          bypassRules: const ['127.0.0.1', 'localhost'],
        ),
      );
      return true;
    } catch (_) {
      // 老内核没有 PROXY_OVERRIDE 时会抛。返回 false 让上层把话说清楚，
      // 而不是当成功继续跑 —— 那会拿真实 IP 去撞站点。
      return false;
    }
  }

  @override
  Future<void> clear() async {
    try {
      await ProxyController.instance().clearProxyOverride();
    } catch (_) {
      // 清不掉不影响使用：下一次 apply 会覆盖。这是唯一允许静默的场合。
    }
  }

  @override
  Future<bool> supported() async {
    try {
      // 唯一能问到内核的话是走一次通道调用 —— 老内核没有 PROXY_OVERRIDE
      // 时 MethodChannel 会抛 PlatformException。`clearProxyOverride` 是
      // 这些调用里副作用最小的：它只是撤掉覆盖，而调用方（`ProxyEngine`）
      // 只会在 apply **已经失败之后**才来问这一句，那时本来就没有生效的
      // 覆盖可撤。查版本号不可靠：内核版本号和特性开关不是一回事。
      await ProxyController.instance().clearProxyOverride();
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<String> engineVersion() async => '系统 WebView';

  @override
  bool get allTrafficGoesThroughBridge => false;
}

/// Windows：什么都不用做。
///
/// WebView2 的代理是**环境创建参数**（`additionalBrowserArguments:
/// '--proxy-server=127.0.0.1:<桥端口>'`），App 启动时就指向那条常驻桥了
/// （见 `platform/webview2_bootstrap.dart` 的 `ensureWebViewEnvironment`）。
/// 之后换出口全在桥那边完成，WebView 侧不需要任何动作。
///
/// 所以 [apply] 直接返回 true —— 它没有失败的可能，因为压根没做事。
/// 这不是偷懒：**真的去动 WebView2 反而做不到**，环境只有一个，参数只在
/// 创建时读。
///
/// [supported] 返回 true：WebView2 必然支持 `--proxy-server`。真正要检查的
/// 是运行时装没装 WebView2，那是启动期的事（同上），不是每次换出口都要问。
final class const WindowsNativeProxy() implements NativeProxy {
  @override
  Future<bool> apply({required String host, required int port}) async => true;

  @override
  Future<void> clear() async {}

  @override
  Future<bool> supported() async => true;

  @override
  Future<String> engineVersion() async => 'WebView2';

  @override
  bool get allTrafficGoesThroughBridge => true;
}
