/// 验证弹层的显示状态。
///
/// ## 为什么收成一个对象
///
/// 原来是 `_showChallenge` 和 `_challengeAuto` 两个字段，它们描述的是**同一件
/// 事**的两个侧面：
///
/// - `_showChallenge`：弹层开着没有
/// - `_challengeAuto`：这次是站点不放行自动弹的，还是用户自己点的
///
/// 拆开时有一整类组合是**无意义但能写出来**的：`show=false, auto=true`
/// （弹层没开、却是自动弹的）。代码里为这种状态写过好几处 `!mounted ||
/// !_showChallenge || !_challengeAuto` 这种三连判 —— 每多一个消费点就多
/// 一次漏判的机会。
///
/// 收成 [ChallengeUi] 之后，「自动弹」这个词只在一个地方定义：
/// [auto] 为真就必然意味着弹层开着。
///
/// ## 两者的呈现**故意不一样**
///
/// - 自动弹 = 站点不放行、用户被迫来过验证 → 屏幕上只显示验证框
/// - 手动点 = 用户想看网页 → 显示整个站点页面
///
/// 这个区别由 [auto] 表达，界面按它分叉（见 `inbox_screen` 的 `build`）。
library;

/// 验证弹层的当前状态。不可变。
class const ChallengeUi({
  /// 弹层是否开着。
  required this.open,

  /// 这次是**自动弹**的还是用户自己点的。
  ///
  /// 只在不变量成立时才有意义 —— 见 [ChallengeUi.auto] 的构造器
  /// [ChallengeUi.autoShown]。弹层没开时恒为 false。
  required this.auto,
}) {
  final bool open;
  final bool auto;

  /// 收起的状态。全 App 只有这一个「收起」入口 —— 漏清某个字段这种
  /// bug 就不可能发生。
  static const closed = ChallengeUi(open: false, auto: false);

  /// 自动弹：屏幕上只显示验证框，不显示网站。
  static const autoShown = ChallengeUi(open: true, auto: true);

  /// 用户自己点开：显示整个站点页面，让他自己看、自己操作。
  static const manualShown = ChallengeUi(open: true, auto: false);

  /// 自动弹 + 弹层开着 —— 只有这种情况才需要盯着 `cf_clearance` 自动收层。
  /// 用户自己点开的那个不收：他可能只是想顺便看看网页。
  bool get watchingForAutoPass => open && auto;
}
