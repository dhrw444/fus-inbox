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

  print('\n$pass passed, $fail failed');
  if (fail > 0) throw StateError('$fail failed');
}
