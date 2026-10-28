// 「把验证框放大到可见区正中」的那段数学。
//
// 这段错了很难发现：稍微偏一点，复选框就跑到屏幕外面，而界面上看只是
// 「一片空白」—— 用户会以为验证框没出来。所以把每个边界都钉住。
//
// 纯逻辑，不碰 UI、不 import `dart:ui`（那在纯 Dart 里没有）。
import 'package:fus_inbox/features/inbox/domain/challenge_focus.dart';

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

const vw = 400.0;
const vh = 800.0;

/// 调用助手：`focus(左, 上, 宽, 高, ...)`，视口固定 400×800。
ChallengeFocus? focus(
  double l,
  double t,
  double w,
  double h, {
  double bottomInset = 0,
  double maxScale = 3.0,
  double viewportW = vw,
  double viewportH = vh,
}) => focusOnChallenge(
  viewportWidth: viewportW,
  viewportHeight: viewportH,
  rectLeft: l,
  rectTop: t,
  rectWidth: w,
  rectHeight: h,
  bottomInset: bottomInset,
  maxScale: maxScale,
);

/// 校验一条不变式：**矩形放大平移之后，整个落在可见区里**。
///
/// 比逐个数对更接近「用户能不能点到」这件事。
void okStaysVisible(
  double l,
  double t,
  double w,
  double h,
  ChallengeFocus f, {
  double bottomInset = 0,
}) {
  final sl = l * f.scale + f.dx;
  final st = t * f.scale + f.dy;
  final sr = (l + w) * f.scale + f.dx;
  final sb = (t + h) * f.scale + f.dy;
  final visibleH = vh - bottomInset;
  final inside =
      sl >= -0.5 && st >= -0.5 && sr <= vw + 0.5 && sb <= visibleH + 0.5;
  ok(inside, '框完整落在可见区里', '(框 $sl,$st → $sr,$sb；可见区 $vw×$visibleH)');
}

void main() {
  print('=== 1. 正常的小复选框：放大到可见区正中 ===');
  {
    // 常见形状：站点给的是一个 300×65 的条。
    final f = focus(50, 300, 300, 65)!;
    ok(f.scale >= 1.0, '放大倍数不小于 1', '(scale=${f.scale})');
    okStaysVisible(50, 300, 300, 65, f);
    // 中心对齐：中心×scale + 平移 == 视口中心
    ok(
      (((50 + 150) * f.scale + f.dx) - vw / 2).abs() < 0.5,
      '水平居中',
      '(cx=${(50 + 150) * f.scale + f.dx})',
    );
    ok(
      (((300 + 32.5) * f.scale + f.dy) - vh / 2).abs() < 0.5,
      '垂直居中',
      '(cy=${(300 + 32.5) * f.scale + f.dy})',
    );
  }

  print('');
  print('=== 2. 底部提示栏要留出来（不能压住复选框）===');
  {
    const inset = 88.0;
    final f = focus(50, 600, 300, 65, bottomInset: inset)!;
    okStaysVisible(50, 600, 300, 65, f, bottomInset: inset);
    // 居中是以「可见区」为基准，不是整个视口。
    final cy = (600 + 32.5) * f.scale + f.dy;
    ok((cy - (vh - inset) / 2).abs() < 0.5, '在可见区内居中（不是整个视口的中心）', '(cy=$cy)');
  }

  print('');
  print('=== 3. 【关键】框比可见区还大时不许缩小 ===');
  {
    // 站点给整块挑战面板时，按「装下」算出来的倍率会小于 1。
    // 那样反而把复选框缩得更小、更难点 —— 必须夹在 1:1。
    final f = focus(0, 200, 380, 500)!;
    ok(f.scale == 1.0, '不缩小，保持 1:1', '(scale=${f.scale})');
    ok((((200 + 250) * f.scale + f.dy) - vh / 2).abs() < 0.5, '仍然居中');
  }

  print('');
  print('=== 4. 放大上限 ===');
  {
    // 一个 20×20 的小方块，按比例能放到 10 倍以上 —— 必须被上限挡住。
    final f = focus(100, 400, 20, 20, maxScale: 3)!;
    ok(f.scale == 3.0, '被 maxScale 挡住', '(scale=${f.scale})');
    ok(focus(100, 400, 20, 20)!.scale <= 3.0, '默认上限也是 3');
  }

  print('');
  print('=== 5. 退化输入返回 null（调用方据此回落显示整页）===');
  {
    ok(focus(0, 0, 0, 0) == null, '零尺寸的框 → null');
    ok(focus(0, 0, -5, 10) == null, '负宽度 → null');
    ok(focus(0, 0, 10, -1) == null, '负高度 → null');
    ok(focus(0, 0, 10, 10, viewportW: 0) == null, '零宽视口 → null');
    ok(focus(0, 0, 10, 10, viewportH: 0) == null, '零高视口 → null');
    ok(
      focus(0, 700, 10, 10, bottomInset: 900) == null,
      '提示栏比视口还高 → null（可见区为负）',
    );
  }

  print('');
  print('=== 6. 框在视口外的负坐标也要能拉回来 ===');
  {
    // 页面滚动之后 rect 可能是负的（框滚到了上方）。
    final f = focus(30, -400, 300, 65)!;
    okStaysVisible(30, -400, 300, 65, f);
    ok(f.dy > 0, '平移量是正的（往下拉）', '(dy=${f.dy})');
  }

  print('');
  print('=== 7. 放大上限之内，框越大放得越少（单调性）===');
  {
    final small = focus(190, 380, 20, 20)!.scale;
    final mid = focus(150, 350, 100, 40)!.scale;
    final big = focus(50, 300, 300, 65)!.scale;
    ok(small >= mid && mid >= big, '框越大倍率越小', '($small ≥ $mid ≥ $big)');
  }

  print('');
  print('$pass passed, $fail failed');
  if (fail > 0) throw StateError('$fail failed');
}
