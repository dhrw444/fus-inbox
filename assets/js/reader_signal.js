// reader_signal.js — 站点验证信号的**文档起始**监听器。
//
// ## 为什么单独一份、为什么不和 fus_inbox.js 合并
//
// `fus_inbox.js` 要在 `onPageStarted` / `onPageFinished` 时才用
// `runJavaScript` 注入，因为它要读 DOM（`document.querySelector` 找收件箱
// 容器和消息卡片）。而站点派发验证信号的时间点**早于**那一刻：
//
//   live.js 首屏就发 `/sms-api/v1/inbox` → `boundedFetch` 里 `await
//   window.FUSReader.ensure()` → `establish()` → 用新密钥 POST
//   `/sms-api/v1/session` → 403 `reader_verification_required` →
//   `challenge()` **第一行**（`reader.js:103`）就
//   `document.dispatchEvent(new CustomEvent('fus:reader-check'))`
//
// 这一整串发生在页面主文档还在加载的时候，`onPageFinished` 之后才注入的
// 监听器**永远收不到那次事件**。结果是 `__fusHumanCheckSeen` 一直是 false，
// `shouldAutoPop` 永远不成立 —— 弹层不会自己冒出来。
//
// **站点不会再派发一次。** 站点里那个 30 秒（`recover()` 的
// `recoveryAt = now + 30000`）是节流器，而 `recover()` 全站没有任何调用点。
// 所以这一份不是「让弹层快一点」，是「让弹层能出来」。
//
// 所以这一份只做一件事：**在文档创建之后、站点任何脚本执行之前**把两个
// 事件监听挂上，把信号落到 window 上。不碰 DOM、不读 navigator、不依赖
// 任何资源，因此 `AT_DOCUMENT_START` 注入是安全的。
//
// ## 信号落在哪
//
//   `fus:reader-check` → `window.__fusHumanCheckCount += 1`（并置 `Seen`）
//   `fus:reader-ready` → `window.__fusReaderReadyAt = Date.now()`
//
// Dart 侧 `_readReaderStatus()` 轮询时读这两个值（见 `inbox_screen.dart`
// 的 `_ReaderStatus`）。
//
// ### 为什么是**计数**，不是只置一个布尔
//
// `__fusHumanCheckSeen` 只置位、永不复位，于是 App 侧那个「这一轮已经弹过」
// 的闩（`VerifyRound.autoPopped`）在第一次之后就再也解不开了。
//
// 代价：站点第二次开始的验证，是在**被 `Offstage` 藏起来**的 WebView 里
// 建 Turnstile 组件的。藏起来 = 平台视图设成 `GONE` → Chromium 把渲染器
// 置为 hidden → **rAF 停摆、定时器降频**。而那个组件是**跨域 iframe**，
// `browser_shim.js` 只覆写了主文档的 `document.hidden`，够不到它自己那份
// document —— 它读到的就是真的 `hidden`。
//
// 组件在停摆的渲染器里永远过不去 → 超时拆掉 → 重建 → 用户看到的就是
// 「验证界面老是自己刷新」。
//
// 记数之后，App 每读到一次增长就知道「站点又开了一轮」：只要弹层不在，
// 那一轮就重新弹出来 —— **必须在站点建组件之前把渲染器恢复成 visible**，
// 事后补是来不及的。
//
// `fus_inbox.js` 的 `boot()` 里还挂了一份同样的监听 —— 留着，不是冗余：
// 那一份覆盖「文档起始注入失败」的情况（某些内核上 `initialUserScripts`
// 不生效）。两处都写同一个 window 变量，重复自增只是数字偏大，
// 判据用的是「有没有增长」，不受影响。
(function () {
  'use strict';
  try {
    document.addEventListener('fus:reader-check', function () {
      window.__fusHumanCheckCount = (window.__fusHumanCheckCount || 0) + 1;
      window.__fusHumanCheckSeen = true;
    });
    document.addEventListener('fus:reader-ready', function () {
      window.__fusReaderReadyAt = Date.now();
    });
  } catch (e) {
    // 文档还没建好。这种情况下页面也不会派发信号，不处理。
  }
})();
