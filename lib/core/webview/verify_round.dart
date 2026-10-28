/// 一轮「等站点验证通过」的状态机。
///
/// 纯逻辑：不碰 Timer、不碰 WebView、不碰 UI。之所以单独抽出来，是因为
/// 之前这套判断埋在 `_pumpVerification` 的定时器回调里，本地没有 Flutter
/// SDK，一行都跑不了 —— 只能靠读代码「看着对」。而这套判断恰好出过两次
/// 真错（ready 后轮询自杀、起算点被反复重置），都是读代码读不出来的。
///
/// 抽出来之后 [VerifyRound] 可以直接 import 进 tool/ 下的测试跑。
library;

class VerifyRound {
  // 带初始化列表 + 非 this 参数（`clock` 要 ?? DateTime.now），
  // 主构造器表达不了 —— 同 ProxyState / IdentityLedger 的处理。
  // ignore: use_primary_constructors
  VerifyRound({
    this.autoChallengeAfter = const Duration(seconds: 6),
    this.window = const Duration(seconds: 90),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// 静默等这么久还没 ready，就把页面放出来让用户点。
  ///
  /// 实测从加载到 ready 大约 4 秒，全程 `iframes: 0` —— 主路径是静默。
  /// 能在几秒里自己过的出口走不到这一步，所以「弹出来的必定是需要点
  /// 一下的那种」。
  final Duration autoChallengeAfter;

  /// 最多等这么久。超过就认栽，停止等待。
  final Duration window;

  final DateTime Function() _clock;

  DateTime? _start;

  /// 这一轮已经等了多久。用真实时间算，不是累加定时器 tick ——
  /// 定时器会被系统挂起（切后台、Doze），挂起期间 tick 不来，
  /// 累加值就落后于真实时间。
  ///
  /// **派生值，不是存的字段。** 以前它是 `Duration elapsed`，只在
  /// [refresh] 里被赋值，于是 [timedOut] / [shouldAutoPop] 读到的是
  /// **上一次 refresh 时的快照** —— 任何一处调用方忘了先 refresh，
  /// 超时和自动弹出就永远不触发（表现是卡在验证页等到底）。
  /// 判定依赖「调用顺序」是这类状态机最容易长出来的暗礁。
  ///
  /// 现在读一次算一次，`refresh()` 退化成「顺手返回它」（调用点不用改）。
  Duration get elapsed {
    final s = _start;
    if (s == null) return Duration.zero;
    return _clock().difference(s);
  }

  /// 站点报过 ready 了吗。
  ///
  /// 只在第一次 ready 时做一次重扫 / 搬通行证，不每 900ms 重复做。
  bool readySeen = false;

  /// 这一轮已经自动弹过了。弹出之后不再重复弹，否则用户一收起，
  /// 6 秒后又弹回来，等于没给他选。
  bool autoPopped = false;

  /// 起算点。null 表示还没开始。
  DateTime? get start => _start;

  /// 开始新一轮：起算点归位。
  ///
  /// [rearm] 决定要不要把「这轮已经弹过」的闸门也解开。
  ///
  /// 用户在验证页上点了按钮（过了 / 收起）之后必须重置起算点 ——
  /// 他可能在人机验证上耗了一分钟以上，接着旧起算点算的话第一次
  /// tick 就超 [window]，当场判超时，明明刚说「我过了」反而放弃。
  ///
  /// 但闸门不能一律解开：点「收起」是明确表示不想过，解开就会在
  /// [autoChallengeAfter] 之后立刻又弹回来，等于没得选。所以那条
  /// 路径传 `rearm: false`。
  void begin({bool rearm = true}) {
    _start = _clock();
    readySeen = false;
    if (rearm) autoPopped = false;
  }

  /// 落起算点，但如果已经有就不动。
  ///
  /// [_pumpVerification] 会被换号、换身份、重载等多条路径调到，每次都
  /// 重设起算点会让「等满 [autoChallengeAfter]」永远凑不满。
  void arm() {
    _start ??= _clock();
  }

  /// 刷新 [elapsed]。每个 tick 调一次。
  /// 保留这个入口只为兼容调用点（每个 tick 调一次）—— [elapsed] 现在
  /// 自己就是真值，这里没有「刷新」可做。
  Duration refresh() => elapsed;

  /// 等太久，该停了。
  bool get timedOut => elapsed > window;

  /// 第一次 ready 时返回 true，之后一直 false。
  ///
  /// ready 只说明 FUSReader 的会话建好了，**不代表**站点肯把消息给你 ——
  /// 新开的号、刚被限流的 IP、页面上还压着没点的人机验证，都会「ready
  /// 了但消息一直不来」。所以这里不负责结束等待，只负责「第一次」。
  bool markReady() {
    if (readySeen) return false;
    readySeen = true;
    return true;
  }

  /// 该不该自动弹出。
  ///
  /// 调用方还要自己 AND 一个 `!_showChallenge`（那是 UI 状态，不在
  /// 这个对象里）。这里只管「等够了、且这轮还没弹过」。
  bool get shouldAutoPop => !autoPopped && elapsed >= autoChallengeAfter;

  /// 记下已经弹过。
  void markPopped() => autoPopped = true;
}
