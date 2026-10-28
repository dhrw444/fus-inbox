/// `InAppWebView` 那棵回调树。
///
/// ## 为什么从 `inapp_web_engine.dart` 拆出来
///
/// 那一半是**引擎的状态与生命周期**（配置攒在字段上、UA、cookie、清理），
/// 这一半是**把内核事件接到我们的回调**——纯接线，不持有任何状态。
/// 两件事的时间轴不同：状态活整个会话，接线只在视图建出来那一刻生效。
/// 挤在一个文件里，读「UA 什么时候生效」要先跳过六十行回调。
///
/// 拆出的代价是 [InAppWebEngine] 的私有字段要在这边访问，所以它们
/// 用 `@internal` 标注：仓库内可用、包外不可见，编译器继续替我们拦住
/// 别处的越界访问。
library;

import 'dart:collection';

import 'package:flutter/widgets.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'package:fus_inbox/platform/engine_settings.dart';
import 'package:fus_inbox/platform/inapp_web_engine.dart';
import 'package:fus_inbox/platform/web_engine.dart';

/// 造出 [InAppWebView] 并把攒下的配置与回调全部接上。
///
/// 引擎对象在这里只被读，不被改 —— 所有状态变更仍走它自己的方法。
/// 视图的 [Key] 由调用方传给 `buildView`，这里不重复管。
Widget buildInAppView(InAppWebEngine engine) {
  return InAppWebView(
    webViewEnvironment: engine.environment,
    initialSettings: engineSettings(engine.userAgent),
    initialUserScripts: UnmodifiableListView(engine.pendingUserScripts),
    onWebViewCreated: (controller) {
      engine.attachController(controller);
      // 通道要在页面脚本跑之前注册好，否则第一帧的消息会丢。
      for (final e in engine.messageHandlers.entries) {
        controller.addJavaScriptHandler(
          handlerName: e.key,
          // 参数类型必须显式写：`JavaScriptHandlerCallback` 的签名是
          // `dynamic Function(List<dynamic>)`，省略不写会被推断成 dynamic
          // （`inference_failure_on_untyped_parameter`），进而让下面那句
          // `args.isNotEmpty` 变成「条件不是 bool」（`non_bool_condition`），
          // 以及一次隐式 dynamic 转换（`no_dynamic_casts`）。
          callback: (List<dynamic> args) {
            if (args.isEmpty) return null;
            // 站点的 JS 侧发的是字符串。不是字符串就丢掉 —— 与其把任意
            // dynamic 拼成字符串塞给状态层（那层会把这段 JSON 直接解析），
            // 不如在这里挡住。
            final first = args.first;
            if (first is String) e.value(first);
            return null;
          },
        );
      }
    },
    shouldOverrideUrlLoading: (controller, action) async {
      final allow = engine.allowNavigation;
      if (allow == null) return NavigationActionPolicy.ALLOW;
      final url = action.request.url?.toString() ?? '';
      if (url.isEmpty) return NavigationActionPolicy.ALLOW;
      return allow(url)
          ? NavigationActionPolicy.ALLOW
          : NavigationActionPolicy.CANCEL;
    },
    onLoadStart: (controller, url) {
      if (url != null) engine.emitPageStarted(url.toString());
    },
    onLoadStop: (controller, url) {
      if (url != null) engine.emitPageFinished(url.toString());
    },
    onReceivedError: (controller, request, error) {
      // 只报**主框架**的错。子资源（图床、埋点）失败是常态，
      // 拿它当页面失败会让每张图挂掉一次就走一轮重试。
      final main = request.isForMainFrame ?? true;
      if (main) {
        engine.emitError(
          WebEngineError(
            description: error.description,
            code: error.type.toNativeValue() ?? 0,
            isForMainFrame: true,
            url: request.url.toString(),
          ),
        );
      }
    },
  );
}
