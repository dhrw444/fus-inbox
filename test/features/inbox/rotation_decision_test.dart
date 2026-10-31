import 'package:flutter_test/flutter_test.dart';
import 'package:fus_inbox/features/inbox/domain/inbox_message.dart';
import 'package:fus_inbox/features/inbox/domain/rotation_decision.dart';

SiteHold hold(SiteHoldKind kind) => SiteHold(
  kind: kind,
  title: '',
  message: '',
);

/// 一次判定的默认输入：开关开着、池子里有别的出口、还没连换过。
RotationDecision decide({
  SiteHold? h,
  String status = '',
  bool autoRotate = true,
  bool egressAvailable = true,
  int consecutive = 0,
}) => decideRotation(
  hold: h,
  status: status,
  autoRotate: autoRotate,
  egressAvailable: egressAvailable,
  consecutiveRotations: consecutive,
  maxConsecutiveRotations: 3,
);

void main() {
  group('challenge 绝不触发换出口/换身份', () {
    test('challenge 只等，不动出口也不动身份', () {
      final d = decide(h: hold(SiteHoldKind.challenge));
      expect(d.action, RotationAction.waitOnly);
      // 真机上「过完验证退出收件页、重进又等一大会、又自动换身份」
      // 就是这个分支在换。它现在必须一次都不换。
      expect(d.action, isNot(RotationAction.rotateEgress));
    });

    test('challenge + 自动换开关关着 → 仍然只等，不是 nothing', () {
      final d = decide(h: hold(SiteHoldKind.challenge), autoRotate: false);
      expect(d.action, RotationAction.waitOnly);
    });

    test('challenge + 池子里没有别的出口 → 只等，不弹「没得换」', () {
      final d = decide(h: hold(SiteHoldKind.challenge), egressAvailable: false);
      expect(d.action, RotationAction.waitOnly);
    });

    test('status 先说 reader_verification、holdup 帧还没到 → 也只等', () {
      final d = decide(status: 'reader_verification_required');
      expect(d.action, RotationAction.waitOnly);
    });
  });

  group('quota 才换出口', () {
    test('quota + 开关开 + 有别的出口 → 换出口', () {
      expect(
        decide(h: hold(SiteHoldKind.quota)).action,
        RotationAction.rotateEgress,
      );
    });

    test('quota + 开关关着 → 只等', () {
      expect(
        decide(h: hold(SiteHoldKind.quota), autoRotate: false).action,
        RotationAction.waitOnly,
      );
    });

    test('quota + 池子里没有别的出口 → 只等，并且说清为什么', () {
      final d = decide(h: hold(SiteHoldKind.quota), egressAvailable: false);
      expect(d.action, RotationAction.waitOnly);
      expect(d.note, contains('没有别的出口'));
    });
  });

  group('其余档位与边界', () {
    test('信号干净 → nothing（调用方据此把连续计数归零）', () {
      expect(decide().action, RotationAction.nothing);
    });

    test('temporary（503）→ 只等，不换', () {
      final d = decide(h: hold(SiteHoldKind.temporary));
      expect(d.action, RotationAction.waitOnly);
      expect(d.note, contains('等它自己恢复'));
    });

    test('连换到上限 → 停手，连配额也不换了', () {
      final d = decide(h: hold(SiteHoldKind.quota), consecutive: 3);
      expect(d.action, RotationAction.waitOnly);
      expect(d.note, contains('先停下'));
    });

    test('连换到上限时，干净状态仍然归零', () {
      // 归零那条路径不受上限影响 —— 否则换满之后永远卡死。
      expect(decide(consecutive: 3).action, RotationAction.nothing);
    });
  });
}
