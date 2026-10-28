// 浏览器身份的**平台维度**：UA / client hints / 落盘三处必须一致。
//
// 修的问题：以前 `Sec-CH-UA-Platform` 写死 `"Android"`，UA 也写死
// `(Linux; Android …) Mobile Safari/537.36`。安卓上没问题，Windows 上就是
// 自相矛盾的三件套 —— 引擎是 WebView2（桌面 Chromium），UA 说自己是安卓
// 手机，hints 也说 "Android"。而 WebView2 的真实默认 UA 里还挂着
// `Edg/…`（它是 Edge 内核），和安卓那套 `; wv` / `Version/4.0` 是同一类
// 招牌，都得剥。
//
// 纯逻辑，不碰网络。
import 'package:fus_inbox/core/webview/browser_identity.dart';

int pass = 0;
int fail = 0;

void ok(bool cond, String name, [String extra = '']) {
  if (cond) {
    pass++;
    print('  ok   $name  $extra');
  } else {
    fail++;
    print('  FAIL $name  $extra');
  }
}

void eq(Object? got, Object? want, String name) =>
    ok(got == want, '$name  (got=$got want=$want)');

/// 安卓 WebView 报的默认 UA（带 WebView 招牌）。
const androidWv =
    'Mozilla/5.0 (Linux; Android 14; SM-S918B Build/UP1A.231005.007; wv) '
    'AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 '
    'Chrome/141.0.7390.122 Mobile Safari/537.36';

/// Windows 上 WebView2 报的默认 UA（带 Edge 内核招牌）。
const windowsWv =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36 Edg/141.0.0.0';

void main() {
  print('=== 1. 平台嗅探 ===');
  {
    ok(isDesktopUserAgent(windowsWv), 'Windows UA 认得出');
    ok(!isDesktopUserAgent(androidWv), '安卓 UA 不误判');
  }

  print('');
  print('=== 2. 安卓：和以前逐字一致（不能被我改坏）===');
  {
    final id = parseWebViewUserAgent(androidWv);
    eq(id.platform, BrowserIdentity.platformAndroid, '平台 = Android');
    ok(id.isMobile, '是 mobile');
    eq(id.model, 'SM-S918B', '机型从 UA 里抠出来了');
    eq(id.platformVersion, '14', 'Android 版本');
    eq(id.chromeMajor, '141', 'Chrome 大版本');
    ok(!id.userAgent.contains('wv'), '剥掉 ; wv');
    ok(!id.userAgent.contains('Version/4.0'), '剥掉 Version/4.0');
    ok(!id.userAgent.contains('Build/'), '剥掉 Build/...');
    ok(id.userAgent.contains('Mobile Safari/537.36'), '保留 Mobile 段');
  }

  print('');
  print('=== 3. 【核心】Windows：桌面身份，不是安卓 ===');
  {
    final id = parseWebViewUserAgent(windowsWv);
    eq(id.platform, BrowserIdentity.platformWindows, '平台 = Windows');
    ok(!id.isMobile, '不是 mobile');
    eq(id.model, '', '桌面没有机型串');
    eq(id.platformVersion, '10.0.0', '平台版本是完整四段式');
    ok(!id.userAgent.contains('Edg/'), '剥掉 Edge 内核招牌');
    ok(!id.userAgent.contains('Android'), 'UA 里不能出现 Android');
    ok(id.userAgent.contains('Windows NT 10.0'), '保留 Windows NT');
    ok(id.userAgent.contains('Chrome/141'), '保留 Chrome 版本');
    eq(
      id.userAgent,
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36',
      '重建后的桌面 UA 逐字正确',
    );
  }

  print('');
  print('=== 4. client hints 跟着平台走 ===');
  {
    final a = parseWebViewUserAgent(androidWv);
    final w = parseWebViewUserAgent(windowsWv);
    eq(a.secChUaPlatform, '"Android"', '安卓平台头');
    eq(w.secChUaPlatform, '"Windows"', 'Windows 平台头');
    // 这两条是这次修的核心：平台版本不能无条件补 `.0.0`。
    eq(a.secChUaPlatformVersion, '"14.0.0"', '安卓补成三段');
    eq(w.secChUaPlatformVersion, '"10.0.0"', 'Windows 原样，不要变成 10.0.0.0.0');
    ok(!w.secChUaPlatformVersion.contains('10.0.0.0.0'), '没有那个不存在的版本号');
    eq(a.secChUa, w.secChUa, '品牌串和大版本无关平台（都跟 chromeMajor 走）');
  }

  print('');
  print('=== 5. 落盘往返保住平台 ===');
  {
    for (final raw in [androidWv, windowsWv]) {
      final id = parseWebViewUserAgent(raw);
      final back = identityFromJson(identityToJson(id));
      ok(back != null, '能还原（${id.platform}）');
      eq(back!.platform, id.platform, '平台保住了（${id.platform}）');
      eq(back.isMobile, id.isMobile, 'isMobile 保住了');
      eq(back.userAgent, id.userAgent, 'UA 逐字保住');
      eq(back.platformVersion, id.platformVersion, '平台版本保住');
    }
  }

  print('');
  print('=== 6. 【兼容】老记录没有 os 键 → 当安卓 ===');
  {
    final old = {
      'ua': androidWv,
      'major': '141',
      'model': 'SM-S918B',
      'platform': '14',
      'mobile': true,
    };
    final back = identityFromJson(old);
    ok(back != null, '老记录仍能读');
    eq(back!.platform, BrowserIdentity.platformAndroid, '缺 os → 安卓');
  }

  print('');
  print('=== 7. 【兼容】Windows 身份 model 为空也要能存能读 ===');
  {
    // 以前 `identityFromJson` 有一条 `model.isEmpty → null`，会把桌面身份
    // 整个判成坏数据、回落成安卓兜底 —— 那正好把这个 bug 又装回去。
    final w = parseWebViewUserAgent(windowsWv);
    eq(w.model, '', '前提：桌面 model 确实为空');
    final back = identityFromJson(identityToJson(w));
    ok(back != null, 'model 为空**不该**判成坏数据');
    eq(back!.platform, 'Windows', '读回来还是 Windows');
  }

  print('');
  print('=== 8. 坏数据仍然要被挡住 ===');
  {
    eq(identityFromJson(null), null, 'null → null');
    eq(identityFromJson('不是 map'), null, '字符串 → null');
    eq(identityFromJson({'major': '141'}), null, '缺 ua → null');
    eq(identityFromJson({'ua': windowsWv}), null, '缺 major → null');
    eq(
      identityFromJson({'ua': '', 'major': '141', 'model': ''}),
      null,
      '空 ua → null',
    );
  }

  print('');
  print('=== 9. 切回账本身份时，平台从 UA 现解 ===');
  {
    // applyBoundIdentity 是写全局状态的；这里只验「解出来的平台对不对」，
    // 因为它内部用的就是同一套判据。
    ok(isDesktopUserAgent(windowsWv), '桌面 UA → 按桌面还原');
    ok(!isDesktopUserAgent(androidWv), '安卓 UA → 按安卓还原');
  }

  print('');
  print('$pass passed, $fail failed');
  if (fail > 0) throw StateError('$fail failed');
}
