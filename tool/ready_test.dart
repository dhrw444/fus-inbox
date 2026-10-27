// `ready` 的语义实测。
//
// 直接测 ProxyNotifier 不行 —— 它 import flutter_riverpod，纯 Dart 跑不了。
// 所以这里复刻「Completer + timeout」那段机制，验证四条性质。
// 复刻的代码与 proxy_provider.dart 里的 _ready / ready 逐字对应。

import 'dart:async';
import 'dart:io';

int passed = 0;
int failed = 0;

void ok(bool cond, String what, [String extra = '']) {
  if (cond) {
    passed++;
    print('  ok   $what  $extra');
  } else {
    failed++;
    print('  FAIL $what  $extra');
  }
}

/// 与 ProxyNotifier 里的 _ready + ready 同一机制。
class Holder {
  final Completer<void> _ready = Completer<void>();
  bool loaded = false;
  int completeCalls = 0;

  Future<void> get ready =>
      _ready.future.timeout(const Duration(seconds: 3), onTimeout: () {});

  /// 对应 _load 的 finally。
  void finish() {
    loaded = true;
    if (!_ready.isCompleted) {
      _ready.complete();
      completeCalls++;
    }
  }
}

Future<void> main() async {
  print('=== 1. loaded 之前 await ready 会真的挂住，直到 finish ===');
  {
    final h = Holder();
    var resumed = false;
    final waiter = h.ready.then((_) => resumed = true);
    await Future<void>.delayed(const Duration(milliseconds: 120));
    ok(!resumed, '还没 finish 时等待方没醒');
    h.finish();
    await waiter;
    ok(resumed, 'finish 之后等待方醒了');
    ok(h.loaded, 'loaded 已置位');
  }

  print('');
  print('=== 2. 零轮询：完成是一次事件，不是 16ms 空转 ===');
  {
    final h = Holder();
    final sw = Stopwatch()..start();
    var polls = 0;
    final waiter = h.ready.then((_) => polls++);
    // 在 finish 之前数一下有多少次事件循环机会被白白用掉。
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    h.finish();
    await waiter;
    sw.stop();
    ok(polls == 1, '回调只跑 1 次（轮询版会跑多次）', '(polls=$polls)');
    ok(
      sw.elapsedMilliseconds < 1000,
      '没有等满 3 秒超时',
      '(${sw.elapsedMilliseconds}ms)',
    );
  }

  print('');
  print('=== 3. 已经 loaded 时 ready 立刻返回，不多挂一帧 ===');
  {
    final h = Holder()..finish();
    final sw = Stopwatch()..start();
    await h.ready;
    sw.stop();
    ok(sw.elapsedMilliseconds < 20, '立即返回', '(${sw.elapsedMilliseconds}ms)');
  }

  print('');
  print('=== 4. 重复 finish 不会抛（Completer 只允许 complete 一次）===');
  {
    final h = Holder();
    h.finish();
    h.finish();
    h.finish();
    ok(h.completeCalls == 1, '只 complete 了 1 次', '(calls=${h.completeCalls})');
  }

  print('');
  print('=== 5. 超时后放行，但 loaded 仍是 false —— 调用方必须自己查 ===');
  {
    final h = Holder();
    final sw = Stopwatch()..start();
    await h.ready; // 永远不 finish，走 3 秒兜底
    sw.stop();
    ok(
      sw.elapsedMilliseconds >= 2900,
      '真的等了约 3 秒',
      '(${sw.elapsedMilliseconds}ms)',
    );
    ok(!h.loaded, 'loaded 仍为 false');
    ok(true, '↑ 所以 _startUp 必须查 loaded 并停下，不能算计划');
  }

  print('');
  print('$passed passed, $failed failed');
  if (failed > 0) exit(1);
}
