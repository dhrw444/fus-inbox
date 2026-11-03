// 浏览器垫片的**平台兼容**测试。
//
// 跑法：node tool/shim_test.js      （全过 exit(0)，任一断言挂 exit(1)）
//
// 为什么要有它：垫片原来有两扇「只在缺属性时才装」的门 ——
// `if (!('userAgentData' in navigator))` 和
// `if (typeof window.chrome === 'undefined')`。
// Android WebView 两样都缺，所以手机上一直是对的；Windows 的 WebView2
// **两样都有**（只是内容不全），于是两段整段跳过，页面读到的是引擎真实的
// `Microsoft Edge` 品牌表 —— 而同一份身份在 UA 串和 `Sec-CH-UA` 请求头里
// 都写着 Chrome。同一次请求三方对不上，Turnstile 最先看的就是这个。
//
// 所以判据是「**原生对象已经存在、且报着 Edge 时，垫片必须盖住它**」，
// 不是「垫片能装上」。装得上只证明了安卓那一条路。
'use strict';

const fs = require('fs');
const path = require('path');
const vm = require('vm');

const SRC = fs.readFileSync(
  path.join(__dirname, '..', 'assets', 'js', 'browser_shim.js'),
  'utf8'
);

let pass = 0;
let fail = 0;
function ok(cond, label) {
  if (cond) {
    pass++;
  } else {
    fail++;
    console.log('FAIL  ' + label);
  }
}
function eq(actual, expected, label) {
  ok(
    actual === expected,
    label + '  got=' + JSON.stringify(actual) + ' want=' + JSON.stringify(expected)
  );
}

const DESKTOP_UA =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' +
  '(KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36';
const ANDROID_UA =
  'Mozilla/5.0 (Linux; Android 14; SM-S918B Build/UP1A.231005.007) ' +
  'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Mobile Safari/537.36';

const DESKTOP_SEED = {
  full: '143.0.0.0',
  major: '143',
  plat: 'Windows',
  mobile: false,
  // 真机上 Windows 的平台版本就是 `10.0.0`（来自 `Windows NT 10.0`）——
  // Dart 那边 `platformVersionHint` 用的也是这个值。这里跟它对齐，
  // 顺便盯住「别再补成 10.0.0.0.0」那条。
  pv: '10.0.0',
  mdl: '',
  brands: [
    { brand: 'Chromium', version: '143' },
    { brand: 'Google Chrome', version: '143' },
    { brand: 'Not?A_Brand', version: '99' }
  ]
};

const ANDROID_SEED = {
  full: '143.0.0.0',
  major: '143',
  plat: 'Android',
  mobile: true,
  pv: '14.0.0',
  mdl: 'SM-S918B',
  brands: [
    { brand: 'Chromium', version: '143' },
    { brand: 'Google Chrome', version: '143' },
    { brand: 'Not?A_Brand', version: '99' }
  ]
};

// 模拟 Chromium 的 `NavigatorUAData`：值挂在**原型**上，实例上没有自己属性。
class NavigatorUAData {
  get brands() {
    return [
      { brand: 'Microsoft Edge', version: '143' },
      { brand: 'Chromium', version: '143' },
      { brand: 'Not?A_Brand', version: '24' }
    ];
  }
  get mobile() {
    return false;
  }
  get platform() {
    return 'Windows';
  }
  getHighEntropyValues() {
    return Promise.resolve({
      architecture: 'x86',
      bitness: '64',
      brands: this.brands,
      fullVersionList: this.brands,
      mobile: this.mobile,
      model: '',
      platform: this.platform,
      platformVersion: '19.0.0',
      uaFullVersion: '143.0.0.0',
      wow64: false
    });
  }
  toJSON() {
    return { brands: this.brands, mobile: this.mobile, platform: this.platform };
  }
}

class Document {}
class Plugin {}
class PluginArray {}
class MimeType {}
class MimeTypeArray {}

