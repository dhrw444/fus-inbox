/// 浏览器身份。
///
/// 值类型见 `identity_profile.dart`；UA 解析见 `identity_parse.dart`
/// （都在这里转出去，引用方不用多写一行 import）。
///
/// 这个文件只做一件事：**持有当前身份，并在需要时换一个**。
/// 谁都不能绕过它直接拼 UA / client hints —— 唯一的 `_current` 在这里。
///
/// ## 为什么不再随机编 UA
///
/// 之前这里有一批手写的「真实 Chrome UA」，用户点「换身份」就换一个。
/// 那个思路是错的，而且**越换越容易被风控**：
///
///   - `Android 13; K` —— `K` 是 Chrome UA 缩减（UA Reduction）后的
///     占位机型。缩减版固定写 `Android 10`。写 13 是自相矛盾。
///   - `Chrome/120.0.0.0` —— 末两段全 0 是模拟器的默认版本号，
///     真 Chrome 从来不是这个形态。
///   - 最致命的是**和 client hints 撕裂**：WebView 引擎的
///     `Sec-CH-UA` / `Sec-CH-UA-Full-Version` 由内核按真实版本发出，
///     Dart 侧改不掉。于是请求变成「UA 说 Chrome 120、
///     Sec-CH-UA 说 Chrome 141」，这是比不伪装更明显的机器特征。
///
/// ## 现在怎么做
///
/// 全部取自 WebView 自己报的那串（`WebSettings.getDefaultUserAgent`），
/// 它是这台设备上**真实存在**的浏览器版本和真实机型串：
///
///   - UA 的 Chrome 版本 = 真实内核版本
///   - `Sec-CH-UA` 的版本 = 同一个版本
///   - 机型串 = 真实机型
///
/// 唯一需要加工的是剥掉 WebView 的招牌（`; wv` 标记和
/// `Version/4.0` 那段），否则 UA 自己就写着「我是 WebView」。
///
/// 「换身份」保留，但只换机型串和版本，且仍然自洽——用户手动点的时候
/// 站点可能已经把这个身份记进风控名单，换一个能重新开始。
library;

import 'dart:math';

import 'package:fus_inbox/core/webview/identity_parse.dart';
import 'package:fus_inbox/core/webview/identity_profile.dart';

export 'package:fus_inbox/core/webview/identity_parse.dart';
export 'package:fus_inbox/core/webview/identity_profile.dart';

/// 当前身份。
///
/// 默认是设备真实身份。用户点「换浏览器身份」时会换一个**仍然自洽**的
/// 组合：换机型串和 Chrome 版本，但 UA 和 client hints 永远同步变。
BrowserIdentity _current = BrowserIdentity.fallback;

BrowserIdentity get currentIdentity => _current;

/// 设备真实内核的 Chrome 大版本。
///
/// **换身份时浮动的唯一基准**，必须不可被 [rotateIdentity] /
/// [mintIdentity] 覆盖。
///
/// 之前它们拿 `_current.chromeMajor` 当基准 —— 那正是自己上一次的输出，
/// 于是每换一次身份就是一次带负漂的随机游走（`r.nextInt(4) - 2` 取值
/// {−2,−1,0,+1}，均值 −0.5）。实测从内核 141 起：约 85 次跌破 Chrome 100，
/// 约 290 次变成 0 或负数，而 `identityToJson` 还会把这个值落盘、
/// 跨重启继续漂。表现就是「Android 16 的机器装着 2020 年的 Chrome」，
/// 和真内核越差越远 —— 换身份这个功能从降低风控变成制造矛盾。
int? _kernelMajor;

/// 当前记着的内核大版本。没探测到过就是 null。
int? get kernelMajor => _kernelMajor;

/// 记下真实内核大版本。**只在原生探测到 UA 时调用**。
///
/// 不要从 [_current] 推 —— 那是浮动的结果，不是基准。
void noteKernelMajor(String major) {
  final v = int.tryParse(major);
  if (v != null && v > 0) _kernelMajor = v;
}

