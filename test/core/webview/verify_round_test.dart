import 'package:flutter_test/flutter_test.dart';
import 'package:fus_inbox/core/webview/verify_round.dart';

void main() {
  /// 可控时钟。状态机用真实时间算 elapsed，测试里必须能推着走。
  late DateTime now;
  DateTime clock() => now;

  VerifyRound build({Duration window = const Duration(seconds: 180)}) {
    now = DateTime(2026, 1, 1, 12);
    return VerifyRound(window: window, clock: clock);
  }

  group('readerPhaseOf', () {
    test('四个合法相位一一对应', () {
      expect(readerPhaseOf('idle'), ReaderPhase.idle);
      expect(readerPhaseOf('pending'), ReaderPhase.pending);
      expect(readerPhaseOf('ready'), ReaderPhase.ready);
      expect(readerPhaseOf('error'), ReaderPhase.error);
    });

    test('空串与认不出的值落到 unknown', () {
      expect(readerPhaseOf(''), ReaderPhase.unknown);
      expect(readerPhaseOf('ready '), ReaderPhase.unknown);
      expect(readerPhaseOf('READY'), ReaderPhase.unknown);
      expect(readerPhaseOf('cancelled'), ReaderPhase.unknown);
    });
  });

  group('窗口计时', () {
    test('没有起算点时 elapsed 为零、不算超时', () {
      final round = build();
      expect(round.elapsed, Duration.zero);
      expect(round.timedOut, isFalse);
    });

    test('arm 只落一次起算点', () {
      final round = build();
      round.arm();
      final first = round.start;
      now = now.add(const Duration(seconds: 30));
      round.arm();
      expect(round.start, first, reason: 'arm 不该覆盖已有起算点');
      expect(round.elapsed.inSeconds, 30);
    });

    test('超过窗口才算超时', () {
      final round = build();
      round.arm();
      now = now.add(const Duration(seconds: 179));
      expect(round.timedOut, isFalse);
      now = now.add(const Duration(seconds: 2));
      expect(round.timedOut, isTrue);
    });

    test('begin 把起算点归位', () {
      final round = build();
      round.arm();
      now = now.add(const Duration(seconds: 100));
      expect(round.elapsed.inSeconds, 100);
      round.begin();
      expect(round.elapsed.inSeconds, 0);
    });
  });

  group('updatePhase', () {
    test('相位变化返回 true，只报一次', () {
      final round = build();
      expect(round.updatePhase(ReaderPhase.pending), isTrue);
      expect(round.updatePhase(ReaderPhase.pending), isFalse);
      expect(round.updatePhase(ReaderPhase.ready), isTrue);
      expect(round.phase, ReaderPhase.ready);
    });

    test('unknown 不覆盖已读到的相位', () {
      final round = build();
      round.updatePhase(ReaderPhase.ready);
      expect(round.updatePhase(ReaderPhase.unknown), isFalse);
      expect(round.phase, ReaderPhase.ready, reason: '读不到时不该把结论抹掉');
    });
  });

  group('自动弹层', () {
    test('没人机验证就不弹 —— 这是旧实现最大的坑', () {
      final round = build();
      round.arm();
      now = now.add(const Duration(seconds: 120));
      // 站点只是慢，没摆验证框。旧实现「等满 6 秒就弹」会在这里误弹。
      expect(round.shouldAutoPop, isFalse);
    });

    test('站点真的摆了验证框才弹', () {
      final round = build();
      expect(round.shouldAutoPop, isFalse);
      round.markHumanCheck();
      expect(round.shouldAutoPop, isTrue);
    });

    test('弹过就不再弹', () {
      final round = build();
      round.markHumanCheck();
      round.markPopped();
      expect(round.shouldAutoPop, isFalse);
    });

    test('层开着时不再弹', () {
      final round = build();
      round.markHumanCheck();
      round.showAuto();
      expect(round.shouldAutoPop, isFalse);
    });

    test('begin(rearm: true) 解开闸门', () {
      final round = build();
      round.markPopped();
      round.begin();
      expect(round.autoPopped, isFalse);
    });

    test('begin(rearm: false) 保持闸门关着 —— 收起后不弹回来', () {
      final round = build();
      round.markPopped();
      round.begin(rearm: false);
      expect(round.autoPopped, isTrue);
    });
  });

  group('自动收层', () {
    test('自动弹的层 + 站点 ready = 收', () {
      final round = build();
      round.markHumanCheck();
      round.showAuto();
      round.updatePhase(ReaderPhase.ready);
      expect(round.shouldAutoClose, isTrue);
    });

    test('用户自己点开的层不自动收', () {
      final round = build();
      round.showManual();
      round.updatePhase(ReaderPhase.ready);
      expect(round.shouldAutoClose, isFalse, reason: '他可能只是想看看网页');
    });

    test('站点还没 ready 就不收', () {
      final round = build();
      round.showAuto();
      round.updatePhase(ReaderPhase.pending);
      expect(round.shouldAutoClose, isFalse);
    });

    test('站点报错就不收', () {
      final round = build();
      round.showAuto();
      round.updatePhase(ReaderPhase.error);
      expect(round.shouldAutoClose, isFalse);
    });
  });

  group('相位保留（点完按钮回来的路径）', () {
    test('resetPhase: false 保住 ready，自动收层仍成立', () {
      final round = build();
      round.showAuto();
      round.updatePhase(ReaderPhase.ready);
      round.begin(rearm: false, resetPhase: false);
      expect(round.phase, ReaderPhase.ready, reason: '刚拿到的结论不能被扔掉');
      expect(round.shouldAutoClose, isTrue);
    });

    test('resetPhase: true 清掉相位与人机验证标记', () {
      final round = build();
      round.markHumanCheck();
      round.updatePhase(ReaderPhase.ready);
      round.begin();
      expect(round.phase, ReaderPhase.unknown);
      expect(round.humanCheckSeen, isFalse);
    });
  });

  group('收起', () {
    test('close 关掉层并清掉 auto 标记', () {
      final round = build();
      round.showAuto();
      expect(round.open, isTrue);
      expect(round.auto, isTrue);
      round.close();
      expect(round.open, isFalse);
      expect(round.auto, isFalse);
    });

    test('收起后站点 ready 也不再自动收（层本来就没开）', () {
      final round = build();
      round.showAuto();
      round.close();
      round.updatePhase(ReaderPhase.ready);
      expect(round.shouldAutoClose, isFalse);
    });
  });
}