// 造一个沙箱，把垫片跑一遍，返回里面那几个对象供外面断言。
// opts.withNativeUAData = true → 模拟 WebView2：原生 UA-CH 已经在，且报 Edge
// opts.withChrome        = true → 模拟 WebView2：chrome 存在，但只有宿主桥
function runShim(opts) {
  const sandbox = {};
  sandbox.window = sandbox;

  const nav = {};
  Object.defineProperty(nav, 'userAgent', {
    get: () => opts.ua,
    configurable: true
  });
  nav.plugins = [];
  nav.mimeTypes = [];
  sandbox.navigator = nav;

  const doc = new Document();
  sandbox.document = doc;
  sandbox.Document = Document;
  sandbox.Plugin = Plugin;
  sandbox.PluginArray = PluginArray;
  sandbox.MimeType = MimeType;
  sandbox.MimeTypeArray = MimeTypeArray;

  let nativeUAData = null;
  if (opts.withNativeUAData) {
    nativeUAData = new NavigatorUAData();
    Object.defineProperty(nav, 'userAgentData', {
      get: () => nativeUAData,
      configurable: true
    });
  }

  let chrome = null;
  if (opts.withChrome) {
    // WebView2 的形状：有插件自己的宿主桥 `chrome.webview`，
    // 也有 `runtime`，但缺 `app` / `csi` / `loadTimes`，runtime 里也没常量。
    chrome = { webview: { postMessage: () => {} }, runtime: {} };
    sandbox.chrome = chrome;
  }

  sandbox.__fusSeed = Object.assign({}, opts.seed);
  sandbox.console = console;

  // 垫片**跑之前**先拍一张原型快照 —— 前置对照要用它，
  // 跑完再读就已经被盖住了（那正是被测的行为）。
  const nativeBefore = nativeUAData ? brandNames(nativeUAData.brands).slice() : null;
  const nativePlatformBefore = nativeUAData ? nativeUAData.platform : null;

  vm.createContext(sandbox);
  vm.runInContext(SRC, sandbox, { filename: 'browser_shim.js' });

  return {
    window: sandbox,
    navigator: nav,
    document: doc,
    chrome,
    nativeUAData,
    nativeBefore,
    nativePlatformBefore
  };
}

const brandNames = (list) => (list || []).map((b) => b && b.brand);

