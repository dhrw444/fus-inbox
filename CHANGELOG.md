# Changelog

本项目的所有重要变更记录在这里。

## [Unreleased]

### Added

- **Windows 目标**：`windows/` runner 是 Flutter 生成的标准产物，零自定义平台代码；
  CI 与发布流水线各加了一个 Windows job。运行时需要目标机器装 Microsoft Edge WebView2
  运行时，缺了会在启动时给一句明确提示，而不是白屏（见 `lib/platform/web_engine_factory.dart`）。
- **代理池与身份轮换**：一个代理绑一个浏览器身份，一个身份最多看 3 个号，满了换出口 + 换身份。
  站点配额记在出口 IP 上，只换身份没有用（实测同一 IP 换身份后第 4 个号照样被拒）。
  因为 WebView 的代理规则串带不出账号密码，SOCKS5 走本机 HTTP 桥（CONNECT → SOCKS5，RFC 1928/1929）。
- **短信正文翻译**：微软 / 谷歌 / Yandex 三家降级链，可开关；首选那家不通会自动换下一家。
- 号码目录磁盘缓存、号码「首次收录时间」、设置页（外观 / 短信 / 代理 / 存储 / 关于）。

- **`lib/core/theme/util.dart` 的 `createTextTheme` 是假的**：它收两个字体名然后
  直接返回 `Typography.englishLike2021`，一个参数都没用上。Windows 上没有 Roboto，
  系统回落到 Segoe UI，而字重行高全按 Roboto 度量算 —— 用户只觉得「Windows 版字有点怪」，
  看不出原因。现在真的把字体族套到 `TextTheme` 上。
- **`IdentityRotator.rotateIdentity` 没有重入闸**：AppBar 上那个按钮直接绑它，
  用户连点两下就并发清库 + 并发换 UA + 并发导航，站点看到的是自相矛盾的访客。
  现在入口加闸，内部路径直调 `_rotateIdentityBody`（否则会被自己的闸门锁死）。
- `inbox_screen.dart` 两处 doc 注释和函数对不上：`_rescan` 挂着「手动验证时的底栏」的说明
  （那是 `ChallengeBar` 的），`_syncClearance` 前面混着 `_rescan` 的说明。
- `platform_channel.dart` 的注释说挂了「三件事（含读 Android SDK 版本）」，
  实际 Kotlin 侧只剩两个 handler —— 那个方法早随死代码删了。
- `MainActivity.kt` 有一段「读某个 URL 下的全部 cookie」的孤儿 doc 注释，
  底下没有对应函数（读 cookie 早改成 `WebEngine.readCookies`）；另一处注释还引用着
  已删除的 `BrowserShim.kt`。
- `assets/js/fus_inbox.js` 里 `window.FusInbox.postMessage` 是废分支 ——
  `addJavascriptInterface` 那条路随 `BrowserShim.kt` 一起删了，只剩 `callHandler` 活着。
  留着会让人以为「两条通道都能走」，改通道名时只改一条就静默失效。
- `rotateIdentity` / `mintIdentity` 造身份那段代码写了两遍（只差「写不写 `_current`」），
  合并成 `_mintFrom`。

- **`ProxyState.canRotate` 会误报「没有别的出口可换」**：判据原来是
  「可用条数 > 1」，两种常见情况会判错 ——（a）池里 2 条、检测判死 1 条，
  可用只剩 1 条而它**不是**当前出口，本来完全能换，用户却被卡在烂出口上；
  （b）全池判死时它说不能换，可 `pickRotation` 的规则是「宁可用可疑代理，
  不裸奔直连」，两条规则互相矛盾。现在两边都走
  `IdentityLedger.nextUsableProxy`，规则只有一处定义。
- **`ProxyNotifier._persist` 在等超时之后仍然落盘**：它等 `ready`（带 3 秒
  兜底超时）之后无条件写盘。读盘卡过 3 秒时 `loaded` 仍是 false，写下去的
  是空池 —— 正是上面那段注释拼命要防的「拿出厂默认值覆盖用户数据」。
  现在等完复查一次，没读完就不写。
- **本地桥的 HTTP 状态行写成了 `HTTP/1.1 502 X`**：第三段 reason phrase
  是个漏下来的字面量 `X`。RFC 之后客户端不该解析它，但它是报文的一部分，
  抓包和日志里就是坏数据。现在按码给标准短语。
- **SOCKS5 认证响应没校验版本字节**：方法协商那步判了 `VER==0x05`，
  RFC 1929 的认证响应却没判 `VER==0x01` —— 只看第二个字节，
  对端回一段别的东西会被当成认证成功。两处现在对称。
- 全项目的 SharedPreferences 键收进 `lib/core/prefs/storage_keys.dart`。
  原先 9 个键散在六个文件、用了**五套**命名风格（`fus:x:y:v1` /
  `x_y_v1` / `x.y.v1` / `pref_x` / 裸名）。统一成 `fus:<区>:<名>:v1`，
  并给 8 个改过名的键带上旧名回落 —— 不带的话升级会**静默清空**用户
  已有的代理池、身份和设置。
- `ProxyNotifier._persist` / `local_http_bridge` 的两处空 `catch` 补上理由。

