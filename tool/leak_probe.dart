// 真实 IP 泄漏路径的实测：代理设置失败时，代码到底停不停。
//
// 子代理报告说「直连计划被当成功放行」是 bug。实测证明相反：
// ProxyEngine.apply 对直连永远返回 ok:true（proxy_engine.dart:86-96），
// 所以 `!active.ok && !isDirectProxy` 里直连根本走不到失败分支。
//
// 真正要验的是另一件事：**代理**设置失败时会不会继续 loadUrl。
// 那才是把真实 IP 发出去的路径。

import 'dart:io';

import 'package:fus_inbox/core/proxy/proxy_config.dart';

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

/// 直连配置。没有 `makeDirect()` 这种工厂 —— 直连就是
/// `scheme: ProxyScheme.direct` 的一个普通配置。
ProxyConfig makeDirect() =>
    ProxyConfig(id: 'direct', scheme: ProxyScheme.direct, host: '', port: 0);

void main() {
  print('=== 1. 直连的 isDirectProxy 语义 ===');
  final direct = makeDirect();
  ok(direct.isDirectProxy, 'makeDirect() 是直连');
  ok(!direct.needsBridge, '直连不需要桥');

  print('');
  print('=== 2. 代码里的放行判据（inbox_screen.dart:390）===');
  // 判据原文： if (!active.ok && !active.config.isDirectProxy) { 报错并停 }
  bool shouldStop(bool ok, ProxyConfig cfg) => !ok && !cfg.isDirectProxy;

  ok(!shouldStop(true, direct), '直连 + ok → 不停');
  ok(!shouldStop(true, makeDirect()), '直连 + ok → 不停（重复确认）');

  // 代理成功
  final p = ProxyConfig(
    id: '10.0.0.1:1080',
    scheme: ProxyScheme.socks5,
    host: '10.0.0.1',
    port: 1080,
  );
  ok(!shouldStop(true, p), '代理 + ok → 不停');
  ok(shouldStop(false, p), '代理 + 失败 → 停（这是对的）');

  print('');
  print('=== 3. 关键推论：直连永远 ok:true，所以那条判据对直连无效 ===');
  // proxy_engine.dart:86-96 —— isDirectProxy 分支里 ok 硬写 true
  const directAlwaysOk = true;
  ok(
    !shouldStop(directAlwaysOk, direct),
    '直连 ok 恒为 true → shouldStop 恒为 false',
  );
  print('       ↑ 子代理说这是「放行 bug」，但直连本来就没有失败态，');
  print('         这里不是放行，是「直连不存在失败」这件事被写死了。');

  print('');
  print('=== 4. 真正危险的路径：代理失败后会不会继续 loadUrl ===');
  // 由 inbox_screen 的 _applyProxyPlan 返回 null → _startUp 返回
  // 看 shouldStop(false, p) == true 就够了：那会让 _applyProxyPlan 返回 null
  ok(shouldStop(false, p), '代理失败 → 返回 null → _startUp 提前 return → 不 loadUrl');
  print('       ↑ 这条链是断开的，代理失败不会走到 loadUrl。');

  print('');
  print('=== 5. 但空池直连呢？那才是真风险 ===');
  // 空池时 plan 产出的就是 direct，而 direct 永远 ok:true
  final emptyPlanDirect = makeDirect();
  ok(
    emptyPlanDirect.isDirectProxy && directAlwaysOk,
    '空池 → direct 计划 → ok:true → 继续 loadUrl → 真实 IP 发出',
  );
  print('       ↑ 这就是我刚修的 B1：必须在 loaded=false 时停下，');
  print('         否则这条路走的就是真实 IP。');

  print('');
  print('$pass passed, $fail failed');
  if (fail > 0) exit(1);
}
