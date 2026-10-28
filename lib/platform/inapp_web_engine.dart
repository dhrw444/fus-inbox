/// [WebEngine] 的 `flutter_inappwebview` 实现：状态 + 生命周期方法。
///
/// ## 时序：配置先攒着，建视图时一次交下去
///
/// `flutter_inappwebview` 的控制器是**页面里的视图创建出来的**（回调
/// `onWebViewCreated`），不像 `webview_flutter` 那样能先 new 一个控制器。
/// 而收件页的调用顺序是「先 setUserAgent、注入垫片，再建视图，最后
/// loadUrl」。
///
/// 所以这里把配置全部攒在字段上，[buildView] 时一次性交给
/// `initialSettings` / `initialUserScripts`。**这不是为了迁就包，反而是
/// 对的**：那几件事本来就该在视图存在之前定下来（见 `web_engine.dart` 的注释）。
///
/// ## 与 `webview_flutter` 的三处语义差异
///
/// 1. **JS 通道**：那个包把通道名直接挂成 `window.<name>`；这个包统一走
///    `window.flutter_inappwebview.callHandler('<name>', …)`。JS 侧因此
///    要改一处 —— 见 `assets/js/fus_inbox.js` 里选通道的那个 `post()`。
/// 2. **文档开始注入**：那个包只有 Android 有（还得走 `WebViewCompat`），
///    这个包是跨平台的 `UserScript`。顺带把 `native_capabilities.dart`
///    里那段「原生能力探测」省掉了。
/// 3. **加载错误回调**：那个包分 `onWebResourceError`（资源加载失败）和
///    `onHttpError`（HTTP 错误码）两套，这个包合并成一个 `onReceivedError`，
///    主框架判断在 `request.isForMainFrame`。
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'package:fus_inbox/platform/engine_settings.dart';
import 'package:fus_inbox/platform/inapp_view_builder.dart';
import 'package:fus_inbox/platform/web_engine.dart';

