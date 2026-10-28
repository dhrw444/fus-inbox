# SMS 收件箱

一个 Flutter 应用（Android + Windows），打开就能看到 [freeussms.com](https://freeussms.com) 公共美国号码池的最新短信。原生界面，不套网页，不显示站点广告。

## 它做什么

- **号码目录**：直接抓站点服务端渲染的 `/numbers/` 页面，原生解析成列表。不走 WebView。
- **筛选与搜索**：按州、按区号、按「最近活跃」「有短信」筛选，支持号码/州名/区号搜索，可排序。
- **收件箱**：点进号码看该号收到的全部短信。验证码会被单独放大，一点即复制。
- **收藏**：把常用的号存下来。
- **代理与身份轮换**：站点的配额记在**出口 IP** 上，所以配一堆 SOCKS5，App 自己轮 ——
  一个代理绑一个浏览器身份、一个身份最多看 3 个号，满了就换出口 + 换身份。见 `lib/core/proxy/`。
- **正文翻译**：微软 / 谷歌 / Yandex 三家降级链，可开关，见 `lib/core/translate/`。

## 为什么收件箱要用一个隐藏的 WebView

站点的 `/sms-api/v1/*` 接口要求浏览器会话 + 每请求的 WebCrypto 签名，签名私钥只存在于页面上下文里，外部 HTTP 客户端签不出来。所以收件箱底下常驻一个**始终不可见**的 WebView 当引擎，靠注入脚本截获它自己的接口响应，再把结果交给原生界面渲染。

站点有广告，但本应用不渲染页面，只从接口响应里挑字段重建列表，广告节点被显式跳过。只有在站点弹出人机验证、需要人工过一次时，界面才会临时露出一次页面（列表底部「卡在人机验证？」）。

## 支持的平台

| | Android | Windows |
|---|---|---|
| WebView 内核 | `flutter_inappwebview` → 系统 WebView | `flutter_inappwebview` → WebView2 |
| 前提 | 系统自带 | 目标机器要装 **Microsoft Edge WebView2 运行时**，缺了会在启动时给一句明确提示（见 `lib/platform/web_engine_factory.dart`） |
| 代理 | `ProxyController` 运行时覆盖 | WebView2 的环境参数，进程启动时定一次 |

两端共用同一套抽象与同一份伪装：WebView 抽象在 `lib/platform/`，浏览器垫片是一份静态 JS（`assets/js/browser_shim.js`），Android 和 Windows 装的是同一份。

## 架构

```
lib/
├── main.dart                    启动顺序：探身份 → 起常驻桥 → 初始化 WebView 环境
├── app.dart                     应用外壳：主题 + 首页
├── core/
│   ├── constants/               应用常量
│   ├── log.dart                 全项目唯一的日志出口（只有它不依赖 Flutter）
│   ├── prefs/                   用户偏好；storage_keys.dart 是**全部存储键**的唯一定义处
│   ├── proxy/                   代理池、身份账本、本机 HTTP→SOCKS5 桥
│   ├── theme/                   主题（Material You 动态取色 + 六套内置配色）
│   ├── time/                    站点时间串解析（那些不带时区后缀的 UTC）
│   ├── translate/               短信正文翻译（传输层 + 三家引擎 + 降级链）
│   └── webview/                 浏览器身份、垫片、原生请求头、验证状态机
├── features/
│   ├── main/                    底部导航壳
│   ├── numbers/                 号码目录：抓取 / 解析 / 筛选 / 列表
│   │                            （domain/ 是纯逻辑，不依赖框架，本地可测）
│   ├── inbox/                   收件箱：注入脚本截获 + 原生渲染
│   ├── saved/                   收藏
│   └── settings/                设置页（外观 / 短信 / 代理 / 存储 / 关于）
└── platform/                    WebView 引擎抽象 + 各平台实现
tool/
├── gate.dart                    纯逻辑门禁：一条命令跑完 12 段检查
└── *_test.dart                  要真 socket / 真网络的实测脚本，各自单独跑
assets/
├── js/                          收件箱注入脚本、浏览器垫片（挂钩 fetch / XHR）
└── proxies/builtin.txt          内置 SOCKS5 清单
```

**号码目录不依赖 WebView**：`/numbers/` 是 WordPress 服务端直出的静态 HTML，站点自己把会话签名只锁在短信正文接口上。目录和收录时间走 `dart:io` 的 `HttpClient`，并自己挂 `findProxy` 走同一条出口 —— 不挂就是静默直连，真实 IP 会被交出去一次。

## 构建

需要 Flutter 3.47.5+ / Dart 3.13+。

```bash
flutter pub get
flutter run                        # 调试
flutter build apk --release        # Android 出包
flutter build windows --release    # Windows 出包（要在 Windows 主机上，需 MSVC + Windows SDK）
```

发布流水线在 `.github/workflows/release.yml`，由手动触发（`workflow_dispatch`）或推送 `main` 触发，签名信息从 GitHub Secrets 读取；Android 出 arm64 APK，Windows 出一个 zip。CI 在 `.github/workflows/ci.yml`，多平台验证见里面对 Windows 的那两个 job。

`tool/` 下是框架外的实测脚本。纯逻辑那部分收在一个入口里：

```bash
dart run tool/gate.dart      # 账本 / 代理配置 / 身份 / 状态机 / 排序 / 收录时间解析，12 段
```

要真网络或自己起假服务器的（`bridge_test`、`socks5_test`、`bridge_upstream_test`、
`translate_live_test`）各自单独跑，它们会真开 socket。

## 测试

```bash
flutter test
```

号码目录解析有真实页面快照做夹具（`test/fixtures/numbers_directory.html`），站点改模板时测试会先失败，而不是线上静默显示空列表。

## 许可

MIT。本项目由 [freedium_mobile](https://github.com/AmanSikarwar/freedium_mobile)（MIT）改造而来，原始版权声明保留在 `LICENSE` 中。
