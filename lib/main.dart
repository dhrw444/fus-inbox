/// 启动入口：探测身份 → 起常驻桥 → 初始化平台 WebView 环境 → 交给 [App]。
///
/// 三步的顺序是硬约束，不能换：身份必须在号码目录的第一次原生请求之前探到
/// （否则「目录用兜底 UA、WebView 用真实 UA」，正是 Cloudflare 最擅长串的
/// 特征）；桥的端口必须在第一个 WebView 之前固定下来（Windows 的 WebView2
/// 环境参数一个进程只能定一次）。
///
/// 启动期就失败时给 [_StartupProblemApp] 一句人话，而不是让用户对着白屏猜。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fus_inbox/app.dart';
import 'package:fus_inbox/core/proxy/proxy_engine.dart';
import 'package:fus_inbox/core/proxy/proxy_engine_provider.dart';
import 'package:fus_inbox/core/webview/native_capabilities.dart';
import 'package:fus_inbox/platform/web_engine_factory.dart';
import 'package:material_ui/material_ui.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 启动顺序是三件事，**不能换**，每一件都有它必须在前面或后面的理由：
  //
  // 1. 探测浏览器身份
  //    号码目录的原生 HTTP 会在首帧后立刻发起，而它要用这里探出来的
  //    真实 UA。晚一步就会出现「目录请求用兜底 UA、WebView 用真实 UA」
  //    的不一致 —— 那正是 Cloudflare 最擅长串的一类特征。
  await bootstrapBrowserIdentity();

  // 2. 起那条常驻桥、并且**先于任何 WebView**
  //    Windows 上 WebView2 的代理是环境创建参数，一个进程只能定一次，
  //    而且必须在第一个 WebView 之前。所以端口要在这里就固定下来，
  //    之后按号换出口全部靠桥的热切换（见 LocalProxyBridge）。
  //    Android 上顺序无所谓，但统一走同一条路径省得两端行为不一样。
  final engine = ProxyEngine();
  final bridgePort = await engine.ensureBridge();

  // 3. 用桥的端口初始化平台 WebView 环境
  //    非 Windows 恒返回 null（平台自己处理代理）。
  final problem = await ensureWebViewEnvironment(proxyPort: bridgePort);

  runApp(
    ProviderScope(
      // 让页面里拿到的就是这一条已经起好的引擎 —— 不然 `main` 建了一个、
      // 收件页又建一个，两个实例各自持着一条桥，原生代理会互相覆盖。
      overrides: [proxyEngineProvider.overrideWithValue(engine)],
      child: problem == null
          ? const App()
          : _StartupProblemApp(message: problem),
    ),
  );
}

/// 启动期就失败时给的页面。
///
/// 只有一种情况会走到这儿：Windows 上没装 WebView2 运行时。那种情况下
/// 页面**根本渲染不出来**，硬启动只会得到一片白屏 —— 与其让用户对着
/// 空白猜，不如直接说清楚要装什么。
class const _StartupProblemApp({required this.message})
    extends StatelessWidget {
  final String message;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline, size: 48),
                const SizedBox(height: 16),
                Text(message, textAlign: TextAlign.center),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
