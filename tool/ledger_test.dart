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
    eq(plan.action, OpenAction.reuse, '首次不轮换');
    eq(plan.binding.used, 0, '首次身份未用');
    eq(plan.proxy.id, pool[0].id, '用当前代理');
    led.commit(plan.proxy.id, 'n1', plan.binding);
    eq(led.forProxy(pool[0].id)!.used, 1, '入账 1 个号');
  }

  // ---------- 3. 用满 3 个后轮换 ----------
  {
    final led = IdentityLedger();
    final firstUa = <String>[];
    for (var i = 1; i <= 3; i++) {
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
      eq(plan.action, OpenAction.reuse, '第 $i 个号仍复用');
      led.commit(plan.proxy.id, 'n$i', plan.binding);
    }
    eq(led.forProxy(pool[0].id)!.used, 3, '第一个身份用满 3 个');

    final plan4 = led.plan(
      pool: pool,
      currentProxyId: pool[0].id,
      numberId: 'n4',
      mintUserAgent: mintUa,
      mintModel: mintModel,
      mintChromeMajor: mintChrome,
    );
    eq(plan4.action, OpenAction.rotate, '第 4 个号触发轮换');
    eq(plan4.proxy.id, pool[1].id, '换到下一个代理');
    eq(plan4.binding.used, 0, '新身份从 0 开始');
    ok(plan4.binding.userAgent != firstUa.last, '新身份换了 UA');
    eq(plan4.binding.proxyId, pool[1].id, '新身份绑在新代理上');
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

  // ---------- 5. 轮换会跳过已废掉的代理 ----------
  {
    final led = IdentityLedger(maxPerIdentity: 1);
    // 代理 0 用满
    final a = led.plan(
      pool: pool,
      currentProxyId: pool[0].id,
      numberId: 'x1',
      mintUserAgent: mintUa,
      mintModel: mintModel,
      mintChromeMajor: mintChrome,
    );
    led.commit(a.proxy.id, 'x1', a.binding);
    // 代理 1 也用满
    final b = led.plan(
      pool: pool,
      currentProxyId: pool[1].id,
      numberId: 'y1',
      mintUserAgent: mintUa,
      mintModel: mintModel,
      mintChromeMajor: mintChrome,
    );
    eq(b.action, OpenAction.reuse, '代理 1 首次不轮换');
    led.commit(b.proxy.id, 'y1', b.binding);
    // 现在在代理 1，用满 1 个 → 轮换到下一个（环形）
    final c = led.plan(
      pool: pool,
      currentProxyId: pool[1].id,
      numberId: 'y2',
      mintUserAgent: mintUa,
      mintModel: mintModel,
      mintChromeMajor: mintChrome,
    );
    eq(c.action, OpenAction.rotate, '代理 1 满了要轮换');
    eq(c.proxy.id, pool[2].id, '轮到第三个代理');
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
    eq(back.maxPerIdentity, 3, '往返后上限一致');
    final p4 = back.plan(
      pool: pool,
      currentProxyId: pool[0].id,
      numberId: 'k4',
      mintUserAgent: mintUa,
      mintModel: mintModel,
      mintChromeMajor: mintChrome,
    );
    eq(p4.action, OpenAction.rotate, '往返后仍然会轮换');
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
      eq(led.maxPerIdentity, 3, '坏数据回落默认上限 ($bad)');
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
    // 满了 + 当前判死 → 换到下一个**活的**，不能换回自己。
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
    ok(r.rotated, '用满后轮换');
    ok(r.proxy.id != pool[1].id, '跳过判死的第二条');
    ok(r.proxy.id != pool[0].id, '不换回已经满的自己');
  }

  // ---------- 14. 回头点老号：必须切回原来那条出口 + 原来那个身份 ----------
  //
  // 这是「之前验证过的号码，我重新点进去为何不是之前的 socks5 + 身份」。
  {
    final led = IdentityLedger();

    // 在 pool[0] 上看满 3 个号。
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
    eq(led.forProxy(pool[0].id)!.used, 3, 'P0 已用满 3 个');

    // 第 4 个号 → 额度满，轮换到别的出口 + 新身份。
    final d = led.plan(
      pool: pool,
      currentProxyId: pool[0].id,
      numberId: 'a4',
      mintUserAgent: mintUa,
      mintModel: mintModel,
      mintChromeMajor: mintChrome,
    );
    eq(d.action, OpenAction.rotate, '满 3 个后轮换');
    led.commit(d.proxy.id, 'a4', d.binding);
    // commitOpen 会把当前出口设成轮换后的那条，这里手工模拟。
    final nowCurrent = d.proxy.id;
    ok(nowCurrent != pool[0].id, '轮换后当前出口确实换了');

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

  // ---------- 16. restore 之后下一步仍能正常轮换 ----------
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
    final next = led.plan(
      pool: pool,
      currentProxyId: pool[0].id,
      numberId: 'r4',
      mintUserAgent: mintUa,
      mintModel: mintModel,
      mintChromeMajor: mintChrome,
    );
    eq(next.action, OpenAction.rotate, '满额轮换');
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

    // 切回去之后，P0 还是满的 → 再开新号仍要轮换。
    final again = led.plan(
      pool: pool,
      currentProxyId: pool[0].id,
      numberId: 'r5',
      mintUserAgent: mintUa,
      mintModel: mintModel,
      mintChromeMajor: mintChrome,
    );
    eq(again.action, OpenAction.rotate, 'restore 不影响额度判定');
  }

  // ---------- 17. 轮转必须跳过「已经满」的出口 ----------
  //
  // 界面在满的代理上写着「下次会跳过」，之前那是句谎话：_nextProxy 只是
  // pool[(idx+1) % len]，压根不看下一条满没满。真轮到它时照样被选中，
  // 在那个烧掉的出口上再造一个新身份 —— 白耗一次轮转，而且站点早盯上
  // 这个 IP 了，很容易直接弹 CF 验证。
  {
    final led = IdentityLedger();

    // pool[0] 和 pool[1] 都用满 3 个，pool[2] 空着。
    for (final id in ['x1', 'x2', 'x3']) {
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
    for (final id in ['y1', 'y2', 'y3']) {
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
    eq(led.usedFor(pool[0].id), 3, 'P0 满');
    eq(led.usedFor(pool[1].id), 3, 'P1 满');
    eq(led.usedFor(pool[2].id), 0, 'P2 空');

    // 站在 P0 上要开新号：下一条 P1 也是满的 → 必须跳到 P2。
    final plan = led.plan(
      pool: pool,
      currentProxyId: pool[0].id,
      numberId: 'x9',
      mintUserAgent: mintUa,
      mintModel: mintModel,
      mintChromeMajor: mintChrome,
    );
    eq(plan.action, OpenAction.rotate, 'P0 满了要轮转');
    eq(plan.proxy.id, pool[2].id, '跳过同样满的 P1，直接到 P2');
    ok(!plan.proxy.id.endsWith('2.2.2.2:1080'), '没有落到满的 P1 上');
  }

  // ---------- 18. 满的那条留在原地时不会被当成候选 ----------
  {
    final led = IdentityLedger();
    for (final id in ['m1', 'm2', 'm3']) {
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
    // 连续轮转三次，每一次都必须落在「没满」的出口上。
    var cur = pool[0].id;
    final seen = <String>{};
    for (var i = 0; i < 3; i++) {
      final p = led.plan(
        pool: pool,
        currentProxyId: cur,
        numberId: 'k$i',
        mintUserAgent: mintUa,
        mintModel: mintModel,
        mintChromeMajor: mintChrome,
      );
      ok(
        led.usedFor(p.proxy.id) < IdentityLedger.slotsPerIdentity ||
            p.action == OpenAction.reuse,
        '第 ${i + 1} 次轮转落在还有余额的出口上',
      );
      led.commit(p.proxy.id, 'k$i', p.binding);
      cur = p.proxy.id;
      seen.add(p.proxy.id);
    }
    ok(seen.contains(pool[1].id) || seen.contains(pool[2].id), '轮转真的往前走');
  }

  // ---------- 19. 全满时退回下一条，不原地卡死 ----------
  {
    final led = IdentityLedger();
    for (var i = 0; i < pool.length; i++) {
      for (var j = 0; j < IdentityLedger.slotsPerIdentity; j++) {
        final p = led.plan(
          pool: pool,
          currentProxyId: pool[i].id,
          numberId: 'f$i-$j',
          mintUserAgent: mintUa,
          mintModel: mintModel,
          mintChromeMajor: mintChrome,
        );
        led.commit(p.proxy.id, 'f$i-$j', p.binding);
      }
    }
    for (var i = 0; i < pool.length; i++) {
      eq(led.usedFor(pool[i].id), 3, 'P$i 满');
    }
    final plan = led.plan(
      pool: pool,
      currentProxyId: pool[0].id,
      numberId: 'over',
      mintUserAgent: mintUa,
      mintModel: mintModel,
      mintChromeMajor: mintChrome,
    );
    eq(plan.action, OpenAction.rotate, '全满仍返回轮转');
    ok(plan.proxy.id != pool[0].id, '不会原地停在当前这条');
  }

  // ---------- 19. 轮换到「用了一半」的出口时，必须复用它自己的身份 ----------
  //
  // _nextProxy 优先挑没绑过的出口，但池子用旧之后会落到「绑过、还有
  // 余额」的出口上。那种出口上已经有一台设备了，如果再 mint 一个新
  // UA，commit() 合并时号数取旧的、UA 取新的 —— 同一个 IP 上冒出第二
  // 台设备，账本也不再是「一个代理一个身份」。
  //
  // 实测（identity_drift_test.dart）在改之前确实是串的：
  //   P1 原本自己的 UA : …Pixel 7) …Chrome/131…
  //   P1 现在记的 UA   : …SM-S918B) …Chrome/134…
  {
    final led = IdentityLedger();
    var n = 0;
    String uaA() => 'UA-A-${n}';
    String uaB() => 'UA-B-${n}';

    // P0 用满 3 个，全部身份是 A。
    for (final id in ['a1', 'a2', 'a3']) {
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

    // 站在 P0 上开新号：P1 和 P2 都绑过且没满 → 落到其中一条，
    // 但**绝不能**把那条的身份换掉。
    final p = led.plan(
      pool: pool,
      currentProxyId: pool[0].id,
      numberId: 'a4',
      mintUserAgent: uaA,
      mintModel: () => 'MODEL-A',
      mintChromeMajor: () => '131',
    );
    eq(p.action, OpenAction.rotate, 'P0 满了要轮转');
    ok(p.proxy.id != pool[0].id, '没落在满的 P0 上');
    eq(p.binding.userAgent, 'UA-B-0', '复用的是目标出口自己的身份，不是现造的 A');

    led.commit(p.proxy.id, 'a4', p.binding);
    final after = led.forProxy(p.proxy.id)!;
    eq(after.userAgent, 'UA-B-0', '落账后身份没被顶掉');
    eq(after.model, 'MODEL-B', '机型也没串');
    eq(after.chromeMajor, '134', 'Chrome 版本没串');
    eq(after.used, 2, '号数照常往上加');
  }

  // ---------- 20. 没绑过的出口优先于「用了一半」的出口 ----------
  //
  // 两边都能用的时候应该挑没绑过的：在新出口上开新身份，比挤到一条
  // 已经有设备的出口上更干净。
  {
    final led = IdentityLedger();
    // P0 满、P1 占 1 个、P2 完全没绑过。
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

    final p = led.plan(
      pool: pool,
      currentProxyId: pool[0].id,
      numberId: 'a4',
      mintUserAgent: mintUa,
      mintModel: mintModel,
      mintChromeMajor: mintChrome,
    );
    eq(p.proxy.id, pool[2].id, '优先挑完全没绑过的 P2');
  }

  // ---------- 21. nextUsableProxy 与 plan 用同一条规则 ----------
  //
  // rotateToNext（站点报限额时自动换）走的是这个方法。两条路径不一致
  // 的话，恰恰在最需要跳过的场合（出口刚被限额烧掉）又会落回一条
  // 用满的出口。
  {
    final led = IdentityLedger();
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
    }
    eq(led.usedFor(pool[0].id), 3, 'P0 满');

    final next = led.nextUsableProxy(pool, pool[0].id);
    ok(next != null, '有可用的下一条');
    ok(next!.id != pool[0].id, '不会返回满的 P0');
    eq(next.id, pool[1].id, '跳过满的 P0，取 P1');

    // 空池返回 null，不抛。
    ok(led.nextUsableProxy(const [], pool[0].id) == null, '空池返回 null');
  }

  print('\n$pass passed, $fail failed');
  if (fail > 0) throw StateError('$fail failed');
}
