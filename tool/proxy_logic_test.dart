import 'dart:io';

import 'package:fus_inbox/core/proxy/proxy_config.dart';

int pass = 0, fail = 0;
void ok(bool c, String label) {
  if (c) {
    pass++;
  } else {
    fail++;
    print('FAIL  $label');
  }
}

void eq(Object? a, Object? b, String label) {
  if (a == b) {
    pass++;
  } else {
    fail++;
    print('FAIL  $label  got=$a want=$b');
  }
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
  ok(
    ProxyConfig.fromJson({'host': 'x', 'port': 70000}) == null,
    'bad port null',
  );
  eq(
    ProxyConfig.fromJson({'host': 'x'})!.scheme,
    ProxyScheme.socks5,
    'missing scheme default',
  );

  print('\n$pass passed, $fail failed');
  if (fail > 0) exit(1);
}
