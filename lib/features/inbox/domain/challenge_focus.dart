/// 把「人机验证框在页面里的位置」换算成「WebView 该怎么裁/放大」。
///
/// ## 为什么需要它
///
/// 自动弹出验证时，整个站点页面糊在屏幕上，而用户要点的只有一个复选框 ——
/// 看着难受，还容易点到广告。所以要**只把那块放大显示**。
///
/// 但 WebView 是全屏渲染的，Flutter 这边改不了页面内部布局。能做的只有
/// 把整个视图 `ClipRect` + `Transform` —— 放大并平移到验证框所在的位置。
/// 这个文件算的就是那个变换的三个数：**放大几倍、平移多少**。
///
/// ## 为什么参数是裸 double 而不是 `Rect` / `Size`
///
/// `Rect` / `Size` 来自 `dart:ui`，**纯 Dart 里没有这个库** —— 用了它们，
/// `tool/challenge_focus_test.dart` 就一行都跑不了（这条本仓踩过一次，
/// 见 `lib/core/log.dart` 的注释）。
///
/// 这段数学错了很难看出来：稍微偏一点，复选框就跑到屏幕外面去了，而界面
/// 上看只是「一片空白」—— 用户会以为验证框根本没出来。所以它必须能单测，
/// 于是参数用裸数字，调用方（UI 那层）自己把 `Rect` / `Size` 拆开传进来。
library;

import 'dart:math' as math;

/// 一次「聚焦到验证框」的变换参数。
class const ChallengeFocus({
  required this.scale,
  required this.dx,
  required this.dy,
}) {
  /// 放大倍数，≥ 1（只放大不缩小 —— 缩小会让复选框小到点不准）。
  final double scale;

  /// 屏幕坐标上的平移量（像素）。
  final double dx;
  final double dy;
}

/// 算出把矩形摆到可见区正中所需的变换。
///
/// - [viewportWidth] / [viewportHeight]：WebView 的尺寸。
/// - [rectLeft] / [rectTop] / [rectWidth] / [rectHeight]：验证框在页面里的
///   位置（CSS 像素，左上角原点，允许为负 —— 页面滚动之后就是这样）。
/// - [bottomInset]：底部那条提示栏的高度（复选框不该被它压住）。
/// - [padding]：验证框四周留的余量，免得贴边。
/// - [maxScale]：放大上限。不设上限时一个 20×20 的复选框会被放到糊。
///
/// 返回 null 表示**没法算**（矩形或可见区是空的），调用方应当回落到
/// 「显示整页」—— 宁可多显示，也不能让用户没有可点的地方。
ChallengeFocus? focusOnChallenge({
  required double viewportWidth,
  required double viewportHeight,
  required double rectLeft,
  required double rectTop,
  required double rectWidth,
  required double rectHeight,
  double bottomInset = 0,
  double padding = 28,
  double maxScale = 3.0,
}) {
  final visibleH = viewportHeight - bottomInset;
  if (viewportWidth <= 0 || visibleH <= 0) return null;
  if (rectWidth <= 0 || rectHeight <= 0) return null;

  final wantW = rectWidth + padding * 2;
  final wantH = rectHeight + padding * 2;

  // 放大到「刚好装下」和「不超过上限」里小的那个；再夹到 ≥1。
  //
  // 夹 ≥1 很关键：验证框本来就大于视口时（站点给的是整块 320×480 的
  // 挑战面板），按比例算出来的 s 会小于 1 —— 那样反而是把页面缩小，
  // 复选框变小、更难点。那种情况直接保持 1:1，靠平移把它居中即可。
  final fit = math.min(viewportWidth / wantW, visibleH / wantH);
  final scale = fit.clamp(1.0, maxScale);

  // 让矩形的中心落到可见区中心：
  //   屏幕坐标 = 原坐标 × scale + offset
  //   要求 rect.center × scale + offset = 可见区中心
  final centerX = rectLeft + rectWidth / 2;
  final centerY = rectTop + rectHeight / 2;
  final dx = viewportWidth / 2 - centerX * scale;
  final dy = visibleH / 2 - centerY * scale;

  return ChallengeFocus(scale: scale, dx: dx, dy: dy);
}
