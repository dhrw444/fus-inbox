/// 全项目唯一的日志出口。
///
/// ## 为什么不用 `debugPrint`
///
/// Flutter 的 `debugPrint` 好用，但它来自 `package:flutter/foundation.dart` ——
/// 那个库在顶层 `export 'dart:ui'`。**只要有一个文件 import 它，
/// 整条 import 链就不能在纯 Dart VM 里编译**，会报
/// `Dart library 'dart:ui' is not available on this platform`。
///
/// 后果是实打实的：`tool/` 下那些实测脚本（账本、代理、目录出口行为）
/// 全都用 `dart run` 跑，而它们 import 的 `numbers_repository` 只是
/// 为了打两句日志就拖进了 `dart:ui` —— 于是那些测试**一条都跑不起来**。
/// 这不是理论问题，是已经发生过的事。
///
/// 所以日志走这里：只依赖 `dart:io`，任何环境都能编译。
///
/// ## 为什么不直接 `print`
///
/// `lib/` 不在 `analysis_options.yaml` 的 exclude 里，`print` 会命中
/// `avoid_print`，而 CI 跑 `--fatal-infos`。`stderr` 完全绕开这条规则，
/// 而且它本来就更适合「诊断信息」这个用途：stdout 留给真正的输出。
///
/// ## 用在哪些地方
///
/// 任何**不该影响控制流**的诊断信息：网络失败后已经走了回落分支、
/// 清数据没清干净、探测拿不到值。不要用它当错误上报 ——
/// 用户该看到的错误走界面，不在这里。
library;

import 'dart:io';

/// 打一行诊断日志。
///
/// 失败了也不抛：`stderr` 在某些嵌入式/管道环境里是关着的，
/// 「日志写不出去」不该把一个正常流程炸掉。
void logLine(String message) {
  try {
    stderr.writeln(message);
  } catch (_) {
    // 写不出去就算了 —— 见上。
  }
}
