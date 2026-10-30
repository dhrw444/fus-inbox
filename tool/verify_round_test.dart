// 测**真实代码**：直接 import lib/core/webview/verify_round.dart。
//
// 这套契约是被重写过的那一版：判据从「等满 6 秒就弹」改成「只认站点
// 自己派的 `fus:reader-check`」，从「看 cf_clearance」改成「只认站点
// 自己的 FUSReader.status() 相位」。
//
// 跑：dart run tool/verify_round_test.dart
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

VerifyRound build({FakeClock? clock, Duration? window}) {
  final c = clock ?? FakeClock();
  return VerifyRound(
    window: window ?? const Duration(seconds: 180),
    clock: c.call,
  );
}

void main() {
  // ── 1. 默认值与初始态 ─────────────────────────────────────────
  {
    final r = VerifyRound();
    check(
      '1.1 窗口 180 秒（与站点 reader.js 的 180 秒超时对齐）',
      r.window == const Duration(seconds: 180),
    );
    check('1.2 初始 elapsed 归零', r.elapsed == Duration.zero);
    check('1.3 初始相位 unknown', r.phase == ReaderPhase.unknown);
    check('1.4 初始没人机验证标记', r.humanCheckSeen == false);
    check('1.5 初始没弹过', r.autoPopped == false);
    check('1.6 初始没起算点', r.start == null);
  }

  // ── 2. arm / elapsed ─────────────────────────────────────────
  {
    final c = FakeClock();
    final r = build(clock: c);
    r.arm();
    check('2.1 arm 后有起算点', r.start != null);
    check('2.2 刚 arm 时 elapsed 为零', r.elapsed == Duration.zero);
    c.advance(const Duration(seconds: 30));
    check('2.3 30 秒后 elapsed = 30 秒', r.elapsed.inSeconds == 30);
    r.arm();
    // **arm 不重置起算点** —— 它只在没有的时候才落（`_start ??= _clock()`）。
    // 这条契约是给轮询用的：`_pumpVerification` 每次重建 timer 都会 arm，
    // 重置的话用户每被挂起一次计时就归零，「等太久」永远等不到。
    // 真正要归位的是 `begin()`（换号、换身份、用户点完按钮）。
    check('2.4 再 arm 不重置起算点', r.elapsed.inSeconds == 30);
  }

  // ── 3. 没有起算点时一切不动 ────────────────────────────────────
  {
    final c = FakeClock();
    final r = build(clock: c);
    c.advance(const Duration(seconds: 300));
    check('3.1 没 arm 过，elapsed 恒零', r.elapsed == Duration.zero);
    check('3.2 没 arm 过，不算超时', r.timedOut == false);
    check('3.3 没 arm 过，不自动弹', r.shouldAutoPop == false);
  }

  // ── 4. 超时边界 ───────────────────────────────────────────────
  {
    final c = FakeClock();
    final r = build(clock: c);
    r.arm();
    c.advance(const Duration(seconds: 180));
    check('4.1 恰好等于窗口不算超时', r.timedOut == false);
    c.advance(const Duration(seconds: 1));
    check('4.2 超过窗口才算超时', r.timedOut == true);
  }

  // ── 5. 自动弹层：只认站点事件，不认计时 ────────────────────────
  //
  // 这是重写的核心。旧实现「等满 6 秒就弹」——站点只是慢的时候会无端
  // 弹层，而站点真的摆了人机验证时又可能还没弹。现在只看
  // `fus:reader-check` 有没有来过。
  {
    final c = FakeClock();
    final r = build(clock: c);
    r.arm();
    c.advance(const Duration(minutes: 5));
    check('5.1 等很久但站点没要人点 → 不弹', r.shouldAutoPop == false);

    r.markHumanCheck();
    check('5.2 站点派了 fus:reader-check → 弹', r.shouldAutoPop == true);
    check('5.3 还没弹过时 autoPopped 为假', r.autoPopped == false);

    r.markPopped();
    check('5.4 弹过之后不再弹', r.shouldAutoPop == false);
    check('5.5 弹过之后 autoPopped 为真', r.autoPopped == true);
  }

  // ── 6. 弹层开着时不自动弹 ──────────────────────────────────────
  {
    final r = build();
    r.arm();
    r.markHumanCheck();
    r.showAuto();
    r.markPopped();
    check('6.1 弹层开着，shouldAutoPop 为假', r.shouldAutoPop == false);
    check('6.2 弹层开着，open 为真', r.open == true);
    check('6.3 自动弹的层 auto 为真', r.auto == true);
  }

  // ── 7. 自动收层：只认站点相位 ready ───────────────────────────
  {
    final r = build();
    r.arm();
    r.markHumanCheck();
    r.showAuto();
    r.markPopped();
    check('7.1 相位还 unknown 时不收', r.shouldAutoClose == false);
    r.updatePhase(ReaderPhase.pending);
    check('7.2 相位 checking 时不收', r.shouldAutoClose == false);
    r.updatePhase(ReaderPhase.ready);
    check('7.3 相位 ready → 收', r.shouldAutoClose == true);
  }

  // ── 8. 用户自己点开的层不自动收 ────────────────────────────────
  //
  // 他可能只是想顺便看看网页。只有「自动弹的」才自动收。
  {
    final r = build();
    r.arm();
    r.showManual();
    r.updatePhase(ReaderPhase.ready);
    check('8.1 手动弹的层，站点 ready 也不自动收', r.shouldAutoClose == false);
  }

  // ── 9. updatePhase 的返回值只在真变化时为真 ────────────────────
  {
    final r = build();
    check('9.1 第一次设 ready 算变化', r.updatePhase(ReaderPhase.ready) == true);
    check('9.2 重复设 ready 不算变化', r.updatePhase(ReaderPhase.ready) == false);
    check('9.3 换到 pending 算变化', r.updatePhase(ReaderPhase.pending) == true);
  }

  // ── 10. begin 的相位保留开关 ───────────────────────────────────
  //
  // 用户点完按钮回来时必须保留相位：`phase == ready` 正是自动收层的
  // 唯一判据，清掉就等于把刚拿到的结论扔了。
  {
    final r = build();
    r.arm();
    r.updatePhase(ReaderPhase.ready);
    r.markHumanCheck();
    r.begin(rearm: false, resetPhase: false);
    check('10.1 保留相位时 phase 还在', r.phase == ReaderPhase.ready);
    check('10.2 保留相位时 humanCheckSeen 还在', r.humanCheckSeen == true);

    final r2 = build();
    r2.arm();
    r2.updatePhase(ReaderPhase.ready);
    r2.markHumanCheck();
    r2.begin();
    check('10.3 默认 begin 清掉相位', r2.phase == ReaderPhase.unknown);
    check('10.4 默认 begin 清掉人机验证标记', r2.humanCheckSeen == false);
  }

  // ── 11. 收层与闸门 ───────────────────────────────────────────
  {
    final r = build();
    r.arm();
    r.markHumanCheck();
    r.markPopped();
    r.showAuto();
    r.markPopped();
    r.close();
    check('11.1 close 后 open 为假', r.open == false);
    // 闸门保持关着 —— 否则收起之后站点再派一次 check 就立刻弹回来。
    check('11.2 close 之后不自动弹回来', r.shouldAutoPop == false);
    r.begin(rearm: true);
    check('11.3 rearm 后闸门解开', r.autoPopped == false);
  }

  // ── 12. readerPhaseOf 的映射 ─────────────────────────────────
  {
    check('12.1 ready → ready', readerPhaseOf('ready') == ReaderPhase.ready);
    check(
      '12.2 pending → pending',
      readerPhaseOf('pending') == ReaderPhase.pending,
    );
    check('12.3 error → error', readerPhaseOf('error') == ReaderPhase.error);
    check('12.4 空串 → unknown', readerPhaseOf('') == ReaderPhase.unknown);
    check(
      '12.5 不认识的值 → unknown',
      readerPhaseOf('nonsense') == ReaderPhase.unknown,
    );
    // 站点自己的 phase 取值只有这几档（reader.js 的 setState 调用），
    // 大写不该被认出来，避免把 'READY' 这种噪声当成 ready。
    check('12.6 大小写敏感', readerPhaseOf('READY') == ReaderPhase.unknown);
  }

  print('');
  print('$_pass 通过 / $_fail 失败');
  if (_fail > 0) throw StateError('$_fail 条断言失败');
}
