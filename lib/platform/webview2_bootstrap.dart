/// Windows 独有的「第一次创建 WebView 之前」那一步。
///
/// ## 为什么要有这一步
///
/// WebView2 的代理和用户数据目录是**环境（environment）参数**，一个进程
/// 只能建一次，而且在任何 WebView 被创建之前就得定好。所以：
///
/// - 代理要指向那条**常驻桥**，端口必须在建环境之前就拿到
///   → 调用方先 `ProxyEngine.ensureBridge()`
/// - 用户数据目录写在 `%APPDATA%` 下，别落在 exe 旁边（那里常常没写权限）
///
/// 这一步失败时**不能继续**：没有 WebView2 运行时的话，页面根本渲染不出来，
/// 硬走下去只会得到一个白屏。所以它返回一句人话，而不是抛异常。
///
/// 非 Windows 平台上 `ensureWebViewEnvironment` 直接返回 null，
/// [windowsWebViewEnvironment] 恒为 null —— 调用方不需要分平台写分支。
library;

import 'dart:io';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// Windows 上那个「全局唯一」的 WebView2 环境。非 Windows 恒为 null。
WebViewEnvironment? windowsWebViewEnvironment;

/// 已经试过就算了，别每次开号都去问一遍运行时在不在。
bool _windowsProbed = false;
String? _windowsProblem;

/// Windows 上初始化 WebView2 环境。返回 `null` = 就绪，否则是一句人话。
///
/// 在 App 启动阶段调一次。非 Windows 平台直接返回 null（不需要做任何事）。
Future<String?> ensureWebViewEnvironment({int? proxyPort}) async {
  if (!Platform.isWindows) return null;
  if (_windowsProbed) return _windowsProblem;
  _windowsProbed = true;

  try {
    // 没装运行时的话，后面所有 WebView 都会白屏 —— 在这里就说清楚，
    // 别让用户对着一片空白猜。
    final available = await WebViewEnvironment.getAvailableVersion();
    if (available == null) {
      _windowsProblem =
          '这台机器没有 Microsoft Edge WebView2 运行时，页面无法显示。'
          '装上它再打开本应用（微软官网搜 “WebView2 Runtime” 即可）。';
      return _windowsProblem;
    }

    windowsWebViewEnvironment = await WebViewEnvironment.create(
      settings: WebViewEnvironmentSettings(
        userDataFolder: _userDataFolder(),
        // **代理只在这里定一次，之后改不了。**
        // 所以这里指向的是那条常驻桥，而不是某一条具体代理 ——
        // 按号换出口由桥的热切换完成（见 LocalProxyBridge）。
        additionalBrowserArguments: proxyPort == null
            ? null
            : '--proxy-server=127.0.0.1:$proxyPort',
      ),
    );
    return null;
  } catch (e) {
    _windowsProblem = 'WebView2 环境初始化失败：$e';
    return _windowsProblem;
  }
}

/// WebView2 的用户数据目录。
///
/// 用 `%APPDATA%` 而不是可执行文件旁边：安装在 `Program Files` 下的应用
/// 对自身目录**没有写权限**，放那里会静默失败。
String? _userDataFolder() {
  final appData = Platform.environment['APPDATA'];
  if (appData == null || appData.isEmpty) return null;
  return '$appData\\fus-inbox\\webview2';
}
