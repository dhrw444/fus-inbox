import 'package:fus_inbox/core/proxy/proxy_config.dart';
import 'package:fus_inbox/core/proxy/proxy_pool.dart';

int pass = 0, fail = 0;
void ok(bool c, String label) {
  if (c) { pass++; } else { fail++; print('FAIL  $label'); }
}
void eq(Object? a, Object? b, String label) {
  if (a == b) { pass++; } else { fail++; print('FAIL  $label  got=$a want=$b'); }
}

void main() {
  // ---------- 解析 ----------
  var p = parseProxyLine('socks5://1.2.3.4:1080')!;
  eq(p.scheme, ProxyScheme.socks5, 'scheme socks5');
  eq(p.host, '1.2.3.4', 'host');
  eq(p.port, 1080, 'port');
  eq(p.id, 'socks5://1.2.3.4:1080', 'id');

  p = parseProxyLine('socks5h://u:p%40ss@host.example:9050')!;
  eq(p.scheme, ProxyScheme.socks5h, 'socks5h scheme');
  eq(p.username, 'u', 'user');
  eq(p.password, 'p@ss', 'pass decoded');
  eq(p.host, 'host.example', 'hostname');
  eq(p.port, 9050, 'port 9050');
  ok(p.needsBridge, 'socks5h needsBridge');
  eq(p.masked, 'socks5h://u:••••@host.example:9050', 'masked hides pw');

  p = parseProxyLine('http://a:b@10.0.0.1:8080')!;
  eq(p.scheme, ProxyScheme.http, 'http scheme');
  ok(!p.needsBridge, 'http no bridge');

  // 省略协议 → socks5
  p = parseProxyLine('9.9.9.9:1080')!;
  eq(p.scheme, ProxyScheme.socks5, 'default scheme socks5');
  eq(p.port, 1080, 'explicit port');

  // 省略端口 → 协议默认
  p = parseProxyLine('socks5://9.9.9.9')!;
  eq(p.port, 1080, 'default socks port');
  p = parseProxyLine('https://9.9.9.9')!;
  eq(p.port, 443, 'default https port');
  p = parseProxyLine('http://9.9.9.9')!;
  eq(p.port, 8080, 'default http port');

  // 尾部路径要丢掉
  p = parseProxyLine('socks5://1.2.3.4:1080/some/path?x=1')!;
  eq(p.host, '1.2.3.4', 'strip path host');
  eq(p.port, 1080, 'strip path port');

  // 前后空格 / 粘整行
  p = parseProxyLine('  1.2.3.4:1080  备注文字  ')!;
  eq(p.host, '1.2.3.4', 'trim + take first token');

  // IPv6
  p = parseProxyLine('socks5://[::1]:1080')!;
  eq(p.host, '::1', 'ipv6 host');
  eq(p.port, 1080, 'ipv6 port');

  // 非法
  ok(parseProxyLine('') == null, 'empty null');
  ok(parseProxyLine('   ') == null, 'spaces null');
  ok(parseProxyLine('socks5://:1080') == null, 'no host null');
  ok(parseProxyLine('socks5://1.2.3.4:0') == null, 'port 0 null');
  ok(parseProxyLine('socks5://1.2.3.4:99999') == null, 'port range null');

  // id 不含密码
  final withPw = parseProxyLine('socks5://u:pw1@1.1.1.1:1080')!;
  final otherPw = parseProxyLine('socks5://u:pw2@1.1.1.1:1080')!;
  eq(withPw.id, otherPw.id, 'id stable across password change');

  // ---------- JSON 往返 ----------
  final rt = ProxyConfig.fromJson(withPw.toJson())!;
  eq(rt.host, '1.1.1.1', 'roundtrip host');
  eq(rt.password, 'pw1', 'roundtrip password');
  eq(rt.id, withPw.id, 'roundtrip id');
  ok(ProxyConfig.fromJson({'host': ''}) == null, 'bad json null');
  ok(ProxyConfig.fromJson({'host': 'x', 'port': 70000}) == null, 'bad port null');
  eq(ProxyConfig.fromJson({'host': 'x'})!.scheme, ProxyScheme.socks5, 'missing scheme default');

  // ---------- 轮换 ----------
  ProxySlot slot(String id) => ProxySlot(
        proxy: parseProxyLine('socks5://$id:1080')!,
        identity: {'userAgent': 'ua-$id'},
      );

  final engine = ProxyRotationEngine(
    slots: [slot('1.1.1.1'), slot('2.2.2.2'), slot('3.3.3.3')],
  );

  var d = engine.beforeOpen();
  eq(d.reason, RotationReason.quotaExhausted, 'first open picks proxy');
  eq(d.next!.proxy.host, '1.1.1.1', 'first proxy = 1.1.1.1');

  d = engine.beforeOpen();
  eq(d.reason, RotationReason.keep, 'second open keeps proxy');
  eq(engine.currentId, 'socks5://1.1.1.1:1080', 'still 1.1.1.1');

  engine.markOpened();
  engine.markOpened();
  eq(engine.used, 2, 'used 2');
  d = engine.beforeOpen();
  eq(d.reason, RotationReason.keep, 'third open still keep');
  engine.markOpened();
  eq(engine.used, 3, 'used 3');

  // 第 4 个 → 换代理
  d = engine.beforeOpen();
  eq(d.reason, RotationReason.quotaExhausted, '4th rotates');
  eq(d.next!.proxy.host, '2.2.2.2', 'rotated to 2.2.2.2');
  eq(engine.used, 0, 'counter reset');

  // 站点拒绝 → 立刻换，不等 3 个
  d = engine.beforeOpen(reason: RotationReason.rejected);
  eq(d.reason, RotationReason.rejected, 'rejected rotates');
  eq(d.next!.proxy.host, '3.3.3.3', 'rejected → 3.3.3.3');

  // 循环回到第一条
  d = engine.beforeOpen(reason: RotationReason.rejected);
  eq(d.next!.proxy.host, '1.1.1.1', 'wraps around to 1.1.1.1');

  // 单条代理：用满也不报错，回到自己
  final solo = ProxyRotationEngine(slots: [slot('9.9.9.9')], perProxyLimit: 1);
  solo.beforeOpen();
  solo.markOpened();
  d = solo.beforeOpen();
  eq(d.reason, RotationReason.quotaExhausted, 'solo rotates');
  eq(d.next!.proxy.host, '9.9.9.9', 'solo reuses itself');
  eq(solo.used, 0, 'solo counter reset');

  // 无代理
  final empty = ProxyRotationEngine(slots: []);
  d = empty.beforeOpen();
  eq(d.reason, RotationReason.noProxy, 'empty → noProxy');
  ok(d.next == null, 'empty next null');
  ok(d.message.isNotEmpty, 'empty has message');

  // 恢复进度
  final restored = ProxyRotationEngine(
    slots: [slot('1.1.1.1'), slot('2.2.2.2')],
  )..restore(currentId: 'socks5://1.1.1.1:1080', used: 2);
  eq(restored.used, 2, 'restore used');
  d = restored.beforeOpen();
  eq(d.reason, RotationReason.keep, 'restore keeps until full');
  restored.markOpened();
  d = restored.beforeOpen();
  eq(d.next!.proxy.host, '2.2.2.2', 'restore then rotate');
  // 恢复一个已删除的代理 → 忽略
  restored.restore(currentId: 'socks5://7.7.7.7:1080', used: 1);
  ok(restored.currentId != 'socks5://7.7.7.7:1080', 'restore ignores unknown proxy');

  // 上限可调
  final five = ProxyRotationEngine(
    slots: [slot('1.1.1.1'), slot('2.2.2.2')],
    perProxyLimit: 5,
  );
  five.beforeOpen();
  for (var i = 0; i < 4; i++) { five.markOpened(); }
  eq(five.beforeOpen().reason, RotationReason.keep, 'limit 5 keeps at 4');

  // ---------- 身份缓存 ----------
  final cache = IdentityCache();
  ok(!cache.has('a'), 'empty cache');
  cache.put('a', {'userAgent': 'UA-A', 'chromeMajor': '141'});
  cache.put('b', {'userAgent': 'UA-B'});
  eq(cache.get('a')!['userAgent'], 'UA-A', 'cache get');

  final encoded = cache.encode();
  final decoded = IdentityCache.decode(encoded);
  eq(decoded.get('a')!['userAgent'], 'UA-A', 'cache survives encode/decode');
  eq(decoded.get('b')!['userAgent'], 'UA-B', 'second identity kept');

  decoded.put('a', {'userAgent': 'UA-A2'});
  eq(decoded.get('a')!['userAgent'], 'UA-A2', 'overwrite identity');

  decoded.pruneTo(['a']);
  ok(decoded.has('a'), 'prune keeps live');
  ok(!decoded.has('b'), 'prune drops dead');

  ok(IdentityCache.decode(null).raw.isEmpty, 'decode null → empty');
  ok(IdentityCache.decode('').raw.isEmpty, 'decode empty → empty');
  ok(IdentityCache.decode('{bad').raw.isEmpty, 'decode garbage → empty');
  ok(IdentityCache.decode('[1,2]').raw.isEmpty, 'decode non-map → empty');

  print('\n$pass passed, $fail failed');
}
