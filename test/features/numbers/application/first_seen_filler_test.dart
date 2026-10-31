import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fus_inbox/features/numbers/application/first_seen_store.dart';

/// 用本地 HTTP 服务替代站点，验证 [FirstSeenFiller] 的真实行为。
///
/// 这些断言全部对着**实际发出的请求**验，不是对着实现里的常量验：
/// 「并发数是多少」这种事写死一个常量去断言它等于 6，等于用我自己的
/// 代码证明我自己对。这里测的是**同一时刻最多有几个请求在飞**。
void main() {
  late HttpServer server;
  late List<String> paths;
  String base = '';
  int inFlight = 0;
  int maxInFlight = 0;

  setUp(() async {
    // `FirstSeenStore.put` 会 `await ready`，而 ready 等的是读盘。
    // 测试环境没有真实 SharedPreferences，不 mock 的话它一直挂着，
    // 第一个 `put` 就把整个 worker 堵死 —— 表现为「并发数是 1」。
    SharedPreferences.setMockInitialValues(<String, Object>{});
    paths = <String>[];
    inFlight = 0;
    maxInFlight = 0;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://${server.address.host}:${server.port}';
    // 每个请求单独起一个 task —— `await for` 里直接 await 会把循环堵住，
    // 那样服务器本身是串行的，客户端并发再好也只能看到 1。
    server.listen((req) {
      unawaited(() async {
        inFlight++;
        if (inFlight > maxInFlight) maxInFlight = inFlight;
        paths.add(req.uri.path);
        // 模拟站点详情页的 1.4 秒响应，这样并发才有意义。
        await Future<void>.delayed(const Duration(milliseconds: 140));
        req.response
          ..statusCode = 200
          ..headers.contentType = ContentType.html
          // 结构照抄站点真实详情页（`curl` 抓到的原文）：
          // <div><dt>First recorded in our directory</dt><dd><time ...>
          ..write(
            '<div><dt>First recorded in our directory</dt><dd>'
            '<time data-insights-date="directory_first_seen_at">'
            '2026-10-28 08:29 UTC</time></dd></div>',
          );
        await req.response.close();
        inFlight--;
      }());
    });
  });

  tearDown(() async => server.close(force: true));

  // Notifier 不能直接 new —— 它要 ref/state，必须由容器建。
  ProviderContainer container() {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    return c;
  }

  Future<FirstSeenStore> freshStore(ProviderContainer c) async {
    final s = c.read(firstSeenStoreProvider.notifier);
    await s.ready;
    return s;
  }

  test('并发后：6 路同时在飞，且全部抓回', () async {
    final store = await freshStore(container());
    final filler = FirstSeenFiller(egress: () => 'DIRECT', baseUrl: base);
    final numbers = [for (var i = 0; i < 12; i++) '141900000${10 + i}'];
    await filler.fillMissing(store, numbers);
    expect(paths.length, 12);
    // 12 个号、6 路并发 → 峰值应该是 6（受 worker 数限制）。
    expect(maxInFlight, greaterThan(1), reason: '并发改动必须真的并发，否则这次优化等于没做');
    expect(maxInFlight, lessThanOrEqualTo(6), reason: 'worker 数不该超过 6');
    // 每一条都要落进 store。
    expect(store.state.length, 12);
  });

  test('可中断：cancel 之后不再发新请求', () async {
    final store = await freshStore(container());
    final filler = FirstSeenFiller(egress: () => 'DIRECT', baseUrl: base);
    final numbers = [for (var i = 0; i < 30; i++) '141900001${10 + i}'];
    final run = filler.fillMissing(store, numbers);
    // 头几个请求已经发出去了，这时候喊停。
    await Future<void>.delayed(const Duration(milliseconds: 300));
    filler.cancel();
    final added = await run;
    // 30 个号全抓完需要 ~0.8 秒（6 路），300ms 时停只能抓一部分。
    expect(paths.length, lessThan(30), reason: 'cancel 之后不该把队列跑完');
    expect(added, lessThanOrEqualTo(store.state.length));
  });

  test('出口没起来时拒绝直连，不是静默 DIRECT', () async {
    final store = await freshStore(container());
    final filler = FirstSeenFiller(egress: () => null, baseUrl: base);
    final added = await filler.fillMissing(store, ['14190000001']);
    expect(added, 0);
    // 一个请求都不该发出去 —— 发了就是拿真实 IP 打站点。
    expect(paths, isEmpty, reason: 'egress 为 null 时必须 fail closed');
  });

  test('已经是 200 的响应能解析出收录时间', () async {
    final store = await freshStore(container());
    final filler = FirstSeenFiller(egress: () => 'DIRECT', baseUrl: base);
    await filler.fillMissing(store, ['14190000001']);
    final at = store.state['14190000001'];
    expect(at, isNotNull);
    expect(at!.toUtc(), DateTime.utc(2026, 10, 28, 8, 29));
  });
}
