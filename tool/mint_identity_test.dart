// mintIdentity 自洽性实测：UA 里的机型 / Chrome 版本必须和字段一致。
//
// 三个 mint 回调曾经各自调一次 mintIdentity()，于是 UA 说 SM-S918B /
// Chrome 134、机型字段却是 Pixel 7、版本字段 131 —— 套到浏览器上
// navigator.userAgentData 和 UA 对不上，比不换还扎眼。
//
// 这里直接跑**仓库里真实的** mintIdentity()，不抄副本 —— 抄副本测的
// 是抄的人，不是代码。

import 'dart:math';

import 'package:fus_inbox/core/webview/browser_identity.dart';

int passed = 0;
int failed = 0;

void check(String name, bool ok, [String extra = '']) {
  if (ok) {
    passed++;
    print('  ok   $name  $extra');
  } else {
    failed++;
    print('  FAIL $name  $extra');
  }
}

void main() {
  final r = Random(20261027);

  print('== 1. UA 里的机型与 model 字段一致');
  {
    var bad = 0;
    for (var i = 0; i < 500; i++) {
      final id = mintIdentity(r);
      final m = RegExp(r'Android [\d.]+; ([^;)]+)\)').firstMatch(id.userAgent);
      if (m?.group(1)?.trim() != id.model) bad++;
    }
    check('机型一致', bad == 0, '(bad=$bad/500)');
  }

  print('== 2. UA 里的 Chrome 版本与 chromeMajor 一致');
  {
    var bad = 0;
    for (var i = 0; i < 500; i++) {
      final id = mintIdentity(r);
      final m = RegExp(r'Chrome/(\d+)\.').firstMatch(id.userAgent);
      if (m?.group(1) != id.chromeMajor) bad++;
    }
    check('版本一致', bad == 0, '(bad=$bad/500)');
  }

  print('== 3. 版本浮动在基准附近（编不存在的版本更可疑）');
  {
    var min = 999;
    var max = 0;
    for (var i = 0; i < 500; i++) {
      final id = mintIdentity(r);
      final major = int.tryParse(id.chromeMajor) ?? 0;
      if (major < min) min = major;
      if (major > max) max = major;
    }
    // 基准是**内核真值**（`noteKernelMajor` 记下的 141），不是「当前身份」——
    // 拿当前身份当基准就是让结果喂给自己，会单向下漂。
    // 窗口对称 ±2 → 139..143，期望 0，不会系统性漂移。
    check('浮动在 139~143', min >= 139 && max <= 143, '(min=$min max=$max)');
  }

  print('== 4. 每次都不一样（不是固定返回同一个）');
  {
    final models = <String>{};
    final majors = <String>{};
    for (var i = 0; i < 500; i++) {
      final id = mintIdentity(r);
      models.add(id.model);
      majors.add(id.chromeMajor);
    }
    check('机型至少 4 种', models.length >= 4, '(got=${models.length})');
    check('版本至少 3 种', majors.length >= 3, '(got=${majors.length})');
  }

  print('== 5. 机型串不能带括号 / 分号（会把 UA 拼坏）');
  {
    var bad = 0;
    for (var i = 0; i < 500; i++) {
      final id = mintIdentity(r);
      if (id.model.contains('(') ||
          id.model.contains(')') ||
          id.model.contains(';')) {
        bad++;
      }
    }
    check('机型全部干净', bad == 0, '(bad=$bad)');
  }

  print('== 6. 生成的身份不能和当前身份一模一样');
  {
    // 这是这次 bug 的核心：mint 回调返回 currentIdentity 时，
    // 「新身份」和旧身份完全相同，换到干净出口上等于没换。
    var same = 0;
    for (var i = 0; i < 200; i++) {
      final id = mintIdentity(r);
      if (id.userAgent == currentIdentity.userAgent) same++;
    }
    check('不会撞出和当前完全相同的 UA', same == 0, '(same=$same/200)');
  }

  print('\n$passed passed, $failed failed');
  if (failed > 0) throw StateError('$failed failed');
}