/// 用原生探测到的真实身份初始化。App 启动时调用一次。
///
/// 注意这里**不**动 [_kernelMajor]：调用方可能传进来的是磁盘上那份
/// 已经被轮换漂过的身份，拿它当基准就等于把漂移固化。
/// 基准一律走 [noteKernelMajor]。
void initBrowserIdentity(BrowserIdentity identity) {
  _current = identity;
}

/// 从磁盘恢复上次的身份。
///
/// 必须持久化，不能每次启动都回到设备真实值：
/// 站点给每个身份发一对 reader 密钥（存在 IndexedDB 里），密钥是**跟着
/// 身份走**的。重启后身份变回真实机型、密钥还是那一对，等于「同一个人
/// 换了台设备又拿旧密钥来」，比不换更显眼。
///
/// 代理账本也依赖这一点：它记着「出口 A 用身份 X」，重启后身份若变了，
/// 那条记录就是假的 —— 新出口会拿到一个站点已经见过的身份。
void restoreIdentity(BrowserIdentity identity) {
  _current = identity;
}

/// UA 字符串。收件箱 WebView 和所有原生 HTTP 都用这一个。
String get currentUserAgent => _current.userAgent;

/// 换一个身份。
///
/// 和旧实现的区别：旧版是**只换 UA、client hints 不变**，
/// 那正是撕裂的来源。现在 UA 和 hints 一起换，始终自洽。
///
/// 机型串从 [knownModels] 里挑，Chrome 版本在真实版本附近浮动
/// （±2 个大版本，都在真实存在的范围内）。
BrowserIdentity rotateIdentity([Random? rnd]) {
  final r = rnd ?? Random();
  final base = _current;

  // 基准见 [_mintFrom]：一律用内核真值，不用上一次的输出。
  _current = _mintFrom(base, r);
  return _current;
}

/// 生成一个**新**身份但不切换当前身份。
///
/// 和 [rotateIdentity] 的区别只在于「不写 [_current]」。账本要在「造
/// 新身份」时先记下来，等代理真的设上了才应用；如果这里直接切，代理
/// 失败时页面已经被换成了新身份，却还挂在旧出口上 —— 一次白烧。
///
/// 之前 `_planForThisNumber` 的 mint 回调传的是 `currentIdentity.xxx`，
/// 于是账本记下的「新身份」和当前身份**一模一样**：换到一条干净出口上，
/// 新 IP 配旧 UA，站点那边看到的是「同一个人换了条线路」。
BrowserIdentity mintIdentity([Random? rnd]) {
  final r = rnd ?? Random();
  final base = _current;

  return _mintFrom(base, r);
}

/// 按 [base] 平台版本 + 内核基准造一个自洽的新身份。
///
/// [rotateIdentity] 和 [mintIdentity] 的唯一差别是「写不写 `_current`」，
/// 造身份这一步是同一个 —— 以前两处各写一份，改一处忘另一处就会造出
/// 两种不同规则的「新身份」。
///
/// 基准一律取 [_kernelMajor]（原生探测到的内核真值）。取 `base.chromeMajor`
/// 等于拿自己上一次的输出当输入，会单向漂移。
/// UA 里的安卓版本必须是 `14` / `14.0` 那个形状。
///
/// **和 `identity_profile.dart` 的 `platformVersionHint` 不是一回事**：
/// 那个是 client hints 的 `platform-version`（要 `14.0.0` 四段），
/// 这个是 UA 里的安卓大版本（只要 `14`）。两个字段形状本来就不同。
///
/// 空串会拼出 `Android ;`、四段式会拼出 `Android 10.0.0` —— 两个都是畸形
/// UA。认不出形状就用内核真值现推。
String _androidVersion(String raw) {
  if (RegExp(r'^\d{1,2}(\.\d{1,2})?$').hasMatch(raw)) return raw;
  return platformVersionFromUserAgent(currentIdentity.userAgent);
}

