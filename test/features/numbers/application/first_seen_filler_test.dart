import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fus_inbox/features/numbers/application/first_seen_store.dart';

/// 用本地 HTTP 服务验 [FirstSeenFiller] 的真实请求行为。
///
/// 断言全部对着**实际发出的请求**验，不是对着实现里的常量验：
/// 「并发数是多少」这种写死常量再断言它等于 6，等于用自己的代码证明
/// 自己对。这里测的是同一时刻最多有几个请求在飞、第二轮有没有真的跑起来。
void main() {
  late HttpServer server;
  late List<String> paths;
  String base = '';
  int inFlight = 0;
  int maxInFlight = 0;

  setUp(() async {
    // `put` 会 `await ready`，ready 等的是读盘。不 mock 的话它一直挂着，
    // 第一个 put 就把 worker 堵死 —— 表现为「并发数是 1」。
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
        await Future<void>.delayed(const Duration(milliseconds: 140));
        req.response
          ..statusCode = 200
          ..headers.contentType = ContentType.html
          // 结构照抄站点真实详情页：
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

  test('6 路同时在飞，且全部抓回', () async {
    final store = await freshStore(container());
    final filler = FirstSeenFiller(egress: () => 'DIRECT', baseUrl: base);
    final numbers = [for (var i = 0; i < 12; i++) '141900000${10 + i}'];
    await filler.fillMissing(store, numbers);
    expect(paths.length, 12);
    // 12 个号、6 路并发 → 峰值受 worker 数限制。
    expect(maxInFlight, greaterThan(1), reason: '并发改动必须真的并发，否则这次优化等于没做');
    expect(maxInFlight, lessThanOrEqualTo(6), reason: 'worker 数不该超过 6');
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
    expect(paths.length, lessThan(30), reason: 'cancel 之后不该把队列跑完');
    expect(added, lessThanOrEqualTo(store.state.length));
  });

  test('cancel 之后新起的那一轮照常跑（点开收件页再回来能续上）', () async {
    final store = await freshStore(container());
    final filler = FirstSeenFiller(egress: () => 'DIRECT', baseUrl: base);

    // 第一轮：12 个号。
    final first = filler.fillMissing(store, [
      for (var i = 0; i < 12; i++) '141900000${10 + i}',
    ]);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    // 用户点开收件页 → cancel。
    filler.cancel();
    await first;

    // 从收件页返回 → 再起一轮。这一轮记的是新世代号，不该受上一次
    // cancel 影响 —— 否则「停了就再也补不上」。
    //
    // 第一轮被 cancel 时只补完了一部分，所以第二轮要补的正是剩下的那些
    // 号 + 新号。断言不能写死「等于 1」：能确定的是**第二轮确实跑了**，
    // 以及两轮合起来把 12 个号 + 新号全部补上。
    final second = filler.fillMissing(store, [
      for (var i = 0; i < 12; i++) '141900000${10 + i}',
      '14190000200',
    ]);
    expect(await second, greaterThan(0), reason: 'cancel 只作废它之前发起的那一轮');
    expect(store.state.length, 13, reason: '两轮合起来要把所有号补齐');
    expect(store.state['14190000200'], isNotNull);
  });

  test('出口没起来时拒绝直连，不是静默 DIRECT', () async {
    final store = await freshStore(container());
    final filler = FirstSeenFiller(egress: () => null, baseUrl: base);
    final added = await filler.fillMissing(store, ['14190000001']);
    expect(added, 0);
    // 一个请求都不该发出去 —— 发了就是拿真实 IP 打站点。
    expect(paths, isEmpty, reason: 'egress 为 null 时必须 fail closed');
  });

  test('200 的响应能解析出收录时间', () async {
    final store = await freshStore(container());
    final filler = FirstSeenFiller(egress: () => 'DIRECT', baseUrl: base);
    await filler.fillMissing(store, ['14190000001']);
    final at = store.state['14190000001'];
    expect(at, isNotNull);
    expect(at!.toUtc(), DateTime.utc(2026, 10, 28, 8, 29));
  });

  test('第一轮还在跑时来的第二轮是排队，不是被丢掉', () async {
    final store = await freshStore(container());
    final filler = FirstSeenFiller(egress: () => 'DIRECT', baseUrl: base);

    // 第一轮：12 个号，要跑约 0.3 秒。
    final first = filler.fillMissing(store, [
      for (var i = 0; i < 12; i++) '141900000${10 + i}',
    ]);
    // 第二轮紧接着来：新号。启动那轮补齐要三十秒，用户在这期间下拉
    // 刷新是很常见的时序 —— 这一轮必须真的跑起来。
    final second = filler.fillMissing(store, [
      for (var i = 0; i < 12; i++) '141900000${10 + i}',
      '14190000200',
    ]);

    final a = await first;
    final b = await second;

    // 第二轮的新号必须被补上 —— 如果第二轮被 `return 0` 丢掉，这里会是 0。
    expect(b, 1, reason: '第二轮必须真跑，否则刷新拉回来的新号补不上');
    expect(store.state['14190000200'], isNotNull);
    // 两轮各 12 个请求，第二轮里 12 个老的已经在缓存里，只该发 1 个。
    expect(paths.length, 13, reason: '第二轮不该重抓已有的号');
    expect(a, 12);
    // 两轮之间是串行的 —— 并发峰值不该叠到 12。
    expect(maxInFlight, lessThanOrEqualTo(6));
  });

  test('第一轮失败不会让排队的第二轮一起失败', () async {
    final store = await freshStore(container());
    // egress 为 null 让第一轮一个请求都发不出去（内部全部 return null，
    // 不抛异常）；这里要的是「第一轮抛异常」的形状，用非法 baseUrl 造。
    final bad = FirstSeenFiller(
      egress: () => 'DIRECT',
      baseUrl: 'http://127.0.0.1:1',
    );
    final first = bad.fillMissing(store, ['14190000001']);
    // 第一轮还没结束时排第二轮。注意：`fetchFirstSeen` 内部把异常都
    // 吃成了 null，所以这里第一轮本身不会抛 —— 断言的是「排队逻辑
    // 不因为前一轮的失败结果而崩」。
    final second = bad.fillMissing(store, ['14190000001']);
    await first;
    expect(await second, 0);
  });
}