- **日志出口不统一，而且日志库把测试拖垮**：全项目 27 处 `debugPrint` 各自
  `import flutter/foundation`，而那个库顶层 `export 'dart:ui'` —— 只要有**一处**
  引到，整条 import 链就不能在纯 Dart VM 里编译，`tool/` 下用 `dart run` 跑的
  实测脚本会全部报 `Dart library 'dart:ui' is not available on this platform`。
  现在统一走新建的 `lib/core/log.dart`（只依赖 `dart:io`），13 个文件删掉了
  foundation 依赖；只需要 `visibleForTesting` 的两处改用 `package:meta`。
- **`lib/features/numbers/data/directory_page.dart` 有个死 import**：
  `flutter/foundation` 一个符号都没用，但就是它一条让
  `tool/numbers_egress_test.dart`（验「代理不可用时不能泄漏真实 IP」）编译不过、
  静默失效。删掉后测试立刻能跑（10 项通过）。
- **存储键真正的数量比我以为的多**：除了原先那 9 个，`directory_cache` 和
  `first_seen` 里还各藏了一个 `_kCacheKey`（`number_dir_cache_v1` /
  `number_first_seen_v1`）。全部 17 个键收进 `lib/core/prefs/storage_keys.dart`，
  并给 `StorageKey` 补了 `remove`（**新旧键都删** —— 只删新键的话，旧键还在
  磁盘上，一旦新键读不到，刚「清除」的数据会复活）。
- **`numbers/domain/first_seen.dart` 违反了自己项目的分层**：它待在 domain 层
  （纯逻辑、刻意不依赖框架以便本地测试，见 `number_sort.dart` 的注释），
  却带着 SharedPreferences、HttpClient 和两个 provider。已拆开 ——
  纯解析留 `domain/first_seen.dart`，抓取/缓存/provider 移到
  `application/first_seen_store.dart`。拆完那段解析**第一次有了测试**
  （`tool/first_seen_test.dart`，16 项，含「必须按 UTC 解不能按本地」和
  「别把最后一条短信时间当收录时间」）。
- 复制整条短信时 SnackBar 会把**整条正文**贴出来（长短信糊满屏幕）。
  现在超过 24 字只报「已复制整条短信」，内容已经在剪贴板里了。
- 状态栏文案句末标点不统一：统一成「完整句加 `。`、进行时加 `…`」。

### Changed

- `tool/` 从 19 个入口收成 2 类：纯逻辑的收进 `tool/gate.dart` 一条命令跑完（10 段），
  要真网络/真 socket 的各自单独跑。删掉三个问题已经回答完的一次性探针。
  各脚本的尾行格式统一成 `N passed, M failed`，`exit()` 只在失败时调 ——
  否则会把整条 gate 一起杀掉。
- `test/` 下 10 个文件补上统一文件头（原先 4 个有、6 个直接以 import 开头），
  `package:` 段按字母重排。

- 从底层项目剥离文章阅读器、书签、历史、镜像切换、分享接管等与接码无关的功能，
  只保留号码目录、收件箱与收藏三条主线 —— 代理、翻译、设置是之后加上去的。
- 应用身份统一：`applicationId` / `namespace` / Dart 包名均为 `fusinbox` 系列，
  启动图标、应用名、README 一并替换。
- **WebView 引擎从 `webview_flutter` 换成 `flutter_inappwebview`**：前者到 4.14.1
  仍然只有 android / ios / macos，没有 Windows 实现。收件页从此不直接依赖任何 WebView 包 ——
  抽象在 `lib/platform/`（`WebEngine` / `WebEngineFactory`），换包只动那三个文件。
- 手写的 `ProxyControllerBridge.kt` 删除，改用 `flutter_inappwebview` 自带的 `ProxyController`；
  浏览器垫片从「原生通道 → Kotlin 拼 JS」改成一份两端共用的静态 JS（`assets/js/browser_shim.js`）。
- 号码目录改为原生 HTTP 抓取 + 正则解析（`/numbers/` 是服务端直出，不需要会话签名），不再走 WebView。
- 站点时间串统一按 UTC 解析：目录页的 `data-rel-time` 没有时区后缀，按本地时区解会整整偏 8 小时。
- 出网出口收敛成 app 级**一条常驻**本机桥，号码目录与收件页共用同一条；换出口只换桥的上游，
  不再重建桥 —— Windows 上 WebView2 的代理是环境参数、改不了，这是它的前提。

### Fixed

- 号码目录与收录时间挂上 `findProxy`：不挂时请求照常成功、SOCKS5 侧连接数为 0，泄漏是静默的；
  现在出口不可用时请求直接失败，绝不退回直连。
- 身份版本号单向漂移：`rotateIdentity` / `mintIdentity` 原来拿「自己上一次的输出」当基准
  （期望 −0.5 的随机游走），现在一律以原生探测到的内核大版本为基准。
- 收件箱 WebView 增加主机白名单：`FusInbox` 通道只对 `freeussms.com` 的页面开放。
- 页面销毁时释放 WebView 引擎并断开状态回调。
- 验证码兜底提取增加语义门，避免把订单号、金额当成验证码。
- 注入脚本改为单个 Future 缓存，首屏不再重复读取资源。
- 号码目录解析失败时显式报错，不再显示成「没有号码」。
