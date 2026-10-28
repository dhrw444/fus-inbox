// 验证 findProxy 的两种兜底行为。
//
// 为什么要先验这个：号码目录要改成走桥，就必须保证
// 「桥没起来」时请求**失败**，而不是静默回退直连 ——
// 静默回退正是现在的 bug（真实 IP 泄漏且没有任何报错）。
//
// 两个候选兜底：
//   a) findProxy 回调里直接 throw
//   b) 返回一个必然连不上的 PROXY（如 127.0.0.1:1）
//
// 哪个真的会抛，就用哪个；两个都抛就选 a（错误信息更清楚）。

import 'dart:io';

int pass = 0;
int fail = 0;

void ok(bool c, String name, [String extra = '']) {
  if (c) {
    pass++;
    print('  ok   $name  $extra');
  } else {
    fail++;
    print('  FAIL $name  $extra');
  }
}

Future<void> main() async {
  // 目标：一个真的 HTTP 服务，确保「能连上」时确实拿得到响应
  final target = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = target.port;
  target.listen((s) async {
    try {
      s.write(
        'HTTP/1.1 200 OK\r\nContent-Length: 2\r\n'
        'Connection: close\r\n\r\nOK',
      );
      await s.flush();
      await s.close();
    } catch (_) {
      s.destroy();
    }
  });
  final url = Uri.parse('http://127.0.0.1:$port/numbers/');

  print('=== a) findProxy 里 throw ===');
  final a = HttpClient()
    ..findProxy = ((Uri u) => throw StateError('没有可用出口：拒绝直连'))
    ..connectionTimeout = const Duration(seconds: 3);
  String aErr = '';
  try {
    final req = await a.getUrl(url);
    final res = await req.close();
    await res.drain<void>();
  } catch (e) {
    aErr = e.toString();
  }
  ok(aErr.isNotEmpty, 'a 抛出了异常', '(${aErr.split('\n').first})');
  ok(aErr.contains('拒绝直连'), 'a 的异常带上了原因', '');
  a.close(force: true);

  print('');
  print('=== b) findProxy 返回连不上的 PROXY ===');
  final b = HttpClient()
    ..findProxy = ((Uri u) => 'PROXY 127.0.0.1:1')
    ..connectionTimeout = const Duration(seconds: 3);
  String bErr = '';
  try {
    final req = await b.getUrl(url);
    final res = await req.close();
    await res.drain<void>();
  } catch (e) {
    bErr = e.toString();
  }
  ok(bErr.isNotEmpty, 'b 也抛异常', '(${bErr.split('\n').first})');
  b.close(force: true);

  print('');
  print('=== c) 对照组：DIRECT 能正常拿到响应 ===');
  final c = HttpClient()
    ..findProxy = ((Uri u) => 'DIRECT')
    ..connectionTimeout = const Duration(seconds: 3);
  var got = '';
  try {
    final req = await c.getUrl(url);
    final res = await req.close();
    got = await res.transform(const SystemEncoding().decoder).join();
  } catch (e) {
    got = 'ERR $e';
  }
  ok(got.contains('OK'), 'DIRECT 拿到响应', '(len=${got.length})');
  c.close(force: true);

  await target.close();

  print('');
  print('结论：');
  print('  a 可用 → 用 throw，错误信息能直达用户');
  print('  b 可用 → 用 throw，两者等价但 b 信息少');
  print('');
  print('$pass passed, $fail failed');
  // 只在**失败**时退出：这个文件既会被单独跑，也会被 tool/gate.dart
  // import 进来当一段。无条件 exit 会把整条 gate 一起杀掉。
  // （socket 订阅没全部取消时 VM 不会自己结束 —— 单独跑起来觉得"卡住"，
  //  那就是这个原因，不是失败。）
  if (fail > 0) exit(1);
}
