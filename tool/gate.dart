// 纯逻辑门禁：一条命令跑完全部不碰外网的检查。
//
// ## 为什么要有这个文件
//
// 这些检查原先散在十七个 `tool/*.dart` 里，每个自带一套 `pass/fail`
// 计数器和 `print` 尾巴。跑一次要记十七条命令，漏一条就等于没验。
// 收成一个入口之后：
//
//     /tmp/an.sh run tool/gate.dart
//
// 退出码非 0 = 有失败，可以直接挂在 CI 上。
//
// ## 这里放什么、不放什么
//
// **放**：纯 Dart 逻辑，能在没有 Flutter 运行时的环境里跑（值类、状态机、
// 协议实现、排序稳定性）。它们不 import `flutter`，CI 之外也能验。
//
// **不放**：要自己起服务器的（`bridge_test`、`socks5_test`、`bridge_upstream_test`）、
// 要真外网的（`translate_live_test`）、要发版的（`set_release_version`）。
// 那几样各自单独跑 —— 它们里的 `exit()` 是有意的，进了 gate 会连坐。
//
// ## 失败怎么传
//
// 每段测试跑完打印 `N passed, M failed`，但**打印不等于判据**：
// 有的脚本失败时 `exit(1)`（单独跑靠这个），有的只 `throw`。
// 这里统一用「抛异常 = 失败」判，因为 gate 里不能真的 exit。
// 所以被 import 的脚本有一条约定：**失败时抛异常，别 exit**。

import 'dart:io';

import 'can_rotate_test.dart' as canRotate;
import 'findproxy_failclosed_test.dart' as findproxy;
import 'inbox_search_test.dart' as inboxSearch;
import 'first_seen_test.dart' as firstSeen;
import 'identity_drift_test.dart' as drift;
import 'identity_platform_test.dart' as idPlatform;
import 'leak_probe.dart' as leak;
import 'ledger_test.dart' as ledger;
import 'loaded_probe.dart' as loaded;
import 'mint_identity_test.dart' as mint;
import 'number_sort_test.dart' as sort;
import 'proxy_logic_test.dart' as proxy;
import 'ready_test.dart' as ready;
import 'verify_round_test.dart' as verify;
import 'webview_version_test.dart' as webviewVersion;

/// 一段检查。抛异常 = 这段失败。
typedef Case = void Function();

void main() {
  // 顺序按「越靠底层越先跑」排：账本和代理配置是所有决策的地基，
  // 身份和轮转建在它们上面，状态机又在更外面。前面的挂了，后面的
  // 失败往往只是连坐 —— 先看到根因比先看到一堆红更有用。
  final cases = <String, Case>{
    '账本：开号决策 / 出口分配': ledger.main,
    '代理配置解析': proxy.main,
    '换出口的可行性（canRotate）': canRotate.main,
    '造身份自洽性': mint.main,
    '一个代理一个身份': drift.main,
    '身份的跨平台一致性': idPlatform.main,
    '验证轮状态机': verify.main,
    'loaded 语义': loaded.main,
    '目录排序稳定性': sort.main,
    '收录时间解析': firstSeen.main,
    '收件箱搜索': inboxSearch.main,
    'findProxy 兜底': findproxy.main,
    'ready 超时语义': ready.main,
    '代理失败必须停': leak.main,
    'WebView 版本检测': webviewVersion.main,
  };

  final failed = <String>[];

  for (final entry in cases.entries) {
    print('');
    print('══ ${entry.key}');
    try {
      entry.value();
    } catch (e) {
      failed.add('${entry.key}：$e');
      print('   ↑ 失败：$e');
    }
  }

  print('');
  if (failed.isEmpty) {
    print('全部通过（${cases.length} 段）');
    // 显式退出。被 import 的那些测试里有几条没取消的 socket /
    // timer 订阅吊着事件循环，光靠 main() 返回，VM 不会结束 ——
    // 表现为「跑完了但命令一直不返回」，CI 里就是一直挂到超时。
    exit(0);
  }
  print('${failed.length} 段失败：');
  for (final f in failed) {
    print('  · $f');
  }
  throw StateError('${failed.length} 段失败');
}
