# SMS 收件箱

一个安卓应用，打开就能看到 [freeussms.com](https://freeussms.com) 公共美国号码池的最新短信。原生界面，不套网页，不显示站点广告。

## 它做什么

- **号码目录**：直接抓站点服务端渲染的 `/numbers/` 页面，原生解析成列表。不走 WebView。
- **筛选与搜索**：按州、按区号、按「最近活跃」「有短信」筛选，支持号码/州名/区号搜索，可排序。
- **收件箱**：点进号码看该号收到的全部短信。验证码会被单独放大，一点即复制。
- **收藏**：把常用的号存下来。

## 为什么收件箱要用一个隐藏的 WebView

站点的 `/sms-api/v1/*` 接口要求浏览器会话 + 每请求的 WebCrypto 签名，签名私钥只存在于页面上下文里，外部 HTTP 客户端签不出来。所以收件箱底下常驻一个**始终不可见**的 WebView 当引擎，靠注入脚本截获它自己的接口响应，再把结果交给原生界面渲染。

站点有广告，但本应用不渲染页面，只从接口响应里挑字段重建列表，广告节点被显式跳过。只有在站点弹出人机验证、需要人工过一次时，界面才会临时露出一次页面（列表底部「卡在人机验证？」）。

## 架构

```
lib/
├── app.dart                     应用外壳：主题 + 首页
├── core/
│   ├── constants/               应用常量
│   ├── theme/                   主题（Material You 动态取色）
│   ├── utils/                   URL 归一化、串行任务队列
│   └── webview/                 跨平台 WebViewWidget 工厂
└── features/
    ├── main/                    底部导航壳
    ├── numbers/                 号码目录：抓取 / 解析 / 筛选 / 列表
    ├── inbox/                   收件箱：注入脚本截获 + 原生渲染
    └── saved/                   收藏
assets/
└── js/fus_inbox.js              收件箱注入脚本（挂钩 fetch / XHR）
```

**号码目录不依赖 WebView**：`/numbers/` 是 WordPress 服务端直出的静态 HTML，站点自己把会话签名只锁在短信正文接口上。

## 构建

需要 Flutter 3.47+ / Dart 3.13+。

```bash
flutter pub get
flutter run                       # 调试
flutter build apk --release       # 出包
```

发布流水线在 `.github/workflows/release.yml`，由 tag 或手动触发，签名信息从 GitHub Secrets 读取。

## 测试

```bash
flutter test
```

号码目录解析有真实页面快照做夹具（`test/fixtures/numbers_directory.html`），站点改模板时测试会先失败，而不是线上静默显示空列表。

## 许可

MIT。本项目由 [freedium_mobile](https://github.com/AmanSikarwar/freedium_mobile)（MIT）改造而来，原始版权声明保留在 `LICENSE` 中。