BrowserIdentity _mintFrom(BrowserIdentity base, Random r) {
  final baseMajor = _kernelMajor ?? int.tryParse(base.chromeMajor) ?? 141;
  // 对称窗口 {−2..+2}，期望 0。原来是 `r.nextInt(4) - 2` = {−2,−1,0,+1}，
  // 均值 −0.5，每换一次身份就往下漂半个大版本。
  final major = baseMajor + r.nextInt(5) - 2;
  final version = '$major.0.${6000 + r.nextInt(4000)}.${r.nextInt(200)}';

  // ── Windows：桌面 UA。没有机型位，也不是 mobile ──
  //
  // 桌面 Chrome 的 UA 长这样（Win64 是 64 位 Windows 的固定段）：
  //   Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36
  //   (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36
  //
  // 这里**只随机大版本**：桌面 UA 里没有机型可换，能变的就是版本号。
  // 以前不分平台，在 Windows 上也去 `_knownModels`（全是安卓机型）里抽一个
  // 塞进 UA —— 那正是「安卓机身串 + WebView2 引擎」这种自相矛盾的来源。
  if (base.platform == BrowserIdentity.platformWindows) {
    return BrowserIdentity(
      userAgent:
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
          'AppleWebKit/537.36 (KHTML, like Gecko) '
          'Chrome/$version Safari/537.36',
      chromeMajor: '$major',
      model: '',
      // 真 Chrome 在 Windows 上发 `"10.0.0"`（完整四段式）。
      platformVersion: base.platformVersion,
      isMobile: false,
      platform: BrowserIdentity.platformWindows,
    );
  }

  final model = _knownModels[r.nextInt(_knownModels.length)];

  return BrowserIdentity(
    userAgent:
        'Mozilla/5.0 (Linux; Android ${_androidVersion(base.platformVersion)}'
        '; $model) '
        'AppleWebKit/537.36 (KHTML, like Gecko) '
        'Chrome/$version Mobile Safari/537.36',
    chromeMajor: '$major',
    model: model,
    platformVersion: base.platformVersion,
    isMobile: true,
  );
}

/// 按账本里记的身份还原当前身份。
///
/// 账本记着「出口 A 用身份 X」，重启或换号时如果还沿用它，页面就必须
/// 真的用 X 的 UA。否则账本记的是假的：站点看到的是另一个身份，本地
/// 却按 X 算额度，两边对不上，轮转全乱。
///
/// 之前 [IdentityBinding] 的 userAgent / model / chromeMajor 是**只写
/// 不读**的死字段 —— 全仓 `setUserAgent` 只有两处，一处读
/// [currentUserAgent]，一处读 [rotateIdentity] 现造的，没有任何地方
/// 从账本取值。所以「切回原出口原身份」实际只切了出口，身份那半截
/// 从来没实现过。
///
/// 老数据里 model / chromeMajor 可能是空串（早期版本没记），那就从
/// UA 里现解 —— 宁可解出来，也不要拿空值去拼一个自相矛盾的 client
/// hints 组合。
void applyBoundIdentity({
  required String userAgent,
  required String model,
  required String chromeMajor,
}) {
  if (userAgent.isEmpty) return;
  final m = model.isNotEmpty ? model : modelFromUserAgent(userAgent);
  final major = chromeMajor.isNotEmpty
      ? chromeMajor
      : chromeMajorFromUserAgent(userAgent);
  // 平台必须从 UA 现解，不能写死安卓 —— 账本里存的可能就是一条 Windows
  // 身份（换平台、或者用户在 Windows 上用过这个号）。写死的话，
  // 「切回原出口原身份」会把一条桌面 UA 配上 `Sec-CH-UA-Platform: "Android"`。
  final desktop = isDesktopUserAgent(userAgent);
  _current = BrowserIdentity(
    userAgent: userAgent,
    chromeMajor: major,
    model: m,
    platformVersion: platformVersionFromUserAgent(userAgent),
    isMobile: !desktop,
    platform: desktop
        ? BrowserIdentity.platformWindows
        : BrowserIdentity.platformAndroid,
  );
}

/// 真实存在的 Android 机型串。
///
/// 都是 `Build.MODEL` 的合法值，不是编的营销名。
const _knownModels = <String>[
  'SM-S918B',
  'SM-S928B',
  'SM-A546E',
  'SM-G991B',
  'Pixel 7',
  'Pixel 8',
  'Pixel 8 Pro',
  'CPH2451',
  'CPH2581',
  '2201117TY',
  '22101316G',
  'V2227A',
  'RMX3630',
  'M2101K7AG',
  'LE2121',
  'NE2211',
];
