// 账本逻辑实测。纯逻辑，不碰网络。
// 运行：dart run tool/ledger_test.dart
import 'dart:convert';

import 'package:fus_inbox/core/proxy/proxy_config.dart';
import 'package:fus_inbox/core/proxy/identity_ledger.dart';

int pass = 0;
int fail = 0;

void ok(bool cond, String name) {
  if (cond) {
    pass++;
    print('  ok   $name');
  } else {
    fail++;
    print('  FAIL $name');
  }
}

void eq(Object? got, Object? want, String name) {
  ok(got == want, '$name  (got=$got want=$want)');
}

void main() {
  var n = 0;
  String mintUa() => 'UA-${++n}';
  String mintModel() => 'Model-$n';
  String mintChrome() => '12$n';

  final pool = <ProxyConfig>[
    parseProxyLine('socks5://1.1.1.1:1080')!,
    parseProxyLine('socks5://2.2.2.2:1080')!,
    parseProxyLine('http://3.3.3.3:8080')!,
  ];

  // ---------- 1. 没配代理 ----------
  {
    final led = IdentityLedger();
    final plan = led.plan(
      pool: const [],
      currentProxyId: '',
      numberId: 'n1',
      mintUserAgent: mintUa,
      mintModel: mintModel,
      mintChromeMajor: mintChrome,
    );
    ok(plan.proxy.isDirectProxy, '空池走直连');
    eq(plan.action, OpenAction.reuse, '空池不轮换');
  }

  // ---------- 2. 一个新代理第一次用 ----------
  {
    final led = IdentityLedger();
    final plan = led.plan(
      pool: pool,
      currentProxyId: pool[0].id,
      numberId: 'n1',
      mintUserAgent: mintUa,
      mintModel: mintModel,
      mintChromeMajor: mintChrome,
    );
    // 契约已改：在一条**从没绑过**的出口上第一次开号，账本现造一台新设备
    // → 必须是 rotate（换身份 + 清密钥），不是 reuse。
    //
    // 以前这里断言 reuse，于是 _applyProxyPlan 的 reuse 分支「什么都不用做」：
    // 账本记下新设备，页面却还挂着上一条出口的旧身份和旧密钥。判据是
    // 「binding 是现造的还是账本里已有的」，不是「出口换没换」。
    eq(plan.action, OpenAction.rotate, '首次要轮换（新设备）');
    eq(plan.binding.used, 0, '首次身份未用');
    eq(plan.proxy.id, pool[0].id, '用当前代理');
    led.commit(plan.proxy.id, 'n1', plan.binding);
    eq(led.forProxy(pool[0].id)!.used, 1, '入账 1 个号');
  }

  // ---------- 3. 本地不限号：同一个身份一直复用 ----------
  //
  // 站点从不告诉你「上限是几个、已用几个」（SITE.md §5：没有任何配额
  // 头、没有计数字段）。本地猜一个数字，猜小了就是白扔站点还愿意给的
  // 额度 —— 多换一次出口 = 多烧一个身份。所以开号一律复用，
  // 什么时候换由站点说（429 pause / 403 challenge）。
  {
    final led = IdentityLedger();
    final firstUa = <String>[];
    for (var i = 1; i <= 12; i++) {
      final plan = led.plan(
        pool: pool,
        currentProxyId: pool[0].id,
        numberId: 'n$i',
        mintUserAgent: () {
          final ua = mintUa();
          firstUa.add(ua);
          return ua;
        },
        mintModel: mintModel,
        mintChromeMajor: mintChrome,
      );
      // 第 1 个号是「这条出口上第一次开号」→ 现造新设备 → rotate；
      // 之后一直是同一台设备，**不管已经看了几个号**。
      eq(
        plan.action,
        i == 1 ? OpenAction.rotate : OpenAction.reuse,
        i == 1 ? '第 $i 个号是新设备，要轮换' : '第 $i 个号仍复用',
      );
      eq(plan.proxy.id, pool[0].id, '第 $i 个号仍落在同一条出口');
      led.commit(plan.proxy.id, 'n$i', plan.binding);
    }
    eq(led.forProxy(pool[0].id)!.used, 12, '看了 12 个号，全记在同一条出口');
    eq(firstUa.length, 1, '12 个号只铸造过 1 个身份');
  }

  // ---------- 4. 重复打开同一个号不耗额度 ----------
  {
    final led = IdentityLedger();
    final p1 = led.plan(
      pool: pool,
      currentProxyId: pool[0].id,
      numberId: 'same',
      mintUserAgent: mintUa,
      mintModel: mintModel,
      mintChromeMajor: mintChrome,
    );
    led.commit(p1.proxy.id, 'same', p1.binding);
    // 同一个号再开 5 次
    for (var i = 0; i < 5; i++) {
      final p = led.plan(
        pool: pool,
        currentProxyId: pool[0].id,
        numberId: 'same',
        mintUserAgent: mintUa,
        mintModel: mintModel,
        mintChromeMajor: mintChrome,
      );
      eq(p.action, OpenAction.reuse, '重开同一个号不轮换');
      led.commit(p.proxy.id, 'same', p.binding);
    }
    eq(led.forProxy(pool[0].id)!.used, 1, '重开只算 1 个号');
  }

  // ---------- 5. 换出口时优先挑没绑过身份的那条 ----------
  //
  // 「满了」这个概念本地已经没有了（不限号）。这里测的是换出口时的
  // 挑选规则：优先落在没绑过身份的出口上造新设备，其次才落到绑过的
  // 出口上复用它的身份 —— 同一个 IP 上冒出第二台才是最扎眼的信号。
  {
    final led = IdentityLedger();
    final a = led.plan(
      pool: pool,
      currentProxyId: pool[0].id,
      numberId: 'x1',
      mintUserAgent: mintUa,
      mintModel: mintModel,
      mintChromeMajor: mintChrome,
    );
    eq(a.action, OpenAction.rotate, 'P0 首次要造新身份');
    led.commit(a.proxy.id, 'x1', a.binding);

    final b = led.plan(
      pool: pool,
      currentProxyId: pool[1].id,
      numberId: 'y1',
      mintUserAgent: mintUa,
      mintModel: mintModel,
      mintChromeMajor: mintChrome,
    );
    eq(b.action, OpenAction.rotate, '代理 1 首次要轮换（新设备）');
    led.commit(b.proxy.id, 'y1', b.binding);

    // 换出口：P0 和 P1 都绑过了，P2 没有 → 必须给 P2。
    final next = led.nextUsableProxy(pool, pool[1].id);
    eq(next?.id, pool[2].id, '优先挑没绑过身份的出口');
  }

  // ---------- 6. 序列化往返 ----------
  {
    final led = IdentityLedger();
    for (var i = 1; i <= 3; i++) {
      final p = led.plan(
        pool: pool,
        currentProxyId: pool[0].id,
        numberId: 'k$i',
        mintUserAgent: mintUa,
        mintModel: mintModel,
        mintChromeMajor: mintChrome,
      );
      led.commit(p.proxy.id, 'k$i', p.binding);
    }
    final json = jsonEncode(led.toJson());
    final back = IdentityLedger.fromJson(jsonDecode(json));
    eq(back.forProxy(pool[0].id)!.used, 3, '往返后计数一致');
    eq(
      back.forProxy(pool[0].id)!.userAgent,
      led.forProxy(pool[0].id)!.userAgent,
      '往返后 UA 一致',
    );
    // 落盘里不再写额度上限（本地不限号），老盘面里的这个键要能照常忽略。
    ok(!led.toJson().containsKey('maxPerIdentity'), '落盘不写额度上限');
    final p4 = back.plan(
      pool: pool,
      currentProxyId: pool[0].id,
      numberId: 'k4',
      mintUserAgent: mintUa,
      mintModel: mintModel,
      mintChromeMajor: mintChrome,
    );
    eq(p4.action, OpenAction.reuse, '往返后仍然复用同一个身份');
  }

  // ---------- 6.1 老盘面带 maxPerIdentity 也不崩 ----------
  {
    final led = IdentityLedger();
    final p = led.plan(
      pool: pool,
      currentProxyId: pool[0].id,
      numberId: 'old1',
      mintUserAgent: mintUa,
      mintModel: mintModel,
      mintChromeMajor: mintChrome,
    );
    led.commit(p.proxy.id, 'old1', p.binding);
    final old = jsonDecode(jsonEncode(led.toJson())) as Map<String, Object?>;
    old['maxPerIdentity'] = 3;
    final back = IdentityLedger.fromJson(old);
    eq(back.forProxy(pool[0].id)!.used, 1, '老盘面照样读得出绑定');
    final again = back.plan(
      pool: pool,
      currentProxyId: pool[0].id,
      numberId: 'old2',
      mintUserAgent: mintUa,
      mintModel: mintModel,
      mintChromeMajor: mintChrome,
    );
    eq(again.action, OpenAction.reuse, '老盘面里的 3 不再限制开号');
  }

  // ---------- 7. 坏 JSON 不崩 ----------
  {
    for (final bad in [
      null,
      'null',
      42,
      [],
      {},
      {'bindings': 'x'},
    ]) {
      final led = IdentityLedger.fromJson(bad);
      ok(led.bindings.isEmpty, '坏数据回落空账本 ($bad)');
    }
  }

  // ---------- 8. clearProxy ----------
  {
    final led = IdentityLedger();
    final p = led.plan(
      pool: pool,
      currentProxyId: pool[0].id,
      numberId: 'z',
      mintUserAgent: mintUa,
      mintModel: mintModel,
      mintChromeMajor: mintChrome,
    );
    led.commit(p.proxy.id, 'z', p.binding);
    ok(led.forProxy(pool[0].id) != null, 'clear 前有绑定');
    led.clearProxy(pool[0].id);
    ok(led.forProxy(pool[0].id) == null, 'clear 后没了');
  }

  // ---------- 9. unusable 过滤 ----------
  //
  // 检测判死的代理不进候选。但**只在还有别的可选时**才剔 ——
  // 全判死说明检测本身有问题（比如没网时点了一次全部检测），
  // 那时候按检测结果走会退化成直连，拿真实 IP 去撞站点更糟。
  {
    final led = IdentityLedger();
    final p = led.plan(
      pool: pool,
      currentProxyId: pool[0].id,
      numberId: 'u1',
      mintUserAgent: mintUa,
      mintModel: mintModel,
      mintChromeMajor: mintChrome,
      unusable: {pool[0].id, pool[1].id},
    );
    ok(p.proxy.id == pool[2].id, '判死的跳过，选到第三条');
  }
  {
    // 全判死 → 退回不剔，仍然用池子里的代理，绝不落到直连。
    final led = IdentityLedger();
    final p = led.plan(
      pool: pool,
      currentProxyId: pool[0].id,
      numberId: 'u2',
      mintUserAgent: mintUa,
      mintModel: mintModel,
      mintChromeMajor: mintChrome,
      unusable: pool.map((e) => e.id).toSet(),
    );
    ok(!p.proxy.isDirectProxy, '全判死也不退化成直连');
    ok(p.proxy.id == pool[0].id, '全判死时仍用当前这条');
  }
  {
    // 当前出口判死 + 池里还有活的 → 换出口时不落到判死的那条。
    final led = IdentityLedger();
    for (final n in ['a', 'b', 'c']) {
      final q = led.plan(
        pool: pool,
        currentProxyId: pool[0].id,
        numberId: n,
        mintUserAgent: mintUa,
        mintModel: mintModel,
        mintChromeMajor: mintChrome,
      );
      led.commit(q.proxy.id, n, q.binding);
    }
    final r = led.plan(
      pool: pool,
      currentProxyId: pool[0].id,
      numberId: 'd',
      mintUserAgent: mintUa,
      mintModel: mintModel,
      mintChromeMajor: mintChrome,
      unusable: {pool[1].id},
    );
    // 本地不限号，所以这里仍然复用当前出口的身份 —— 判死的是别的出口，
    // 与「这次用哪条」无关。
    eq(r.action, OpenAction.reuse, '当前出口还有身份就直接复用');
    eq(r.proxy.id, pool[0].id, '复用当前这条出口');
    ok(r.proxy.id != pool[1].id, '不会落到判死的那条');
  }

  // ---------- 14. 回头点老号：必须切回原来那条出口 + 原来那个身份 ----------
  //
  // 这是「之前验证过的号码，我重新点进去为何不是之前的 socks5 + 身份」。
  {
    final led = IdentityLedger();

    // 在 pool[0] 上看 3 个号。
    Object? uaOnP0;
    for (final id in ['a1', 'a2', 'a3']) {
      final p = led.plan(
        pool: pool,
        currentProxyId: pool[0].id,
        numberId: id,
        mintUserAgent: mintUa,
        mintModel: mintModel,
        mintChromeMajor: mintChrome,
      );
      led.commit(p.proxy.id, id, p.binding);
      uaOnP0 = p.binding.userAgent;
    }
    eq(led.forProxy(pool[0].id)!.used, 3, 'P0 已看 3 个号');

    // 站点报限额 → `IdentityRotator` 换出口 + 换身份（这里手工模拟，
    // 那条路径在 `identity_rotator.dart`，不归账本管）。
    final d = led.plan(
      pool: pool,
      currentProxyId: pool[1].id,
      numberId: 'a4',
      mintUserAgent: mintUa,
      mintModel: mintModel,
      mintChromeMajor: mintChrome,
    );
    eq(d.action, OpenAction.rotate, '换到没绑过的出口要造新身份');
    eq(d.proxy.id, pool[1].id, '落在 pool[1]');
    led.commit(d.proxy.id, 'a4', d.binding);
    final nowCurrent = d.proxy.id;
    ok(nowCurrent != pool[0].id, '换出口后当前出口确实变了');

    // 回头点 a1 —— 它之前是 P0 上的身份看的。
    final back = led.plan(
      pool: pool,
      currentProxyId: nowCurrent,
      numberId: 'a1',
      mintUserAgent: mintUa,
      mintModel: mintModel,
      mintChromeMajor: mintChrome,
    );
    eq(back.action, OpenAction.restore, '回头点老号要切回原出口');
    eq(back.proxy.id, pool[0].id, '切回的是 P0');
    eq(back.binding.userAgent, uaOnP0, '复用 P0 上那个原身份，不新造');
    ok(back.restored, 'restored 标记为真');
    ok(!back.rotated, 'restore 不算轮换');

    // 落账不该多算 —— a1 本来就在 P0 的名单里。
    final usedP0 = led.forProxy(pool[0].id)!.used;
    led.commit(back.proxy.id, 'a1', back.binding);
    eq(led.forProxy(pool[0].id)!.used, usedP0, '重看老号不增加计数');
    eq(led.forProxy(nowCurrent)!.used, 1, '轮换后那条没被老号污染');
  }

  // ---------- 15. 原出口被删掉时不硬切 ----------
  {
    final led = IdentityLedger();
    final p = led.plan(
      pool: pool,
      currentProxyId: pool[0].id,
      numberId: 'z1',
      mintUserAgent: mintUa,
      mintModel: mintModel,
      mintChromeMajor: mintChrome,
    );
    led.commit(p.proxy.id, 'z1', p.binding);

    // 池子里已经没有 pool[0] 了（用户把它删了）。
    final gone = led.plan(
      pool: [pool[1], pool[2]],
      currentProxyId: pool[1].id,
      numberId: 'z1',
      mintUserAgent: mintUa,
      mintModel: mintModel,
      mintChromeMajor: mintChrome,
    );
    eq(gone.proxy.id, pool[1].id, '原出口不在池子里就正常走当前这条');
    ok(!gone.restored, '不应报 restore');
  }

  // ---------- 16. restore 之后仍能正常开号 ----------
  {
    final led = IdentityLedger();
    for (final id in ['r1', 'r2', 'r3']) {
      final p = led.plan(
        pool: pool,
        currentProxyId: pool[0].id,
        numberId: id,
        mintUserAgent: mintUa,
        mintModel: mintModel,
        mintChromeMajor: mintChrome,
      );
      led.commit(p.proxy.id, id, p.binding);
    }
    // 换到没绑过的出口（模拟站点报限额后换出口）。
    final next = led.plan(
      pool: pool,
      currentProxyId: pool[1].id,
      numberId: 'r4',
      mintUserAgent: mintUa,
      mintModel: mintModel,
      mintChromeMajor: mintChrome,
    );
    eq(next.action, OpenAction.rotate, '新出口要造新身份');
    led.commit(next.proxy.id, 'r4', next.binding);

    final back = led.plan(
      pool: pool,
      currentProxyId: next.proxy.id,
      numberId: 'r2',
      mintUserAgent: mintUa,
      mintModel: mintModel,
      mintChromeMajor: mintChrome,
    );
    eq(back.action, OpenAction.restore, '切回原出口');
    led.commit(back.proxy.id, 'r2', back.binding);

    // 切回去之后 P0 上已经有身份 → 直接复用，不再造新的。
    final again = led.plan(
      pool: pool,
      currentProxyId: pool[0].id,
      numberId: 'r5',
      mintUserAgent: mintUa,
      mintModel: mintModel,
      mintChromeMajor: mintChrome,
    );
    eq(again.action, OpenAction.reuse, 'restore 之后照常复用 P0 的身份');
    eq(again.proxy.id, pool[0].id, '仍落在 P0');
  }

  // ---------- 17. 换出口时优先挑没绑过身份的那条 ----------
  //
  // 以前 _nextProxy 只是 pool[(idx+1) % len]，落到一条已经绑了身份的
  // 出口上又造新身份 —— 同一个 IP 上冒出两台设备，站点眼里最扎眼。
  // 现在两轮：先找没绑过的，其次才复用绑过的。
  {
    final led = IdentityLedger();

    // pool[0] 和 pool[1] 都绑了身份，pool[2] 还空着。
    for (final id in ['x1', 'x2']) {
      final p = led.plan(
        pool: pool,
        currentProxyId: pool[0].id,
        numberId: id,
        mintUserAgent: mintUa,
        mintModel: mintModel,
        mintChromeMajor: mintChrome,
      );
      led.commit(p.proxy.id, id, p.binding);
    }
    for (final id in ['y1', 'y2']) {
      final p = led.plan(
        pool: pool,
        currentProxyId: pool[1].id,
        numberId: id,
        mintUserAgent: mintUa,
        mintModel: mintModel,
        mintChromeMajor: mintChrome,
      );
      led.commit(p.proxy.id, id, p.binding);
    }
    eq(led.usedFor(pool[0].id), 2, 'P0 已看 2 个');
    eq(led.usedFor(pool[1].id), 2, 'P1 已看 2 个');
    eq(led.usedFor(pool[2].id), 0, 'P2 没绑过');

    // 换出口：P1 绑过了，P2 没有 → 必须给 P2。
    final next = led.nextUsableProxy(pool, pool[0].id);
    eq(next?.id, pool[2].id, '优先挑没绑过身份的出口');
  }

  // ---------- 18. 绑过的出口排在没绑过的后面 ----------
  {
    final led = IdentityLedger();
    for (final id in ['m1', 'm2']) {
      final p = led.plan(
        pool: pool,
        currentProxyId: pool[0].id,
        numberId: id,
        mintUserAgent: mintUa,
        mintModel: mintModel,
        mintChromeMajor: mintChrome,
      );
      led.commit(p.proxy.id, id, p.binding);
    }
    // 从 P1 出发换出口：P2 没绑过 → 优先给它，而不是复用 P0 的身份。
    final next = led.nextUsableProxy(pool, pool[1].id);
    eq(next?.id, pool[2].id, '没绑过的排在绑过的前面');
  }

  // ---------- 19. 全绑过时也能换出去，不原地卡死 ----------
  {
    final led = IdentityLedger();
    for (var i = 0; i < pool.length; i++) {
      final p = led.plan(
        pool: pool,
        currentProxyId: pool[i].id,
        numberId: 'f$i',
        mintUserAgent: mintUa,
        mintModel: mintModel,
        mintChromeMajor: mintChrome,
      );
      led.commit(p.proxy.id, 'f$i', p.binding);
    }
    for (var i = 0; i < pool.length; i++) {
      eq(led.usedFor(pool[i].id), 1, 'P$i 各看过 1 个号');
    }
    // 每条出口都绑过身份，当前这条上也有 → 直接复用，不换出口。
    // （本地不限号，所以「都绑过」不再是换出口的理由。）
    final plan = led.plan(
      pool: pool,
      currentProxyId: pool[0].id,
      numberId: 'over',
      mintUserAgent: mintUa,
      mintModel: mintModel,
      mintChromeMajor: mintChrome,
    );
    eq(plan.action, OpenAction.reuse, '当前出口有身份就复用');
    eq(plan.proxy.id, pool[0].id, '不会原地乱跳');
    eq(plan.binding.userAgent, led.forProxy(pool[0].id)!.userAgent, '身份没被顶掉');
  }

  // ---------- 19. 换到绑过的出口时，必须复用它自己的身份 ----------
  //
  // 落在一条已经绑过身份的出口上时，如果再 mint 一个新 UA，commit()
  // 合并时号数取旧的、UA 取新的 —— 同一个 IP 上冒出第二台设备，
  // 账本也不再是「一个代理一个身份」。
  //
  // 实测（identity_drift_test.dart）在改之前确实是串的：
  //   P1 原本自己的 UA : …Pixel 7) …Chrome/131…
  //   P1 现在记的 UA   : …SM-S918B) …Chrome/134…
  {
    final led = IdentityLedger();
    var n = 0;
    String uaA() => 'UA-A-${n}';
    String uaB() => 'UA-B-${n}';

    // P0 先占 2 个号，全部身份是 A。
    for (final id in ['a1', 'a2']) {
      final p = led.plan(
        pool: pool,
        currentProxyId: pool[0].id,
        numberId: id,
        mintUserAgent: uaA,
        mintModel: () => 'MODEL-A',
        mintChromeMajor: () => '131',
      );
      led.commit(p.proxy.id, id, p.binding);
    }

    // P1 先占 1 个号，用 B 身份 —— 这就是它的「自己的身份」。
    final first = led.plan(
      pool: pool,
      currentProxyId: pool[1].id,
      numberId: 'b1',
      mintUserAgent: uaB,
      mintModel: () => 'MODEL-B',
      mintChromeMajor: () => '134',
    );
    led.commit(pool[1].id, 'b1', first.binding);
    final p1Before = led.forProxy(pool[1].id);
    eq(p1Before!.used, 1, 'P1 先用掉 1 个');
    eq(p1Before.userAgent, 'UA-B-0', 'P1 自己的身份是 B');

    // P2 也占 1 个，逼着后面只能落到 P1 上。
    final f2 = led.plan(
      pool: pool,
      currentProxyId: pool[2].id,
      numberId: 'c1',
      mintUserAgent: uaB,
      mintModel: () => 'MODEL-B',
      mintChromeMajor: () => '134',
    );
    led.commit(pool[2].id, 'c1', f2.binding);

    // 三条出口都绑过身份了。换出口时只能落到绑过的，**但挑选本身
    // 绝不铸造新身份** —— 账本里那条绑定必须原样留着，让调用方复用它。
    final next = led.nextUsableProxy(pool, pool[0].id);
    ok(next != null, '全绑过时照样给得出一条');
    ok(next!.id != pool[0].id, '不会给回当前这条');
    final kept = led.forProxy(next.id)!;
    eq(kept.userAgent, 'UA-B-0', '目标出口自己的身份没被顶掉');
    eq(kept.model, 'MODEL-B', '机型没串');
    eq(kept.chromeMajor, '134', 'Chrome 版本没串');
    eq(kept.used, 1, '号数没被挑改动');
  }

  // ---------- 20. 没绑过的出口优先于绑过的出口 ----------
  //
  // 换出口时两边都能用，应该挑没绑过的：在新出口上开新身份，比挤到一条
  // 已经有设备的出口上更干净。
  {
    final led = IdentityLedger();
    // P0 绑了 2 个号、P1 绑了 1 个、P2 完全没绑过。
    for (final id in ['a1', 'a2']) {
      final p = led.plan(
        pool: pool,
        currentProxyId: pool[0].id,
        numberId: id,
        mintUserAgent: mintUa,
        mintModel: mintModel,
        mintChromeMajor: mintChrome,
      );
      led.commit(p.proxy.id, id, p.binding);
    }
    final b = led.plan(
      pool: pool,
      currentProxyId: pool[1].id,
      numberId: 'b1',
      mintUserAgent: mintUa,
      mintModel: mintModel,
      mintChromeMajor: mintChrome,
    );
    led.commit(pool[1].id, 'b1', b.binding);

    final next = led.nextUsableProxy(pool, pool[0].id);
    eq(next?.id, pool[2].id, '优先挑完全没绑过的 P2');
  }

  // ---------- 21. nextUsableProxy 与 plan 用同一条规则 ----------
  //
  // rotateToNext（站点报限额时自动换）走的是这个方法。两条路径不一致
  // 的话，换出口时会落回一条刚被烧掉的出口。
  {
    final led = IdentityLedger();
    final p0 = led.plan(
      pool: pool,
      currentProxyId: pool[0].id,
      numberId: 'a1',
      mintUserAgent: mintUa,
      mintModel: mintModel,
      mintChromeMajor: mintChrome,
    );
    led.commit(p0.proxy.id, 'a1', p0.binding);
    eq(led.usedFor(pool[0].id), 1, 'P0 绑了 1 个号');

    final next = led.nextUsableProxy(pool, pool[0].id);
    ok(next != null, '有可用的下一条');
    ok(next!.id != pool[0].id, '不会返回当前这条');
    eq(next.id, pool[1].id, '取 P1（P1、P2 都没绑过，按顺序给 P1）');

    // 空池返回 null，不抛。
    ok(led.nextUsableProxy(const [], pool[0].id) == null, '空池返回 null');
  }

  // ---------- 22. 只有一条出口时不做任何假装的动作 ----------
  //
  // `plan` 的候选是 `usable.isNotEmpty ? usable : pool`。用户点一次
  // 「全部检测」，只要这批公共代理里只剩一条通的，候选就变成 1。
  // 那种情况下绝不能在这个出口上造第二台设备 —— 同一个 IP 上冒出
  // 第二台，正是 identity_ledger 开头说的最扎眼信号。
  {
    final solo = <ProxyConfig>[pool[0]];
    final led = IdentityLedger();
    String? firstUa;
    for (var j = 0; j < 5; j++) {
      final p = led.plan(
        pool: solo,
        currentProxyId: pool[0].id,
        numberId: 'solo-$j',
        mintUserAgent: mintUa,
        mintModel: mintModel,
        mintChromeMajor: mintChrome,
      );
      firstUa ??= p.binding.userAgent;
      led.commit(p.proxy.id, 'solo-$j', p.binding);
    }
    eq(led.usedFor(pool[0].id), 5, '单条出口记了 5 个号');

    final over = led.plan(
      pool: solo,
      currentProxyId: pool[0].id,
      numberId: 'solo-over',
      mintUserAgent: mintUa,
      mintModel: mintModel,
      mintChromeMajor: mintChrome,
    );
    eq(over.action, OpenAction.reuse, '只有一条出口时只复用');
    eq(over.proxy.id, pool[0].id, '出口确实没变');
    eq(over.binding.userAgent, firstUa, '沿用原身份，不在同一个 IP 上造第二台');
    // 只有一条出口时 nextUsableProxy 也换不出去。
    ok(
      led.nextUsableProxy(solo, pool[0].id)?.id == pool[0].id,
      '单条出口没得换（调用方据此说「加一条代理」）',
    );
  }

  // ---------- 23. 一个号被两个身份看过：归属按**最后一次** ----------
  //
  // 真机踩过：用户切回一个**已经验证过**的号，身份却变成新的了。
  //
  // 根因是原来靠扫 `bindings` 的 `openedNumbers` 猜「谁看过它」，而
  // 一个号可以挂在多个绑定上（A 看过，B 又看了一次）。
  // 猜法取「最早创建」的那个 → 永远拉回 A，而 A 的站点密钥早被清掉，
  // 站点不认，看起来就是「身份变成新的」。
  //
  // 现在 `commit` 每次都写死「这个号归这条出口」，`plan` 直接查表。
  {
    final led = IdentityLedger();

    // A 出口看号 n1。
    final a = led.plan(
      pool: pool,
      currentProxyId: pool[0].id,
      numberId: 'n1',
      mintUserAgent: mintUa,
      mintModel: mintModel,
      mintChromeMajor: mintChrome,
    );
    led.commit(a.proxy.id, 'n1', a.binding);
    eq(led.ownerOf('n1'), pool[0].id, 'n1 先归 A');

    // 站点报限额 → 换到 B 出口（新身份）。
    final b = led.plan(
      pool: pool,
      currentProxyId: pool[1].id,
      numberId: 'n2',
      mintUserAgent: mintUa,
      mintModel: mintModel,
      mintChromeMajor: mintChrome,
    );
    ok(b.rotated, '换到没绑过的出口要造新身份');
    led.commit(b.proxy.id, 'n2', b.binding);

    // 现在把 n1 记到 B 名下（模拟 B 也看过它）
    led.commit(b.proxy.id, 'n1', b.binding);
    eq(led.ownerOf('n1'), b.proxy.id, 'n1 被 B 重新看过之后归 B');

    // 用户切回 n1 —— 必须回到 **B**，不是最早的 A
    final back = led.plan(
      pool: pool,
      currentProxyId: pool[1].id,
      numberId: 'n1',
      mintUserAgent: mintUa,
      mintModel: mintModel,
      mintChromeMajor: mintChrome,
    );
    eq(back.proxy.id, b.proxy.id, '切回 n1 要回到最后看过它的 B');
    // 当前已经在 B 出口、当前绑定就是 B —— 那就什么都不用换。
    // `reuse` 而不是 `restore` 是对的：`restore` 的意思是「从别处切回来」，
    // 而这里压根没离开过。
    ok(!back.rotated, '不能又造新身份');
    ok(!back.restored || back.proxy.id == b.proxy.id, '不能切到别的出口');
    eq(back.binding.createdAtMs, b.binding.createdAtMs, '用的必须是 B 那个身份');
  }

  // ---------- 24. 归属表会持久化 ----------
  {
    final led = IdentityLedger();
    final p = led.plan(
      pool: pool,
      currentProxyId: pool[0].id,
      numberId: 'keep',
      mintUserAgent: mintUa,
      mintModel: mintModel,
      mintChromeMajor: mintChrome,
    );
    led.commit(p.proxy.id, 'keep', p.binding);
    final round = IdentityLedger.fromJson(led.toJson());
    eq(round.ownerOf('keep'), p.proxy.id, '归属表存盘后能读回来');
  }

  // ---------- 21. 空 numberId 不占额度 ----------
  //
  // 换身份那条路调 `commitOpen(proxyId, '', binding)`（表示「只建了身份、
  // 还没看号」）。空串若进了 `openedNumbers`，它会白占一个计数位置 ——
  // `used = openedNumbers.length`，界面上「已看 3 个号」就成了假的。
  {
    final led = IdentityLedger();
    final a = led.plan(
      pool: pool,
      currentProxyId: pool[0].id,
      numberId: 'first',
      mintUserAgent: mintUa,
      mintModel: mintModel,
      mintChromeMajor: mintChrome,
    );
    led.commit(a.proxy.id, 'first', a.binding);
    eq(led.usedFor(a.proxy.id), 1, '看了 1 个号就记 1 个');

    // 连续两次换身份（空 id）
    led.commit(a.proxy.id, '', a.binding);
    led.commit(a.proxy.id, '', a.binding);
    eq(led.usedFor(a.proxy.id), 1, '空 id 换身份不该占计数');

    // 再接着看号，全部落在同一条出口上（本地不限号）。
    for (final n in ['second', 'third']) {
      final r = led.plan(
        pool: pool,
        currentProxyId: pool[0].id,
        numberId: n,
        mintUserAgent: mintUa,
        mintModel: mintModel,
        mintChromeMajor: mintChrome,
      );
      eq(r.proxy.id, pool[0].id, '$n 该用同一个出口');
      led.commit(r.proxy.id, n, r.binding);
    }
    eq(led.usedFor(a.proxy.id), 3, '三个号都记在同一条出口');
  }

  print('\n$pass passed, $fail failed');
  if (fail > 0) throw StateError('$fail failed');
}