async function main() {
  // ==========================================================
  // 场景一：Windows（WebView2）—— 原生 UA-CH 已存在，且报着 Edge
  // ==========================================================
  const w = runShim({
    ua: DESKTOP_UA,
    seed: DESKTOP_SEED,
    withNativeUAData: true,
    withChrome: true
  });

  // 前置对照：确认这个场景**确实**是「原生报着 Edge」。
  // 没有这一步，下面「盖住了」的断言就没意义 —— 也许本来就没有 Edge。
  ok(
    w.nativeBefore.indexOf('Microsoft Edge') >= 0,
    '前置：跑垫片之前，原生对象确实报着 Microsoft Edge'
  );
  eq(
    w.nativePlatformBefore,
    'Windows',
    '前置：跑垫片之前，原生 platform 是 Windows'
  );

  const wUA = w.navigator.userAgentData;
  ok(wUA, 'Windows：userAgentData 存在');
  ok(
    brandNames(wUA.brands).indexOf('Microsoft Edge') < 0,
    'Windows：品牌表里已经没有 Microsoft Edge'
  );
  ok(
    brandNames(wUA.brands).indexOf('Google Chrome') >= 0,
    'Windows：品牌表是种子那套（Google Chrome 在）'
  );
  eq(wUA.platform, 'Windows', 'Windows：platform 跟种子（Windows）');
  eq(wUA.mobile, false, 'Windows：mobile=false');

  // 原型链和 instanceof 都不能动 —— 动过就是能被摸出来的破绽。
  ok(
    wUA instanceof NavigatorUAData,
    'Windows：instanceof NavigatorUAData 仍然成立'
  );
  eq(
    Object.getOwnPropertyNames(wUA).length,
    0,
    'Windows：实例上没有多出自己属性'
  );
  eq(
    Object.getPrototypeOf(wUA),
    NavigatorUAData.prototype,
    'Windows：原型链没被换掉'
  );

  // 高位熵值：以前写死 architecture:'arm' / bitness:'64'，
  // 而 UA 是 `Win64; x64` —— 又是一处自己打自己。
  const wHe = await wUA.getHighEntropyValues([
    'architecture',
    'bitness',
    'model',
    'platformVersion',
    'fullVersionList'
  ]);
  eq(wHe.architecture, 'x86', 'Windows 高位熵：architecture=x86');
  eq(wHe.bitness, '64', 'Windows 高位熵：bitness=64');
  eq(wHe.model, '', 'Windows 高位熵：model 是空串（桌面没有机型）');
  eq(wHe.platformVersion, '10.0.0', 'Windows 高位熵：platformVersion 跟种子');
  ok(
    wHe.platformVersion.indexOf('10.0.0.0.0') < 0,
    'Windows 高位熵：平台版本没被补成五段'
  );
  eq(wHe.platform, 'Windows', 'Windows 高位熵：platform=Windows');
  ok(
    brandNames(wHe.fullVersionList).indexOf('Microsoft Edge') < 0,
    'Windows 高位熵：fullVersionList 里没有 Microsoft Edge'
  );

  // window.chrome：有桥、缺内容 —— 必须「缺什么补什么」。
  // 桥本身一个字节都不能动（`callHandler` 底下就是它，动了桥就断）。
  ok(
    typeof w.chrome.webview.postMessage === 'function',
    'Windows：chrome.webview 宿主桥还在'
  );
  ok(w.chrome.app, 'Windows：缺的 chrome.app 被补上');
  eq(w.chrome.app.isInstalled, false, 'Windows：补上的 chrome.app 内容对');
  ok(typeof w.chrome.csi === 'function', 'Windows：缺的 chrome.csi 被补上');
  ok(
    typeof w.chrome.loadTimes === 'function',
    'Windows：缺的 chrome.loadTimes 被补上'
  );
  ok(
    w.chrome.runtime.OnInstalledReason,
    'Windows：已有但空的 runtime 被补齐常量'
  );

  eq(w.document.hidden, false, 'Windows：document.hidden=false');
  eq(w.document.visibilityState, 'visible', 'Windows：visibilityState=visible');

  // ==========================================================
  // 场景二：Android（WebView）—— 原生两样都缺，走「装上」那条路
  // ==========================================================
  const a = runShim({
    ua: ANDROID_UA,
    seed: ANDROID_SEED,
    withNativeUAData: false,
    withChrome: false
  });

  const aUA = a.navigator.userAgentData;
  ok(aUA, 'Android：userAgentData 被装上了');
  eq(aUA.platform, 'Android', 'Android：platform=Android');
  eq(aUA.mobile, true, 'Android：mobile=true');
  ok(
    brandNames(aUA.brands).indexOf('Google Chrome') >= 0,
    'Android：品牌表是种子那套'
  );

  const aHe = await aUA.getHighEntropyValues([
    'architecture',
    'bitness',
    'model'
  ]);
  eq(aHe.architecture, 'arm', 'Android 高位熵：architecture=arm（没被桌面规则带跑）');
  eq(aHe.bitness, '64', 'Android 高位熵：bitness=64');
  eq(aHe.model, 'SM-S918B', 'Android 高位熵：model 从 UA 解出来');

  ok(a.window.chrome, 'Android：window.chrome 被装上了');
  ok(a.window.chrome.app, 'Android：chrome.app 在');
  ok(typeof a.window.chrome.csi === 'function', 'Android：chrome.csi 是函数');
  ok(
    typeof a.window.chrome.loadTimes === 'function',
    'Android：chrome.loadTimes 是函数'
  );
  ok(
    a.window.chrome.runtime.OnInstalledReason,
    'Android：chrome.runtime 带枚举常量'
  );

  eq(a.document.hidden, false, 'Android：document.hidden=false');
  eq(a.document.visibilityState, 'visible', 'Android：visibilityState=visible');

  console.log(pass + ' passed, ' + fail + ' failed');
  if (fail > 0) {
    process.exit(1);
  }
  process.exit(0);
}

main().catch((e) => {
  console.log('FAIL  测试自身抛异常：' + (e && e.stack ? e.stack : e));
  process.exit(1);
});
