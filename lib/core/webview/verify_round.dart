/// 一轮「等站点放行」的状态机。纯逻辑，不碰 Timer / WebView / UI。
///
/// ## 判据来源（全部实测，不是推断）
///
/// 站点自己把会话状态暴露在 `window.FUSReader.status()`：
/// `{phase, category, errorCode, message}`，`phase` 只有四个值
/// `idle / pending / ready / error`（`reader.js:7,13-16,69,92,134-147`）。
/// 站点在 `ready` 时同时派发 `fus:reader-ready`，在开始摆人机验证时派发
/// `fus:reader-check`（`reader.js:103`）。
///
/// 所以「过了」这件事只有一种可靠证据：**站点自己说 ready**。
///
/// ## 为什么不看 `cf_clearance`
///
/// 旧实现在这里盯 `cf_clearance` cookie 判通过。**站点根本不下发它** ——
/// 对站点三个脚本 `live.js / reader.js / site.js` 做字面检索，`cf_clearance`
/// 与 `cf-chl` 均 0 命中；对收件页与目录页做 `curl -D -`，响应头里没有任何
/// `Set-Cookie`。盯一个永不存在的值，等价于「自动收层永不发生」。
///
/// ## 为什么不看 DOM 上的挑战标记
///
/// 旧实现还查 `id="challenge-form" / challenge-success-text /
/// challenge-error-text`。这三个 id 同样是 Cloudflare 通用挑战页的标记，
/// 站点用自己的 Turnstile 组件，脚本里 0 命中。而且这组判据的方向是反的：
/// 它用来「确认可以收层」，真正该问的是「站点有没有在等人」。
library;

/// 站点会话相位。和 `reader.js` 的 `uiState.phase` 一一对应。
enum ReaderPhase() {
  /// 还没读到（页面没加载完、注入脚本没跑）。
  unknown,

  /// 空闲，没有进行中的会话动作。
  idle,

  /// 站点正在建立会话（可能正在摆人机验证）。
  pending,

  /// 会话可用。**这就是「放行」的唯一证据。**
  ready,

  /// 明确失败。`category` / `errorCode` 在站点那边有值。
  error,
}

/// 把站点回的 `phase` 字符串转成枚举。认不出的当 [ReaderPhase.unknown]。
ReaderPhase readerPhaseOf(String raw) {
  return switch (raw) {
    'idle' => ReaderPhase.idle,
    'pending' => ReaderPhase.pending,
    'ready' => ReaderPhase.ready,
    'error' => ReaderPhase.error,
    _ => ReaderPhase.unknown,
  };
}

class VerifyRound {
  /// 带初始化列表，主构造器表达不了 `clock ?? DateTime.now`。
  // ignore: use_primary_constructors
  VerifyRound({
    this.window = const Duration(seconds: 180),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// 最多等这么久。
  ///
  /// 站点自己的人机验证组件超时是 **180 秒**（`reader.js:110`），
  /// 而 `recover()` 的重试间隔是 30 秒（`reader.js:172`）。
  /// 窗口比站点短，就会出现「用户还在站点的验证框上，App 已经放弃了」。
  final Duration window;

  final DateTime Function() _clock;

  DateTime? _start;

  /// 站点当前相位。派生自每次轮询读到的 `FUSReader.status()`。
  ReaderPhase phase = ReaderPhase.unknown;

  /// 站点是否真的摆了人机验证。
  ///
  /// 只有一个来源：注入脚本在页面里挂 `fus:reader-check` 的监听
  /// （`reader.js:103` 派发它）。**不靠计时推断** —— 旧实现「等满 6 秒
  /// 就弹」会在站点只是慢的时候无端弹层。
  bool humanCheckSeen = false;

  /// 这一轮已经自动弹过了。收起后不再重复弹，否则用户一收就又弹回来。
  bool autoPopped = false;

  /// 验证界面是否正在显示。
  bool open = false;

  /// 这次是自动弹的（站点要人点）还是用户自己点的。
  bool auto = false;

  /// 已经等了多久。用真实时间算，不累加定时器 tick —— 定时器会被系统挂起。
  Duration get elapsed {
    final s = _start;
    if (s == null) return Duration.zero;
    return _clock().difference(s);
  }

  DateTime? get start => _start;

  /// 等太久了。
  bool get timedOut => elapsed > window;

  /// 该不该自动弹层。
  ///
  /// 条件只有一个：**站点真的摆了人机验证**，且这轮没弹过、当前没开。
  /// 站点自己能静默过的出口永远走不到这里 —— 这正是「只弹需要点的那种」。
  bool get shouldAutoPop => !autoPopped && !open && humanCheckSeen;

  /// 该不该自动收层。
  ///
  /// 站点说 ready = 会话已建立，站点的 `live.js` 会接着自己拉消息。
  /// 只对自动弹的层生效；用户手动点开的不自动收（他可能只是想看看网页）。
  bool get shouldAutoClose => open && auto && phase == ReaderPhase.ready;

  /// 开始新一轮：起算点归位。
  ///
  /// [rearm] 决定要不要把「这轮已经弹过」的闸门也解开。
  /// 用户在验证页上点了按钮之后必须重置起算点（他可能耗了一分钟以上，
  /// 接着旧起算点算的话第一次 tick 就超窗口）。但「收起」是明确表示不想过，
  /// 解开闸门会在下一次 `humanCheckSeen` 时立刻又弹回来，等于没得选，
  /// 所以那条路径传 `rearm: false`。
  ///
  /// [resetPhase] 决定要不要把站点相位和人机验证标记一起清掉。默认清 ——
  /// 「换号 / 换身份 / 换出口 / 重载」之后上一个页面的一切都作废了。
  /// 但**用户点完按钮回来的那两条路径必须传 false**：`phase == ready`
  /// 正是自动收层的唯一判据，清掉就等于把刚拿到的结论扔了。
  void begin({bool rearm = true, bool resetPhase = true}) {
    _start = _clock();
    if (resetPhase) {
      phase = ReaderPhase.unknown;
      humanCheckSeen = false;
    }
    if (rearm) autoPopped = false;
  }

  /// 落起算点，但如果已经有就不动。
  ///
  /// 换号、换身份、重载等多条路径都会调到；每次都重设会让「等满窗口」永远凑不满。
  void arm() {
    _start ??= _clock();
  }

  /// 更新站点相位。返回 true 表示相位**变了**（调用方据此只做一次副作用）。
  bool updatePhase(ReaderPhase next) {
    if (next == ReaderPhase.unknown || next == phase) return false;
    phase = next;
    return true;
  }

  /// 站点开始摆人机验证了。
  void markHumanCheck() => humanCheckSeen = true;

  /// 自动弹：显示验证界面。
  void showAuto() {
    open = true;
    auto = true;
  }

  /// 用户自己点开：显示站点页面。
  void showManual() {
    open = true;
    auto = false;
  }

  /// 收起。全 App 只有这一个收起入口。
  void close() {
    open = false;
    auto = false;
  }

  /// 记下已经弹过。
  void markPopped() => autoPopped = true;
}