class InAppWebEngine({String userAgent = '', this.environment})
    implements WebEngine {
  // 字段初始化器引用主构造器的参数 —— 这样命名参数还能叫 userAgent
  // （参数名不能以下划线开头），而字段保持私有。
  String _userAgent = userAgent;

  /// Windows 上那个全局唯一的 WebView2 环境（非 Windows 恒为 null）。
  ///
  /// 它带着 `--proxy-server`，所以**代理其实在环境里定好了**；
  /// 这里再持有一次只是为了把 `CookieManager` 绑到同一个环境 ——
  /// 不绑的话 cookie 会落在默认环境里，和页面看到的不是同一份。
  final WebViewEnvironment? environment;

  InAppWebViewController? _controller;
  bool _disposed = false;

  // ── 建视图之前攒下的配置 ──────────────────────────────────────────
  final List<UserScript> _userScripts = [];
  final Map<String, void Function(String)> _messageHandlers = {};
  void Function(String url)? _onPageStarted;
  void Function(String url)? _onPageFinished;
  void Function(WebEngineError error)? _onError;
  bool Function(String url)? _allowNavigation;

  // ── 给 `inapp_view_builder.dart` 的内部通道 ───────────────────────
  // buildView 的那棵回调树拆在 `inapp_view_builder.dart` 里，但配置攒在
  // 本类的字段上，所以下面这些必须跨文件可见。
  //
  // **别在别的文件里用它们** —— 它们不是这个类对外的能力，只是拆文件留的
  // 接缝。这里用注释而不是 `@internal` 标注：`@internal` 只对「公开包的
  // 私有 API」有意义，而这个应用 `publish_to: none`、没有对外 API 面，
  // 标注上去 analyzer 会报 `invalid_internal_annotation`。

  /// 建视图时还没交出去的「文档开始」脚本。
  List<UserScript> get pendingUserScripts => _userScripts;

  /// 建视图时攒下的 JS 通道（通道名 → 处理函数）。
  Map<String, void Function(String)> get messageHandlers => _messageHandlers;

  /// 导航闸门。null = 全部放行。
  bool Function(String url)? get allowNavigation => _allowNavigation;

  /// 当前 UA。视图还没建时只是存着，建的时候交给 `initialSettings`。
  String get userAgent => _userAgent;

  /// 视图创建出来的那一刻由回调树回填控制器。
  void attachController(InAppWebViewController controller) {
    // dispose 已经跑过就别接了：那时 `_controller == null`，而 dispose 里
    // 那句 `_controller?.dispose()` 早已跳过 —— 这个控制器**再也不会被释放**。
    // 要求 dispose 早于 `onWebViewCreated` 回调，概率低，但守卫成本为零。
    if (_disposed) return;
    _controller = controller;
  }

  void emitPageStarted(String url) => _onPageStarted?.call(url);

  void emitPageFinished(String url) => _onPageFinished?.call(url);

  void emitError(WebEngineError error) => _onError?.call(error);

  @override
  void onPageStarted(void Function(String url) handler) =>
      _onPageStarted = handler;

  @override
  void onPageFinished(void Function(String url) handler) =>
      _onPageFinished = handler;

  @override
  void onWebResourceError(void Function(WebEngineError error) handler) =>
      _onError = handler;

  @override
  void onMessage(String name, void Function(String message) handler) =>
      _messageHandlers[name] = handler;

  @override
  void onNavigationRequest(bool Function(String url) allow) =>
      _allowNavigation = allow;

  @override
  Future<void> setUserAgent(String userAgent) async {
    _userAgent = userAgent;
    // 视图已经建好了就当场改；还没有就留着建的时候用。
    final c = _controller;
    if (c != null && !_disposed) {
      await c.setSettings(settings: engineSettings(_userAgent));
    }
  }

  @override
  void injectOnDocumentStart(String script) {
    final userScript = UserScript(
      source: script,
      // 文档创建后、**页面任何脚本执行前**。用 `evaluateJavascript`
      // 太晚了：那时站点脚本和 Turnstile 早就读完 navigator 了。
      injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
      // forMainFrameOnly 不传：默认就是 true，而我们要的正是它 ——
      // 垫片只该装进主框架，站点广告的跨域 iframe 不用装。
    );
    // 视图还没建 → 攒着，建的时候走 `initialUserScripts`。
    if (_controller == null) {
      _userScripts.add(userScript);
      return;
    }
    // 视图**已经建好了** → 必须当场补注册。
    //
    // 这不是优化，是不补就不工作：收件页的顺序是「initState 里建引擎 →
    // build 建出视图 → 异步的 _startUp 才注入垫片」。只丢进 `_userScripts`
    // 的话，那份列表在建视图时已经交出去了，**垫片永远装不上** ——
    // 而站点的 Turnstile 会立刻发现 navigator 少了 userAgentData。
    if (!_disposed) {
      unawaited(_controller!.addUserScript(userScript: userScript));
    }
  }

  @override
  Widget buildView({Key? key}) => buildInAppView(this, key: key);

  @override
  Future<void> loadUrl(String url) async {
    final c = _controller;
    if (c == null || _disposed) return;
    await c.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
  }

  @override
  Future<void> runJavaScript(String script) async {
    final c = _controller;
    if (c == null || _disposed) return;
    await c.evaluateJavascript(source: script);
  }

  @override
  Future<Object?> evaluateJavascript(String script) async {
    final c = _controller;
    if (c == null || _disposed) return null;
    try {
      return await c.evaluateJavascript(source: script);
      // 页面还没就绪时 `evaluateJavascript` 会抛（时序问题，不是错误）。
      // 调用方（量验证框位置）本来就容忍拿不到值，返回 null 让它下一轮再试。
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> reload() async {
    final c = _controller;
    if (c == null || _disposed) return;
    await c.reload();
  }

  @override
  Future<Map<String, String>> readCookies(String url) async {
    if (_disposed) return const {};
    try {
      final list = await CookieManager.instance(webViewEnvironment: environment)
          .getCookies(url: WebUri(url));
      // 逐个判类型，不用集合字面量：`Cookie.value` 是 `dynamic`，直接塞进
      // `Map<String, String>` 是一次隐式 dynamic 转换（`no_dynamic_casts`），
      // 而且元素类型对不上（`map_value_type_not_assignable`）——
      // 真拿到非字符串时会在赋值那一刻炸。
      final out = <String, String>{};
      for (final c in list) {
        final value = c.value;
        if (c.name.isEmpty || value is! String) continue;
        out[c.name] = value;
      }
      return out;
    } catch (_) {
      // 读失败返回空 map，不抛 —— 调用方据此区分「没拿到」和
      // 「拿到了但里面没有 cf_clearance」。
      return const {};
    }
  }

  @override
  Future<bool> clearSiteData() async {
    if (_disposed) return false;
    try {
      await CookieManager.instance(webViewEnvironment: environment)
          .deleteAllCookies();
      await WebStorageManager.instance().deleteAllData();
      // 实例上的 `clearCache()` 已废弃，官方替代是**静态**的
      // `InAppWebViewController.clearAllCache()`（清的是全进程所有
      // WebView 的缓存，不是这一个）。这个 App 同时只存在一个 WebView，
      // 两者效果相同；默认连磁盘缓存一起清，换身份要的正是这个。
      await InAppWebViewController.clearAllCache();
      return true;
    } catch (_) {
      // 清不干净比清多了危险（下次开号带着旧密钥），所以尽力而为之后
      // 由收件页的 JS 侧兜底再清一次 localStorage / IndexedDB。
      return false;
    }
  }

  @override
  Future<String> defaultUserAgent() async {
    try {
      // 不加 `?? ''`：这方法返回的是非空 String，兜底永远不会走
      // （analyzer 报 dead_code + dead_null_aware_expression）。
      // 真失败是抛异常，由下面的 catch 兜。
      return await InAppWebViewController.getDefaultUserAgent();
    } catch (_) {
      return '';
    }
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    final c = _controller;
    _controller = null;
    if (c == null) return;
    try {
      // 这个包的 `dispose()` 返回 void 不是 Future —— 别 await 它。
      c.dispose();
    } catch (_) {
      // 视图已经不在树上了，收尾失败没有补救价值。
    }
  }
}

/// 忽略一个 Future 的结果，**并且吞掉它的异常**。
///
/// ## 和 `dart:async` 的 `unawaited` 语义不同，别当等价物
///
/// 标准库那个只是把「没 await」这件事标记出来（压 lint），**异常照旧
/// 进 zone**、该崩还是会崩、该上报还是会到 Crashlytics。这个实现
/// 用 `catchError` 把异常整个吃掉 —— 调用点全是「视图已经不在树上」
/// 那类收尾动作，崩了也没人接，所以故意吞。
///
/// 换句话说：**往这里塞新调用之前先想清楚**，它会把失败藏起来。
/// 需要保留失败线索的，老老实实 `await` + `try/catch` 自己处理。
///
/// 本地小工具，故意不借用标准库那个名字：这里的行为更重（吞错），
/// 共用一个名字会让人以为两者等价。
void unawaited(Future<void> future) {
  future.catchError((Object _) {});
}
