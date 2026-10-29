/// 版本检测的纯逻辑测试。
///
/// 这个判据真机上错过一次：114 的机器上验证永远转不完，而界面上一句话
/// 都没有，用户只能一直重试。所以「读哪个版本号」和「多低算低」必须钉死。
library;

import 'package:fus_inbox/features/inbox/domain/webview_version_check.dart';

int _ok = 0;
int _fail = 0;

void check(String label, bool cond) {
  if (cond) {
    _ok++;
  } else {
    _fail++;
    print('FAIL $label');
  }
}

void main() {
  // ── 真实的安卓 WebView UA（版本 114，就是真机上那台）──
  const ua114 =
      'Mozilla/5.0 (Linux; Android 14; SM-S918B) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Version/4.0 Chrome/114.0.5735.196 Mobile Safari/537.36';
  final v114 = checkWebViewVersion(ua114);
  check('114 解析出主版本', v114.major == 114);
  check('114 显示完整四段', v114.display == '114.0.5735.196');
  check('114 判为过低', v114.tooLow);
  check('114 不是 unknown', !v114.unknown);

  // ── 判据不能读成 Version/4.0（那是 WebView 的恒值，不是内核版本）──
  check('没把 Version/4.0 当成版本', v114.major != 4);

  // ── 120 正好是阈值，算够 ──
  const ua120 =
      'Mozilla/5.0 (Linux; Android 14; SM-S918B) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Version/4.0 Chrome/120.0.6099.230 Mobile Safari/537.36';
  final v120 = checkWebViewVersion(ua120);
  check('120 不算过低', !v120.tooLow);
  check('120 主版本正确', v120.major == 120);

  // ── 高于阈值 ──
  const ua141 =
      'Mozilla/5.0 (Linux; Android 14; SM-S918B) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/141.0.0.0 Mobile Safari/537.36';
  final v141 = checkWebViewVersion(ua141);
  check('141 不算过低', !v141.tooLow);
  check('141 主版本正确', v141.major == 141);

  // ── 解析不出来：沉默，既不报警也不说够用 ──
  check('空串是 unknown', checkWebViewVersion('').unknown);
  check('空串不判过低', !checkWebViewVersion('').tooLow);
  check(
    '没有 Chrome 段的 UA 是 unknown',
    checkWebViewVersion(
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
    ).unknown,
  );

  // ── 只有三段（少见但存在）：不该解析成功 ──
  check(
    '三段版本号视为解析失败',
    checkWebViewVersion('Chrome/114.0.5735 Safari/537.36').unknown,
  );

  print('$_ok 通过 / $_fail 失败');
  if (_fail > 0) throw StateError('webview_version_check: $_fail 项失败');
}
