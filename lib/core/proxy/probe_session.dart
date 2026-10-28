/// 一次「全部检测」的进度会话：进度怎么算、结果快照怎么给。
///
/// 会话编排（谁跑完了、进度到哪、快照啥时候发）和检测本体（一条代理
/// 怎么探）是两件事。以前 notifier 里自己实现了一遍 queue + worker + 快照，
/// `proxy_probe.dart` 里还有一份没人调用的同款 —— 两边的并发参数和异常
/// 语义已经漂了。收敛成这里一个纯函数之后，notifier 只给一个 `apply`
/// 回调，聚合逻辑只有这一份。
library;

import 'package:fus_inbox/core/proxy/proxy_config.dart';
import 'package:fus_inbox/core/proxy/proxy_probe.dart';

/// 跑完一整轮检测，每完成一条就把进度和结果快照交给 [apply]。
///
/// [apply] 的参数：
/// - `progress` —— 已完成条数；
/// - `probeTotal` —— 本轮总数；
/// - `results` —— 按 `proxy.id` 索引的**不可变快照**。界面直接 watch 它，
///   原地改的 map Riverpod 看不到变化，所以每次都是新对象。
///
/// 异常语义由 [ProxyProbe.probeAll] 决定 —— 单条代理的失败已经被
/// [ProxyProbe.probeOne] 收成 `ok == false` 的结果，所以这里正常不会抛；
/// 万一抛了（比如任务被取消），异常原样往上走，让调用方的 `finally`
/// 去收尾。
Future<void> runProbeSession({
  required ProxyProbe probe,
  required List<ProxyConfig> targets,
  required int concurrency,
  required void Function(
    int progress,
    int probeTotal,
    Map<String, ProxyProbeResult> results,
  )
  apply,
}) async {
  final results = <String, ProxyProbeResult>{};
  await probe.probeAll(
    targets,
    concurrency: concurrency,
    onProgress: (done, total, last) {
      results[last.proxy.id] = last;
      // `Map.unmodifiable` 本身就是一份拷贝，不必先 `{...results}` 再包一层。
      apply(done, total, Map<String, ProxyProbeResult>.unmodifiable(results));
    },
  );
}
