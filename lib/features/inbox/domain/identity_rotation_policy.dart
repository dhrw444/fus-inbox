/// 自动换身份的策略。
///
/// ## 设计立场
///
/// 目标是让用户**尽可能一直能用**，不是照着站点的暂停说明乖乖等。
/// 站点的倒计时只是它的建议，不是我们的规则。
///
/// ## 有几件事仍然要考虑，但理由纯粹是「怎样更有效」
///
/// 站点按「短时间大量不同收件箱」判定，记在 IP 上。所以：
///
///   - **换身份有用**：新身份不会继承旧的会话、密钥、cookie。
///   - **但真正的杠杆是 IP**。同一个 IP 上换十个身份，站点的
///     行为计数还在涨。所以换身份之后要提示用户换 IP，
///     换了 IP 立刻重试 —— 这才是真正清零。
///   - **节流不是怕它，是怕浪费自己的机会**。重置之后立刻又撞墙，
///     等于白扔一次新身份。留一点间隔，让新身份有一次干净的尝试。
///
/// 参数取短：30 秒冷却、10 分钟内最多 6 次。够密，但不至于把
/// 几十个身份在几秒内全打光。
library;

/// 什么时候该自动换身份。
enum RotationTrigger() {
  /// 配额用完（429 + pause）。**换** —— 新身份不继承旧计数。
  quota,

  /// 服务端临时繁忙（503）。也换，顺手换一个干净的再试。
  busy,

  /// 需要人机验证（403）。换，绕开这次挑战。
  challenge,

  /// 会话/身份失效。换。
  sessionBroken,
}

/// 自动换身份的节流器。
class IdentityRotationPolicy({
  this.cooldown = const Duration(seconds: 30),
  this.window = const Duration(minutes: 10),
  this.maxPerWindow = 6,
}) {
  /// 两次自动重置的最小间隔。
  ///
  /// 不是怕站点，是为了让新身份有一次干净完整的尝试 ——
  /// 刚重置完立刻又撞墙，那个身份就白扔了。
  final Duration cooldown;

  final Duration window;

  /// 一个窗口内最多自动重置几次。
  ///
  /// 6 次足够覆盖「换 IP 前后各试几轮」。再多就是无脑刷，
  /// 反而把新身份一次性打光。
  final int maxPerWindow;

  final List<DateTime> _recent = [];
  DateTime? _last;

  /// 所有拒绝类型都换身份。
  static bool shouldRotateFor(RotationTrigger trigger) => true;

  /// 现在能不能自动重置。不能的话第二个值是给用户看的原因。
  (bool, String) canRotate(DateTime now) {
    _prune(now);

    final last = _last;
    if (last != null) {
      final passed = now.difference(last);
      if (passed < cooldown) {
        final left = cooldown - passed;
        return (false, '刚换过身份，${left.inSeconds} 秒后再来');
      }
    }

    if (_recent.length >= maxPerWindow) {
      return (
        false,
        '这 ${window.inMinutes} 分钟换了 $maxPerWindow 次，'
            '建议换个 IP 再继续 —— 那才是真正清零。',
      );
    }
    return (true, '');
  }

  void record(DateTime now) {
    _last = now;
    _recent.add(now);
    _prune(now);
  }

  void _prune(DateTime now) {
    _recent.removeWhere((t) => now.difference(t) > window);
  }
}
