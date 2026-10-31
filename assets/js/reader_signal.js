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
// `shouldAutoPop` 永远不成立 —— App 不知道站点在等人，只能干等站点自己
// 30 秒一次的 `recover()` 重试（`reader.js:172`）再派发一次，那时脚本已经
// 装上了，弹层才「过一大会」冒出来。
//
// 所以这一份只做一件事：**在文档创建之后、站点任何脚本执行之前**把两个
// 事件监听挂上，把信号落到 window 上。不碰 DOM、不读 navigator、不依赖
// 任何资源，因此 `AT_DOCUMENT_START` 注入是安全的。
//
// ## 信号落在哪
//
//   `fus:reader-check` → `window.__fusHumanCheckSeen = true`
//   `fus:reader-ready` → `window.__fusReaderReadyAt = Date.now()`
//
// Dart 侧 `_readReaderStatus()` 轮询时读 `__fusHumanCheckSeen` 这一个布尔值
// （见 `inbox_screen.dart` 的 `_ReaderStatus`）。
//
// `fus_inbox.js` 的 `boot()` 里还挂了一份同样的监听 —— 留着，不是冗余：
// 那一份覆盖「文档起始注入失败」的情况（某些内核上 `initialUserScripts`
// 不生效）。两处都写同一个 window 变量，重复置位无害。
(function () {
  'use strict';
  try {
    document.addEventListener('fus:reader-check', function () {
      window.__fusHumanCheckSeen = true;
    });
    document.addEventListener('fus:reader-ready', function () {
      window.__fusReaderReadyAt = Date.now();
    });
  } catch (e) {
    // 文档还没建好。这种情况下页面也不会派发信号，不处理。
  }
})();
