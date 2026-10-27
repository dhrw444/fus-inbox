import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fus_inbox/app.dart';
import 'package:fus_inbox/core/webview/native_capabilities.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 必须在 runApp 之前：号码目录的原生 HTTP 会在首帧后立刻发起，
  // 而它要用这里探测出来的真实 UA。晚一步就会出现
  // 「目录请求用兜底 UA、WebView 用真实 UA」的不一致。
  await bootstrapBrowserIdentity();
  runApp(const ProviderScope(child: App()));
}
