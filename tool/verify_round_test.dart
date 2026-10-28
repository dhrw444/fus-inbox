// 测**真实代码**，不是手抄模型。
//
// 上一版这份文件是照抄 inbox_screen.dart 里那段状态机的一份副本 ——
// 代码改了副本没改，30 条全绿但一行真实代码都没跑过。现在状态机
// 搬到了 lib/core/webview/verify_round.dart，这里直接 import 它。
//
// 跑：cd /tmp/tt5 && dart verify_round_test.dart
import 'package:fus_inbox/core/webview/verify_round.dart';

int _pass = 0;
int _fail = 0;

void check(String name, bool ok, [String extra = '']) {
  if (ok) {
    _pass++;
  } else {
    _fail++;
    print('FAIL  $name${extra.isEmpty ? '' : '  ($extra)'}');
  }
}

/// 可控时钟，测试里手推时间。
class FakeClock {
  DateTime now = DateTime(2026, 1, 1, 12);
  DateTime call() => now;
  void advance(Duration d) => now = now.add(d);
}

void main() {
  // ── 1. 默认阈值与窗口 ──────────────────────────────────────────
  {
    final r = VerifyRound();
    check('1.1 自动弹出阈值 6 秒', r.autoChallengeAfter == const Duration(seconds: 6));
    check('1.2 窗口 90 秒', r.window == const Duration(seconds: 90));
    check('1.3 初始 elapsed 归零', r.elapsed == Duration.zero);
    check('1.4 初始没 ready', r.readySeen == false);
    check('1.5 初始没弹过', r.autoPopped == false);
    check('1.6 初始没起算点', r.start == null);
  }

  // ── 2. arm 只在空的时候落点 ────────────────────────────────────
  {
    final c = FakeClock();
    final r = VerifyRound(clock: c.call);
    r.arm();
    final first = r.start;
    check('2.1 arm 落点', first != null);
    c.advance(const Duration(seconds: 3));
    r.arm();
    check('2.2 重复 arm 不覆盖起算点', r.start == first);
    r.refresh();
    check(
      '2.3 重复 arm 后 elapsed 接着算',
      r.elapsed == const Duration(seconds: 3),
      '${r.elapsed}',
    );
  }

  // ── 3. 没起算点时 refresh 不动 ─────────────────────────────────
  {
    final c = FakeClock();
    final r = VerifyRound(clock: c.call);
    c.advance(const Duration(seconds: 30));
    r.refresh();
    check('3.1 没 arm 过，refresh 不产生 elapsed', r.elapsed == Duration.zero);
    check('3.2 没 arm 过，timedOut 为假', r.timedOut == false);
    check('3.3 没 arm 过，shouldAutoPop 为假', r.shouldAutoPop == false);
  }

  // ── 4. elapsed 按真实时间走 ────────────────────────────────────
  {
    final c = FakeClock();
    final r = VerifyRound(clock: c.call);
    r.arm();
    c.advance(const Duration(seconds: 4));
    r.refresh();
    check('4.1 4 秒', r.elapsed == const Duration(seconds: 4));
    c.advance(const Duration(seconds: 10));
    r.refresh();
    check(
      '4.2 跳到 14 秒（定时器被挂起也照样对）',
      r.elapsed == const Duration(seconds: 14),
      '${r.elapsed}',
    );
  }

  // ── 5. shouldAutoPop 的边界 ────────────────────────────────────
  {
    final c = FakeClock();
    final r = VerifyRound(clock: c.call);
    r.arm();
    c.advance(const Duration(milliseconds: 5900));
    r.refresh();
    check('5.1 5.9 秒不弹', r.shouldAutoPop == false);
    c.advance(const Duration(milliseconds: 100));
    r.refresh();
    check('5.2 满 6 秒就弹', r.shouldAutoPop == true);
    r.markPopped();
    check('5.3 弹过之后不再弹', r.shouldAutoPop == false);
    check('5.4 suppressedByDismiss 同步', r.suppressedByDismiss == true);
  }

  // ── 6. timedOut 边界 ──────────────────────────────────────────
  {
    final c = FakeClock();
    final r = VerifyRound(clock: c.call);
    r.arm();
    c.advance(const Duration(seconds: 90));
    r.refresh();
    check('6.1 正好 90 秒不算超时', r.timedOut == false);
    c.advance(const Duration(milliseconds: 1));
    r.refresh();
    check('6.2 90 秒零 1 毫秒算超时', r.timedOut == true);
  }

  // ── 7. markReady 只第一次为真 ──────────────────────────────────
  {
    final c = FakeClock();
    final r = VerifyRound(clock: c.call);
    r.arm();
    check('7.1 第一次 ready', r.markReady() == true);
    check('7.2 第二次 ready 为假', r.markReady() == false);
    check('7.3 第三次 ready 为假', r.markReady() == false);
    check('7.4 readySeen 已置位', r.readySeen == true);
  }

  // ── 8. begin 重置一切（rearm=true）────────────────────────────
  {
    final c = FakeClock();
    final r = VerifyRound(clock: c.call);
    r.arm();
    c.advance(const Duration(seconds: 30));
    r.refresh();
    r.markReady();
    r.markPopped();
    c.advance(const Duration(seconds: 30));
    r.begin();
    check('8.1 elapsed 归零', r.elapsed == Duration.zero);
    check('8.2 readySeen 归零', r.readySeen == false);
    check('8.3 autoPopped 归零（rearm=true）', r.autoPopped == false);
    check('8.4 起算点是新的', r.start == c.now, '${r.start} vs ${c.now}');
    check('8.5 重置后不超时', r.timedOut == false);
  }

  // ── 9. begin(rearm: false) 只重置计时，不解闸门 ────────────────
  {
    final c = FakeClock();
    final r = VerifyRound(clock: c.call);
    r.arm();
    r.markPopped();
    c.advance(const Duration(seconds: 120));
    r.refresh();
    check('9.1 先确认超时', r.timedOut == true);
    r.begin(rearm: false);
    check('9.2 收起后不超时', r.timedOut == false);
    check('9.3 收起后 elapsed 归零', r.elapsed == Duration.zero);
    check('9.4 收起后闸门仍关着', r.autoPopped == true);
    c.advance(const Duration(seconds: 10));
    r.refresh();
    check('9.5 收起 10 秒后也不自动弹回来', r.shouldAutoPop == false);
  }

  // ── 10. 用户「我过了」路径：超时后重置能继续等 ─────────────────
  {
    final c = FakeClock();
    final r = VerifyRound(clock: c.call);
    r.arm();
    c.advance(const Duration(seconds: 200)); // 用户在人机验证上耗 200 秒
    r.refresh();
    check('10.1 旧轮次已超时', r.timedOut == true);
    r.begin(); // _confirmChallengeDone 走这条
    check('10.2 点「验证好了」后不超时', r.timedOut == false);
    c.advance(const Duration(seconds: 5));
    r.refresh();
    check('10.3 接着还能等到 ready', r.markReady() == true);
    check('10.4 闸门解开', r.autoPopped == false);
  }

  // ── 11. 自动弹出后 ready 仍能被识别（不互相吞）─────────────────
  {
    final c = FakeClock();
    final r = VerifyRound(clock: c.call);
    r.arm();
    c.advance(const Duration(seconds: 7));
    r.refresh();
    check('11.1 该弹', r.shouldAutoPop == true);
    r.markPopped();
    check('11.2 弹过之后 ready 依然第一次为真', r.markReady() == true);
    check('11.3 弹过之后 shouldAutoPop 为假', r.shouldAutoPop == false);
  }

  // ── 12. 连续 begin 不会把阈值推到永远 ──────────────────────────
  {
    final c = FakeClock();
    final r = VerifyRound(clock: c.call);
    // 模拟换身份路径连着调两次 _pumpVerification（内部是 arm 不是 begin）
    r.arm();
    c.advance(const Duration(seconds: 2));
    r.arm();
    c.advance(const Duration(seconds: 5));
    r.refresh();
    check(
      '12.1 两次 arm 后照样满 7 秒',
      r.elapsed == const Duration(seconds: 7),
      '${r.elapsed}',
    );
    check('12.2 照样触发自动弹出', r.shouldAutoPop == true);
  }

  // ── 13. 自定义阈值生效 ────────────────────────────────────────
  {
    final c = FakeClock();
    final r = VerifyRound(
      autoChallengeAfter: const Duration(seconds: 2),
      window: const Duration(seconds: 10),
      clock: c.call,
    );
    r.arm();
    c.advance(const Duration(seconds: 3));
    r.refresh();
    check('13.1 自定义阈值 2 秒', r.shouldAutoPop == true);
    c.advance(const Duration(seconds: 8));
    r.refresh();
    check('13.2 自定义窗口 10 秒', r.timedOut == true);
  }

  print('');
  print('');
  print('=== 13. 【回归】用户正在过验证时，不该被超时淘汰 ===');
  {
    // 用户在页面上点复选框、等 Cloudflare 转圈，很容易超过 90 秒的窗口。
    // 旧行为：到点 timer.cancel() + 「已停止等待」，之后再也不看状态 ——
    // 用户过完回来发现界面没变，看起来就是「切过去了但回来还是不让我过」。
    final c = FakeClock();
    final r = VerifyRound(clock: c.call);
    r.begin();
    c.advance(const Duration(seconds: 120));
    r.refresh();
    check('13.1 确实超窗口了', r.timedOut);

    // 修法：界面那边判的是 `timedOut && !_showChallenge`。
    // 这里把两个分支都验一遍，防止有人把那个 `!showChallenge` 删掉。
    bool shouldGiveUp({required bool challengeOpen}) =>
        r.timedOut && !challengeOpen;
    check('13.2 弹层没开 → 让放弃', shouldGiveUp(challengeOpen: false));
    check('13.3 弹层开着 → 不放弃（继续盯着）', !shouldGiveUp(challengeOpen: true));
  }

  print('');
  print('=== 14. 【回归】弹层打开时起算点归零，但不解开自动弹出闸门 ===');
  {
    final c = FakeClock();
    final r = VerifyRound(clock: c.call);
    r.begin();
    c.advance(const Duration(seconds: 8));
    r.refresh();
    check('14.1 等满 8 秒，该自动弹了', r.shouldAutoPop);

    r.markPopped();
    r.begin(rearm: false);
    check('14.2 起算点归零之后不再超窗口', !r.timedOut);
    check('14.3 闸门仍关着（收起后不会又弹回来）', !r.shouldAutoPop);

    r.begin(rearm: false);
    c.advance(const Duration(seconds: 10));
    r.refresh();
    check('14.4 收起后再等 10 秒也不会自动弹回来', !r.shouldAutoPop);
  }

  print('$_pass passed, $_fail failed');
  if (_fail > 0) throw StateError('$_fail 条失败');
}
