// 浏览器能力垫片（跨平台版）。
//
// ## 为什么需要它
//
// 各家的 WebView 内核**都不提供**三样真 Chrome 一定有、而 Cloudflare
// Turnstile 一定会查的东西：
//
//   navigator.userAgentData  → undefined（client hints 的 JS 入口）
//   window.chrome            → undefined（Chrome 的命名空间）
//   navigator.plugins        → 长度 0（Chrome 内置 5 个 PDF 插件）
//
// 缺任何一个，UA 写得多像都会被判成伪装的浏览器 —— 这正是「只换 UA
// 反而更容易被风控」的根源。
//
// ## 从 Kotlin 搬到这个文件的原因
//
// 原来这段脚本烧在 `BrowserShim.kt` 里，只有 Android 有。加了 Windows
// 之后不能再这么干：同一份伪装必须两端一致，否则「Android 上是 Chrome、
// Windows 上是 WebView2」本身就是个能被串联的特征。
//
// ## 时序
//
// 由宿主通过 `injectOnDocumentStart` 注入，时机是**文档创建后、页面任何
// 脚本执行前**。站点自己的 reader.js / live.js / Turnstile 拿到的已经是
// 补齐后的 navigator。
//
// ## 一条铁律
//
// 这里所有值都必须和宿主传进来的身份**同源**：UA 里的版本号 =
// userAgentData.brands 的版本号 = 原生请求头里的 Sec-CH-UA 版本号。
// 只要一处对不上，垫片自己就变成新的矛盾点。
//
// ## 兜底值
//
// 下面的 `SEED` 由宿主注入（`window.__fusSeed`）。它只在**整个 UA 解不出
// 身份**时才用得上 —— 正常情况下所有值都从当下那串 UA 现推。
// 为什么坚持现推：注入是**只能加、不能删**的（脚本开头有
// `__fusShimmed` 守卫，先装的那份永远赢），烧死版本号会停在上一次的身份
// 上，而且每换一次身份就多累积一层矛盾。
(function () {
  'use strict';
  if (window.__fusShimmed) return;
  window.__fusShimmed = true;

  // 宿主注入的兜底值（见文件头的「兜底值」一节）。
  // 正常情况下用不到 —— 所有值都从下面那串 UA 现推。
  var SEED = window.__fusSeed || {};

  // ---- 身份值：从当下的 UA 现推，不烧进脚本 ----
  //
  // 为什么不能烧：`addDocumentStartJavaScript` **只能加、不能删**
  // （webkit 1.14.0 里没有 removeDocumentStartJavaScript，已 javap 核实），
  // 而本脚本开头有 `if (window.__fusShimmed) return;` —— 于是**先装的那份
  // 永远赢**，后面重装多少次都无效。
  //
  // 后果：换身份时 Dart 用 setUserAgent 把 UA 换了，脚本里烧死的版本没换，
  // navigator.userAgentData 就停在上一次的身份上 —— 而且这个矛盾**每换一次
  // 就累积一层**。改成自推就没有「旧」这个概念：每个文档加载时读的都是
  // 当下那串 UA，装一次管到底。
  //
  // 下面 $ 开头的是装机时那组值，只在整个 UA 解不出来时兜底。
  var UA = navigator.userAgent || '';
  var uaChrome = /Chrome\/([\d.]+)/.exec(UA);
  var uaParen = /\(([^)]*)\)/.exec(UA);
  var FULL = uaChrome ? uaChrome[1] : (SEED.full || '');
  var MAJOR = FULL.split('.')[0] || (SEED.major || '');
  var PLATFORM = /Android/i.test(UA) ? 'Android' : (SEED.plat || 'Android');
  // UA 里连 Chrome 标记都没有 = 整串解不出来，这时才用装机时的值。
  var MOBILE = /Chrome\//.test(UA) ? /Mobile/i.test(UA) : SEED.mobile;
  var PLATFORM_VERSION = (SEED.pv || '');
  var MODEL = (SEED.mdl || '');
  if (uaParen) {
    var segs = uaParen[1].split(';');
    // "(Linux; Android 14)" —— 只有两段就是 UA 本身没有机型。
    // 这时给空串（**和 UA 保持一致**），绝不退回装机时那个机型：
    // 机型在换身份时是会变的，退回旧值等于又造一处矛盾。
    MODEL = segs.length >= 3
      ? segs[2].trim().replace(/\s+Build\/.*$/, '')
      : '';
    if (segs.length >= 2) {
      var av = segs[1].trim().split(/\s+/);
      // 补成三段。UA 里是 "Android 16"，但 client hints 的
      // Sec-CH-UA-Platform-Version 是三段（原生头那边发的是
      // 平台版本拼上 .0.0）—— 推成两段等于把 F3 修好的
      // 那处不一致又造回来。
      //
      // 注意：这行是 Kotlin 原始字符串内部，美元符号会被当插值。
      // 上面那句原来是从 Dart 注释直接粘的、带了花括号插值写法，
      // 编译期就被当成 Kotlin 插值，报 Unresolved reference 'id'。
      // 同理：注释里连空的插值花括号也别写，那是语法错
      // （Expecting an expression）。这段注释本身就不含美元符号。
      if (av.length >= 2) {
        PLATFORM_VERSION = av[1].indexOf('.') < 0 ? av[1] + '.0.0' : av[1];
      }
    }
  }

  // 品牌表**由宿主注入**（Dart 侧的 `BrowserIdentity.brandsFor`）——那边是
  // 唯一来源。以前这里硬编码一份、Dart 拼请求头又一份，Chrome 每版换
  // GREASE 品牌时必然只改一边：请求头说一套、页面里 userAgentData 说另一套。
  //
  // 下面的兜底只在种子缺席时（旧包、或注入被挡）用，取值和 Dart 侧一致。
  // GREASE 值：Chrome 每版会换一个 "Not?A_Brand" 之类的占位品牌，
  // 真 Chrome 一定有这一项，缺了反而是特征。
  var SEED_BRANDS = (SEED.brands && SEED.brands.length) ? SEED.brands : null;
  var BRANDS = SEED_BRANDS
    ? SEED_BRANDS.map(function (b) {
        return { brand: b.brand, version: b.version };
      })
    : [
        { brand: 'Chromium', version: MAJOR },
        { brand: 'Google Chrome', version: MAJOR },
        { brand: 'Not?A_Brand', version: '99' }
      ];
  var FULL_LIST = SEED_BRANDS
    ? SEED_BRANDS.map(function (b) {
        return { brand: b.brand, version: b.fullVersion };
      })
    : [
        { brand: 'Chromium', version: FULL },
        { brand: 'Google Chrome', version: FULL },
        { brand: 'Not?A_Brand', version: '99.0.0.0' }
      ];

  // ---- navigator.userAgentData ----
  if (!('userAgentData' in navigator)) {
    var highEntropy = {
      architecture: 'arm',
      bitness: '64',
      brands: BRANDS,
      fullVersionList: FULL_LIST,
      mobile: MOBILE,
      model: MODEL,
      platform: PLATFORM,
      platformVersion: PLATFORM_VERSION,
      uaFullVersion: FULL,
      wow64: false
    };

    var uaData = {
      brands: BRANDS,
      mobile: MOBILE,
      platform: PLATFORM,
      getHighEntropyValues: function (hints) {
        return new Promise(function (resolve) {
          var out = {};
          var want = hints || [];
          for (var i = 0; i < want.length; i++) {
            var k = want[i];
            if (Object.prototype.hasOwnProperty.call(highEntropy, k)) {
              out[k] = highEntropy[k];
            }
          }
          // 真 Chrome 的返回里一定带 brands / mobile / platform。
          out.brands = BRANDS;
          out.mobile = MOBILE;
          out.platform = PLATFORM;
          resolve(out);
        });
      },
      toJSON: function () {
        return { brands: BRANDS, mobile: MOBILE, platform: PLATFORM };
      }
    };

    try {
      Object.defineProperty(navigator, 'userAgentData', {
        get: function () { return uaData; },
        configurable: true,
        enumerable: true
      });
    } catch (e) {}
  }

  // ---- window.chrome ----
  // 真 Chrome 暴露这几个命名空间。Turnstile 会摸 chrome.runtime 之类
  // 来判断「是不是真的 Chromium 内核」。
  if (typeof window.chrome === 'undefined') {
    window.chrome = {
      app: {
        isInstalled: false,
        InstallState: { DISABLED: 'disabled', INSTALLED: 'installed', NOT_INSTALLED: 'not_installed' },
        RunningState: { CANNOT_RUN: 'cannot_run', READY_TO_RUN: 'ready_to_run', RUNNING: 'running' },
        getDetails: function () { return null; },
        getIsInstalled: function () { return false; }
      },
      runtime: {
        OnInstalledReason: {
          CHROME_UPDATE: 'chrome_update',
          INSTALL: 'install',
          SHARED_MODULE_UPDATE: 'shared_module_update',
          UPDATE: 'update'
        },
        OnRestartRequiredReason: {
          APP_UPDATE: 'app_update',
          OS_UPDATE: 'os_update',
          PERIODIC: 'periodic'
        },
        PlatformArch: {
          ARM: 'arm', ARM64: 'arm64', MIPS: 'mips', MIPS64: 'mips64',
          X86_32: 'x86-32', X86_64: 'x86-64'
        },
        PlatformOs: {
          ANDROID: 'android', CROS: 'cros', LINUX: 'linux',
          MAC: 'mac', OPENBSD: 'openbsd', WIN: 'win'
        },
        RequestUpdateCheckStatus: {
          NO_UPDATE: 'no_update', THROTTLED: 'throttled', UPDATE_AVAILABLE: 'update_available'
        },
        // 页面里通常拿不到这些（只有扩展上下文才有），
        // 但属性存在本身就是「Chrome 内核」的证据。
        connect: undefined,
        sendMessage: undefined,
        id: undefined
      },
      csi: function () {
        return { onloadT: Date.now(), startE: Date.now(), tran: 15, pageT: 0 };
      },
      loadTimes: function () {
        var t = Date.now() / 1000;
        return {
          commitLoadTime: t, connectionInfo: 'h2', finishDocumentLoadTime: t,
          finishLoadTime: t, firstPaintAfterLoadTime: 0, firstPaintTime: t,
          navigationType: 'Other', npnNegotiatedProtocol: 'h2',
          requestTime: t, startLoadTime: t, wasAlternateProtocolAvailable: false,
          wasFetchedViaSpdy: true, wasNpnNegotiated: true
        };
      }
    };
  }

  // ---- navigator.plugins / mimeTypes ----
  // Chrome 内置 PDF 查看器，所以这两个都不是空的。WebView 里是 0。
  // plugins 可能是 undefined（部分内核干脆不暴露）也可能是长度 0。
  // 两种都要补 —— 只判 length === 0 会漏掉前者。
  if (!navigator.plugins || navigator.plugins.length === 0) {
    var mkPlugin = function (name, filename, desc) {
      var p = Object.create(Plugin.prototype);
      Object.defineProperties(p, {
        name: { value: name, enumerable: true },
        filename: { value: filename, enumerable: true },
        description: { value: desc, enumerable: true },
        length: { value: 1, enumerable: true }
      });
      return p;
    };
    var names = [
      ['PDF Viewer', 'internal-pdf-viewer', 'Portable Document Format'],
      ['Chrome PDF Viewer', 'internal-pdf-viewer', 'Portable Document Format'],
      ['Chromium PDF Viewer', 'internal-pdf-viewer', 'Portable Document Format'],
      ['Microsoft Edge PDF Viewer', 'internal-pdf-viewer', 'Portable Document Format'],
      ['WebKit built-in PDF', 'internal-pdf-viewer', 'Portable Document Format']
    ];
    var list = [];
    for (var n = 0; n < names.length; n++) {
      list.push(mkPlugin(names[n][0], names[n][1], names[n][2]));
    }
    var arr = Object.create(PluginArray.prototype);
    for (var q = 0; q < list.length; q++) {
      Object.defineProperty(arr, q, { value: list[q], enumerable: true });
    }
    Object.defineProperty(arr, 'length', { value: list.length });
    arr.item = function (i) { return list[i] || null; };
    arr.namedItem = function (nm) {
      for (var i2 = 0; i2 < list.length; i2++) {
        if (list[i2].name === nm) return list[i2];
      }
      return null;
    };
    arr.refresh = function () {};
    try {
      Object.defineProperty(navigator, 'plugins', {
        get: function () { return arr; }, configurable: true
      });
    } catch (e) {}

    var mt = Object.create(MimeTypeArray.prototype);
    var mime = Object.create(MimeType.prototype);
    Object.defineProperties(mime, {
      type: { value: 'application/pdf', enumerable: true },
      suffixes: { value: 'pdf', enumerable: true },
      description: { value: 'Portable Document Format', enumerable: true },
      enabledPlugin: { value: list[0], enumerable: true }
    });
    Object.defineProperty(mt, 0, { value: mime, enumerable: true });
    Object.defineProperty(mt, 'length', { value: 1 });
    mt.item = function (i) { return i === 0 ? mime : null; };
    mt.namedItem = function (nm) { return nm === 'application/pdf' ? mime : null; };
    try {
      Object.defineProperty(navigator, 'mimeTypes', {
        get: function () { return mt; }, configurable: true
      });
    } catch (e) {}
  }
})();
