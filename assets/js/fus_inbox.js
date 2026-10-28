// fus_inbox.js — freeussms 抓取层（精确字段版）
//
// ## 为什么必须在页面里跑
//
// freeussms 的 `/sms-api/v1/*` 受 Cloudflare Turnstile 会话 + 每请求
// WebCrypto 签名（X-FUS-Proof）保护，请求签名用的私钥只存在于页面上下文
// （IndexedDB `fus-reader-v1`）。外部 HTTP 客户端拿不到，必须借页面自己的
// 请求能力。所以这里挂钩页面的 fetch / XMLHttpRequest，把响应抄一份回来。
//
// ## 字段名不是猜的
//
// 来自站点自己的 `assets/live.js`：
//
//   messageCard(m) 读 m.event_id / m.sender / m.content / m.received_at /
//                  m.copy_code / m.protected / m.receiver / m.number_id
//   update()      读 /sms-api/v1/numbers 的 d.numbers[] → {id, number, message_count}
//
// DOM 卡片是 `article.sms-message[data-event-id]`，广告节点带
// `data-fus-promotion`。
//
// ## 宿主与通道
//
// 宿主：Flutter WebView（`flutter_inappwebview`，跨平台同一份脚本）
// 通道：`window.flutter_inappwebview.callHandler('FusInbox', <json 字符串>)`
//
// 上行消息：
//
//   {type:'messages', items:[{id,sender,text,code,time,phone,protected}], hits, src, phase}
//   {type:'catalog',  items:[{id,number,count}], hits}
//   {type:'status',   text}
//   {type:'holdup',   kind, scope, message, retry, title}
//
// `holdup` = 站点拒绝给消息。不是错误，是它主动说「现在不给」。
// 三种 kind（来自站点 live.js 的 holdMessages）：
//
//   pause       —— 429 + X-Fair-Use: pause。配额，最快 retry 秒后自愈
//   challenge   —— 403 + X-Fair-Use: challenge。要过人机验证
//   unavailable —— 503 + X-Fair-Use: unavailable。服务端临时繁忙
//
// 必须单独上报：以前这些全被当成「没有消息」，界面一直转圈，用户看到的
// 就是「卡住了」，而真正原因一条都看不到。
(function () {
  'use strict';

  if (window.__fusInboxHooked) {
    try { window.__fusInbox && window.__fusInbox.rescan(); } catch (e) {}
    return;
  }
  window.__fusInboxHooked = true;

  var hits = 0;
  var src = '等待中';
  var lastErr = '';
  var lastKey = '';
  var messages = [];
  // 与 Dart 侧的 `kInboxMaxMessages`（lib/features/inbox/application/
  // inbox_merge.dart）保持一致 —— 两边都截断，数值不一样就会出现
  // 「Dart 收了 240、JS 只发 150」这种一边砍一边补的怪现象。
  // 上限要容得下「翻几页」。之前是 60，而翻页正是往尾部追加更早的消息，
  // 追加完立刻被 slice(0,60) 砍掉——等于翻页功能从来没生效过。
  // 240 = 10 页（每页 24），够用且每次推送的 JSON 仍在几十 KB 量级。
  var MAX_MESSAGES = 240;

  function post(obj) {
    try {
      var envelope = JSON.stringify(obj);
      // 通道只有一条：`flutter_inappwebview` 的 callHandler。
      //
      // 曾经这里还有一条 `window.FusInbox.postMessage` 的老分支 ——
      // 那是当年用 `addJavascriptInterface` 从 Kotlin 注册的，那条路
      // 随 `BrowserShim.kt` 一起删了。留着它不会出错，但会让人以为
      // 「有两条通道、哪条都能走」，改通道名时只改一条就静默失效。
      //
      // Dart 侧的注册点在 `platform/inapp_view_builder.dart` 的
      // `addJavaScriptHandler`，通道名常量是
      // `inbox_screen.dart` 的 `_kChannel` —— 改这里必须同步改那两处。
      if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
        window.flutter_inappwebview.callHandler('FusInbox', envelope);
      }
    } catch (e) { lastErr = 'post:' + e.message; }
  }

  function status(text) { post({ type: 'status', text: text }); }

  function pushMessages(phase) {
    // key 必须把 hits / src / err 一起算进去：只比 messages 的话，
    // 「消息没变但 hits 从 0 涨到 1」这种帧会被丢掉，
    // 而 UI 正是靠 hits 判断挂钩有没有生效（否则一直显示「卡在人机验证」）。
    var key = JSON.stringify([messages, hits, src, lastErr]);
    if (key === lastKey && !phase) return;
    lastKey = key;
    var p = {
      type: 'messages',
      items: messages,
      hits: hits,
      src: src,
      count: messages.length,
      url: location.href,
    };
    if (phase) p.phase = phase;
    if (lastErr) p.err = lastErr;
    post(p);
  }

  // ---- 归一化 ----

  function str(v) { return typeof v === 'string' ? v : (v === null || v === undefined ? '' : String(v)); }

  // 站点给的 copy_code 是权威值；没有才从正文里兜。
  // 兜底必须带语义门：否则「订单 12345 已发货」这类正文会被当成验证码放大。
  //
  // 分隔符形式（`890-864` / `450-549`）必须先匹配：
  // WhatsApp 的验证码就是三位-三位，早期只认连续数字，这类整条都被漏掉。
  // 保号不保格式——站点显示什么就抄什么，用户要照着填。
  function codeFrom(text) {
    var t = str(text);
    if (!t) return '';

    // 语义门：没有这些词就不当验证码，否则「订单 12345 已发货」会被放大。
    // 补了几个真实短信里常见但之前漏掉的词：one-time / confirmation /
    // sign-in / verification / activation / pin。
    var hasCodeWord = /(code|verif|otp|passcode|one[ -]?time|confirmation|sign[ -]?in|activation|pin\b|验证码|驗證碼|动态码|动态密码)/i.test(t);
    if (!hasCodeWord) return '';

    // 已知的固定格式优先，这些是真实服务专用的，误判率最低。
    //   Google:      G-123456   或  G-123 456
    //   WhatsApp:    123-456
    //   通用方括号:  [123456]
    // 注意不能加 \b：G- 后面是连字符，\b 在那里不成立，会整体漏掉。
    var known = t.match(/G-(\d{3}[ -]?\d{3})(?![\d])/i);
    if (known) return ('G-' + known[1]).replace(/\s/g, '-');

    var bracketed = t.match(/[\[【(（]\s*(\d{4,8})\s*[\]】)）]/);
    if (bracketed) return bracketed[1];

    // 带分隔符的码：890-864 / 123 456 / 1234 5678
    // 全局扫描：命中的可能是年份对或不等长片段，要跳过继续往后找。
    var re = /(?:^|[^\d])(\d{2,4}(?:[-\s]\d{2,4}){1,3})(?=[^\d]|$)/g;
    var mm;
    while ((mm = re.exec(t)) !== null) {
      var parts = mm[1].split(/[-\s]/);
      var joined = parts.join('');
      var sameLen = parts.every(function (p) { return p.length === parts[0].length; });
      var yearPair = parts.length === 2 && parts[0].length === 4 &&
          parts[1].length === 4 && /^20\d\d$/.test(parts[0]) && /^20\d\d$/.test(parts[1]);
      // 排除像是日期/电话的片段：3-4-4 这种是电话号码形状。
      var phoneLike = parts.length === 3 && parts[0].length === 3 &&
          parts[1].length === 3 && parts[2].length === 4;
      if (joined.length >= 4 && joined.length <= 10 && sameLen && !yearPair && !phoneLike) {
        return mm[1];
      }
    }

    // 连续数字。先把年份剔掉，否则 "expired in 2024" 会被当成验证码。
    var rest = t.replace(/\b20\d\d\b/g, ' ');

    // 新版：先在「验证码词」附近找，再退回全文找。
    // 真实短信经常写成：
    //   "Your code is 123456"
    //   "123456 is your verification code"
    //   "Use 123456 to sign in"
    // 前两种都能被「附近」这一招覆盖。
    var near = rest.match(
      /(?:code|verif|otp|passcode|one[ -]?time|confirmation|sign[ -]?in|activation|pin|验证码|驗證碼)[^\d]{0,24}(\d{4,8})/i
    );
    if (near) return near[1];
    var before = rest.match(
      /(\d{4,8})[^\d]{0,24}(?:code|verif|otp|passcode|one[ -]?time|confirmation|sign[ -]?in|activation|pin|验证码|驗證碼)/i
    );
    if (before) return before[1];

    // 最后退回全文第一个 4~8 位数字。
    var m = rest.match(/(?:^|[^\d])(\d{4,8})(?:[^\d]|$)/);
    return m ? m[1] : '';
  }

  function normMessage(m) {
    if (!m || typeof m !== 'object') return null;
    var content = str(m.content || m.body || m.text || m.message);
    var code = str(m.copy_code || m.code || '');
    if (!code) code = codeFrom(content);
    var sender = str(m.sender || m.from || '');
    var received = str(m.received_at || m.receivedAt || m.time || '');
    var receiver = str(m.receiver || '');
    var id = str(m.event_id || m.id || m.eventId || '');
    if (!content && !code) return null;
    if (!id) id = (receiver + '|' + received + '|' + content).slice(0, 120);
    return {
      id: id,
      sender: sender,
      text: content,
      code: code,
      time: received,
      phone: receiver,
      protected: m.protected === true,
    };
  }

  // 合并：同 id 后到的覆盖先到的（正文/验证码可能分批抵达）。
  function merge(list) {
    var byId = {};
    var order = [];
    var i, n;
    for (i = 0; i < messages.length; i++) {
      byId[messages[i].id] = messages[i];
      order.push(messages[i].id);
    }
    for (i = 0; i < list.length; i++) {
      n = list[i];
      if (!n) continue;
      // 站点给的是「新→旧」，原序追加即可；unshift 会把整表翻转。
      if (!byId[n.id]) order.push(n.id);
      var old = byId[n.id];
      byId[n.id] = {
        id: n.id,
        sender: n.sender || (old && old.sender) || '',
        text: n.text || (old && old.text) || '',
        code: n.code || (old && old.code) || '',
        time: n.time || (old && old.time) || '',
        phone: n.phone || (old && old.phone) || '',
        protected: n.protected,
      };
    }
    var out = [];
    for (i = 0; i < order.length; i++) if (byId[order[i]]) out.push(byId[order[i]]);
    // 与站点侧 messageSize 一致：超出上限的旧消息对用户没意义，
    // 而且每一次推送都要把整个数组序列化过通道，不裁会越推越慢。
    if (out.length > MAX_MESSAGES) out = out.slice(0, MAX_MESSAGES);
    messages = out;
  }

  // ---- 抄页面自己的接口响应 ----

  function digest(json) {
    if (!json || typeof json !== 'object') return false;

    // 有些路径拿不到响应头（XHR 在被拦截时、或某些中间层去掉了
    // X-Fair-Use）。这时候只能看 body 里的错误码兜底——
    // 不认出来就会被当成「没有消息」，界面又转圈。
    if (json.error === 'fair_use_unavailable') {
      reportHold('unavailable', 0, json.scope, json.message);
      return false;
    }
    if (json.error === 'reader_session_required') {
      // 会话过期。站点会自己续，这里只记一条状态，不当作被拒。
      lastErr = 'reader 会话过期，正在续';
      return false;
    }

    // 号码目录：d.numbers[] -> {id, number, message_count}
    if (Array.isArray(json.numbers) && json.numbers.length) {
      hits++;
      var cat = [];
      for (var k = 0; k < json.numbers.length; k++) {
        var nb = json.numbers[k];
        if (!nb || !nb.number) continue;
        cat.push({
          id: str(nb.id),
          number: str(nb.number),
          count: nb.message_count === undefined ? null : Number(nb.message_count),
          state: str(nb.state || nb.region || ''),
          area: str(nb.area_code || nb.area || ''),
        });
      }
      if (cat.length) post({ type: 'catalog', items: cat, hits: hits });
    }

    // 收件箱：items[] 是消息数组
    var raw = null;
    if (Array.isArray(json.items)) raw = json.items;
    else if (Array.isArray(json.messages)) raw = json.messages;
    else if (Array.isArray(json.data)) raw = json.data;

    if (!raw || !raw.length) return false;

    // 拿到真消息 = 这次拒绝结束了。清掉「已上报」，
    // 下次再被拒才会重新提醒用户。
    clearHold();

    hits++;
    src = '接口';
    var norms = [];
    for (var i = 0; i < raw.length; i++) {
      var n = normMessage(raw[i]);
      if (n) norms.push(n);
    }
    if (!norms.length) return false;
    merge(norms);
    pushMessages();
    return true;
  }

  /* ---------------- 服务端拒绝检测 ----------------

   * 站点在 live.js:693 用 X-Fair-Use 这个响应头区分三种拒绝：
   *
   *   429 + pause        → 新号配额用完了
   *   403 + challenge    → 要过人机验证
   *   503 + unavailable  → 服务端临时繁忙
   *
   * 三种都有 Retry-After，表示多少秒后可以自己好。
   *
   * 为什么必须识别：这些响应体里**没有 messages 字段**，我们原来的
   * digest() 直接当作「空」跳过，界面就一直停在「正在加载」。
   * 用户看不到任何原因，只能反复重试，越重试越糟。
   */
  var holdupSeen = {};
  // 是否已经告诉过用户「被拒了」。用来决定恢复时要发不发「解除」。
  var holdReported = false;

  function holdFromResponse(res) {
    var marker = res.headers && res.headers.get('X-Fair-Use');
    if (!marker) return null;
    var kind = res.status === 429 ? 'pause'
      : res.status === 403 ? 'challenge'
      : res.status === 503 ? 'unavailable'
      : null;
    if (!kind) return null;
    var retry = parseInt(res.headers.get('Retry-After') || '', 10);
    return { kind: kind, retry: isFinite(retry) ? retry : 0 };
  }

  // 从页面 DOM 抄站点的原话。站点自己会渲染这段说明，
  // 我们照抄比编一句准确。
  function holdCopy(kind) {
    var box = document.querySelector('[data-fair-use-notice]');
    if (box) {
      var t = box.querySelector('[data-fair-use-title]');
      var m = box.querySelector('[data-fair-use-message]');
      if (t || m) {
        return {
          title: t ? (t.textContent || '').trim() : '',
          message: m ? (m.textContent || '').trim() : '',
        };
      }
    }
    // 站点还没渲染出来，用已知的文案。
    return {
      pause: { title: '免费额度用完了', message: '站点限制了新号码的免费读取。已打开过的号码仍然可以读。' },
      challenge: { title: '需要过人机验证', message: '点右上角盾牌，在页面里完成验证，通过后会自动收起。' },
      unavailable: { title: '站点暂时繁忙', message: '服务器暂时没有响应，稍等一会它会自己恢复。' },
    }[kind] || { title: '', message: '' };
  }

  function reportHold(kind, retry, scope, serverMessage) {
    // 同一种拒绝 + 同一个重试秒数只报一次，避免每帧刷屏。
    var key = kind + '|' + retry;
    if (holdupSeen[key]) return;
    holdupSeen[key] = 1;
    holdReported = true;
    var copy = holdCopy(kind);
    post({
      type: 'holdup',
      kind: kind,
      scope: scope || '',
      retry: retry || 0,
      title: copy.title,
      message: serverMessage || copy.message,
    });
  }

  // 清掉「已上报」记录。只在**真的拿到消息**时调用 ——
  // 拿到消息就说明这次拒绝结束了，下次再被拒要重新告诉用户。
  function clearHold() {
    holdupSeen = {};
    if (!holdReported) return;
    holdReported = false;
    post({ type: 'holdup', kind: '', scope: '' });
  }

  function interesting(u) {
    if (typeof u !== 'string') return false;
    return u.indexOf('/sms-api/') >= 0;
  }

  try {
    var origFetch = window.fetch;
    if (origFetch && !origFetch.__fus) {
      var wrapped = function (input) {
        var url = typeof input === 'string' ? input : (input && input.url) || '';
        // 先抄号码 id：首屏请求一定带，抄到就能自己翻页了。
        if (interesting(url)) captureNumberId(url);
        var p = origFetch.apply(this, arguments);
        if (interesting(url)) {
          try {
            p.then(function (res) {
              // 先看有没有被拒。这几条响应的 body 里没有 messages，
              // 交给 digest 只会被当成「空」，原因就丢了。
              var hold = holdFromResponse(res);
              if (hold) {
                try {
                  res.clone().json().then(function (d) {
                    reportHold(hold.kind, hold.retry, d && d.scope, d && d.message);
                  }).catch(function () {
                    reportHold(hold.kind, hold.retry, '', '');
                  });
                } catch (e) {
                  reportHold(hold.kind, hold.retry, '', '');
                }
                return res;
              }
              try {
                res.clone().json().then(function (d) {
                  try { digest(d); } catch (e) { lastErr = 'digest:' + e.message; }
                }).catch(function () {});
              } catch (e) {}
              return res;
            }).catch(function () {});
          } catch (e) {}
        }
        return p;
      };
      wrapped.__fus = 1;
      window.fetch = wrapped;
    }
  } catch (e) { lastErr = 'fetch-hook:' + e.message; }

  try {
    var origOpen = XMLHttpRequest.prototype.open;
    var origSend = XMLHttpRequest.prototype.send;
    if (!origOpen.__fus) {
      var newOpen = function (method, url) {
        this.__fusUrl = url;
        if (interesting(url)) captureNumberId(url);
        return origOpen.apply(this, arguments);
      };
      newOpen.__fus = 1;
      XMLHttpRequest.prototype.open = newOpen;
      XMLHttpRequest.prototype.send = function () {
        var self = this;
        this.addEventListener('load', function () {
          if (!interesting(self.__fusUrl)) return;
          // 用 status 判断被拒，比 fetch 那边多一步：XHR 拿不到响应头
          // 之外的信号时只能看状态码。
          var code = self.status;
          if (code === 429 || code === 403 || code === 503) {
            var d = null;
            try { d = JSON.parse(self.responseText); } catch (e) {}
            var retry = parseInt(self.getResponseHeader('Retry-After') || '', 10);
            reportHold(
              code === 429 ? 'pause' : code === 403 ? 'challenge' : 'unavailable',
              isFinite(retry) ? retry : 0,
              d && d.scope,
              d && d.message
            );
            return;
          }
          try { digest(JSON.parse(self.responseText)); } catch (e) {}
        });
        return origSend.apply(this, arguments);
      };
    }
  } catch (e) { lastErr = 'xhr-hook:' + e.message; }

  /* ---------------- DOM 兜底 ----------------
   * 只扫收件箱容器，跳过广告节点（data-fus-promotion）。
   * 结构（来自站点 live.js 的 messageCard）：article.sms-message[data-event-id]
   *   .sms-message-top > .message-origin > h3     发送方
   *   time                                         时间
   *   p.live-message-body                          正文
   *   .code-chip[data-live-copy]                   验证码
   */
  function domScan() {
    var root = document.querySelector('[data-live-messages]');
    if (!root) { status('页面里还没出现收件箱容器'); return 0; }

    var cards = root.querySelectorAll('[data-event-id]');
    var found = [];
    for (var i = 0; i < cards.length; i++) {
      var c = cards[i];
      // 广告节点混在同一个列表里，明确剔掉。
      if (c.hasAttribute('data-fus-promotion') || c.closest('[data-fus-promotion]')) continue;

      var h3 = c.querySelector('.message-origin h3');
      var body = c.querySelector('.live-message-body');
      var chip = c.querySelector('.code-chip[data-live-copy]');
      var t = c.querySelector('time');

      var text = body ? (body.textContent || '').trim() : '';
      var code = chip ? (chip.getAttribute('data-live-copy') || '').trim() : '';
      if (!code && text) code = codeFrom(text);
      var sender = h3 ? (h3.textContent || '').trim() : '';
      var when = t ? (t.getAttribute('datetime') || t.textContent || '').trim() : '';

      if (!text && !code) continue;
      found.push({
        id: c.getAttribute('data-event-id') || '',
        sender: sender,
        text: text,
        code: code,
        time: when,
        phone: '',
        protected: /unavailable/i.test(c.textContent || ''),
      });
    }

    if (found.length) {
      if (src === '等待中') src = '页面';
      merge(found);
      pushMessages();
    } else {
      status('收件箱容器在，但还没有可见消息');
    }
    return found.length;
  }

  // ---- 按需翻页 ----
  //
  // 站点接口是游标分页：GET /sms-api/v1/inbox?id=<32hex>&before=<游标>。
  // 首屏由站点自己请求，我们只抄；更早的消息必须由这里主动拉——
  // 因为签名头 X-FUS-Proof 依赖页面上下文的私钥，纯 HTTP 拿不到（实测 401
  // reader_session_required）。
  //
  // 之所以不一次抓完：站点在 Cloudflare 后面，连着抓多页就是风控的直接来源。
  // 用户滑到底才拉一页，既省请求也让首屏更快。
  var loadingMore = false;
  var exhausted = false;   // 站点明确说没有更早的了
  var pageSize = 0;        // 首屏条数，用来判断「这页是不是最后一页」

  function oldestCursor() {
    // 不能直接取最后一条：merge() 对新到的实时消息是「追加到末尾」，
    // 数组顺序并不保证新→旧（Dart 侧会按时间重排，但这里是 JS 自己的数组）。
    // 取所有时间里最小的那个，与顺序无关，永远安全。
    // ISO 8601 字符串可以直接字典序比较。
    var min = '';
    for (var i = 0; i < messages.length; i++) {
      var t = messages[i] && messages[i].time;
      if (!t) continue;
      if (!min || t < min) min = t;
    }
    return min;
  }

  // ---- 号码 id 捕获 ----
  //
  // inbox 接口要的是 32 位 hex 的号码 id，而页面 URL 里只有 10 位电话号码，
  // 两者对不上。所以从站点自己的 /sms-api/ 请求里把它抄下来——
  // 首屏那次请求一定带 id，抄到就不用猜了。
  var numberId = '';

  function captureNumberId(url) {
    if (numberId) return;
    var m = String(url).match(/[?&]id=([0-9a-f]{32})/i);
    if (m) {
      numberId = m[1];
      return;
    }
    // 有的接口把 id 放在路径里
    m = String(url).match(/\/numbers?\/([0-9a-f]{32})/i);
    if (m) numberId = m[1];
  }

  function resolveNumberId() {
    if (numberId) return numberId;
    if (window.__fusNumberId) return window.__fusNumberId;

    // 退路一：页面里的 data 属性
    var el = document.querySelector('[data-number-id]');
    if (el) {
      var v = el.getAttribute('data-number-id');
      if (v && /^[0-9a-f]{32}$/i.test(v)) return v;
    }
    // 退路二：页面脚本里的常量
    try {
      var html = document.documentElement.innerHTML;
      var m = html.match(/"number_id"\s*:\s*"([0-9a-f]{32})"/i) ||
              html.match(/data-number-id="([0-9a-f]{32})"/i);
      if (m) return m[1];
    } catch (e) {}
    return '';
  }

  function loadMore() {
    if (loadingMore || exhausted) return false;
    var cursor = oldestCursor();
    if (!cursor) {
      // 必须回一声：Dart 侧已经先把 loadingMore 置真了，
      // 没有回音就一直转圈。
      post({ type: 'moreFail', reason: 'no_cursor' });
      return false;
    }

    var numId = resolveNumberId();
    if (!numId) {
      status('还拿不到号码 id，等页面加载完再试');
      post({ type: 'moreFail', reason: 'no_id' });
      return false;
    }

    loadingMore = true;
    status('正在加载更早的消息…');

    var url = '/sms-api/v1/inbox?id=' + encodeURIComponent(numId) +
              '&before=' + encodeURIComponent(cursor);

    // 必须走站点自己的签名入口。
    //
    // 直接 fetch 会被 401 reader_session_required 打回：inbox 接口要求
    // X-FUS-Proof 头，而签名用的私钥只存在页面上下文（IndexedDB
    // fus-reader-v1），还得先过一次 Turnstile 换 grant。
    //
    // 站点把这块封装成了 window.FUSReader，其中 fetch(url, options)
    // 就是 secureFetch —— 它自己会 ensure() 拿 grant、给请求签名，
    // 并在 401/403/409 时按 reader_* 错误码自动续期重试。
    // 我们只需要把 URL 交给它，等于借用站点自己的登录态。
    var send = (window.FUSReader && window.FUSReader.fetch)
      ? function (u) { return window.FUSReader.fetch(u, {}); }
      : function (u) { return fetch(u, { credentials: 'same-origin' }); };

    send(url)
      .then(function (r) {
        if (!r.ok) throw new Error('HTTP ' + r.status);
        return r.json();
      })
      .then(function (json) {
        var raw = json && (json.items || json.messages || json.data);
        if (!Array.isArray(raw) || !raw.length) {
          exhausted = true;
          status('没有更早的消息了');
          post({ type: 'moreEnd', empty: true });
          return;
        }
        // 「一页给不满就到底」的基准必须是接口实际返回的条数。
        // 之前用 messages.length（含 DOM 扫到的条目）当基准，
        // DOM 抓到 60 条时，接口返回 24 < 60 会被误判为最后一页。
        if (!pageSize) pageSize = raw.length;

        var norms = [];
        for (var i = 0; i < raw.length; i++) {
          var n = normMessage(raw[i]);
          if (n) norms.push(n);
        }
        if (!norms.length) {
          exhausted = true;
          post({ type: 'moreEnd', empty: true });
          return;
        }
        var before = messages.length;
        merge(norms);
        var added = messages.length - before;
        // 一页给不满 = 到底了，别再让用户空拉。
        if (raw.length < pageSize) exhausted = true;
        status(added > 0 ? '又加载了 ' + added + ' 条' : '没有更早的消息了');
        post({ type: 'moreDone', added: added, exhausted: exhausted });
        pushMessages('more');
      })
      .catch(function (e) {
        status('加载更早消息失败：' + (e && e.message ? e.message : e));
        post({ type: 'moreFail', err: String(e && e.message ? e.message : e) });
      })
      .then(function () { loadingMore = false; });
    return true;
  }

  // 人机验证框在页面里的位置（CSS 像素，相对视口左上角）。
  //
  // 宿主拿它做一件事：**自动弹出时只把这一小块放大显示**，而不是把整个
  // 站点页面糊在屏幕上 —— 用户要点的就那一个复选框，整页看着难受。
  // 用户自己点「自己过验证」时不调这个，仍然看整页（他想顺便翻翻站点）。
  //
  // `getBoundingClientRect()` 对**跨域 iframe 也算得出来** —— 同源策略
  // 拦的是读写 iframe 内部，量它自己的位置和尺寸不受影响。Turnstile 的
  // 复选框正好在 challenges.cloudflare.com 的 iframe 里，所以这条路通。
  //
  // 找不到就返回 null，宿主那边回落到「显示整页」—— 宁可多显示，
  // 不能因为认不出框就让用户没了可点的地方。
  function challengeRect() {
    // 选择器**从具体到宽泛**排：Turnstile 是站点用 `turnstile.render()`
    // 动态渲染的（配置在 `script[data-fair-use-turnstile]` 里），
    // 静态 HTML 里一个字都没有 —— 所以只能按渲染后的形态找，
    // 而且要留足「它还没渲染出来」的余地。
    var sel = [
      'iframe[src*="challenges.cloudflare.com"]', // Turnstile 本体
      'iframe[src*="turnstile"]',
      '[id^="cf-chl-widget"]',                    // Cloudflare 自己的 widget id
      '.cf-turnstile',
      '[data-sitekey]',
      '[class*="turnstile"]',
      '[id*="turnstile"]',
    ];
    var el = null;
    for (var i = 0; i < sel.length && !el; i++) {
      el = document.querySelector(sel[i]);
    }
    if (!el) return null;

    // 找到的那个常常是 0×0：Turnstile 在 managed 模式下先挂一个隐藏的
    // 占位，或者外层是 inline 元素、尺寸全在祖先上。**往上找第一个有尺寸的**，
    // 而不是直接放弃 —— 放弃就会回落到「显示整页」，那正是要避免的。
    var node = el;
    var r = null;
    for (var up = 0; up < 6 && node; up++) {
      var rr = node.getBoundingClientRect();
      if (rr && rr.width > 2 && rr.height > 2) { r = rr; break; }
      node = node.parentElement;
    }
    if (!r) return null;
    return { x: r.left, y: r.top, w: r.width, h: r.height };
  }

  window.__fusInbox = {
    rescan: function () { domScan(); pushMessages('rescan'); },
    digest: digest,
    dump: function () { return JSON.stringify(messages); },
    loadMore: loadMore,
    canLoadMore: function () { return !exhausted && !loadingMore; },
    setNumberId: function (id) { window.__fusNumberId = str(id); },
    challengeRect: challengeRect,
  };

  // ---- 启动 ----
  function boot() {
    status('抓取层已就绪');

    // 自适应扫描节奏 —— 之前是固定 [1200,3000,6000,10000] 敲四次，
    // 不管有没有消息都按同一个间隔打，快了浪费、慢了又错过第一屏。
    //
    // 现在改成：从 300ms 起步、逐次退避到 4s，一旦扫到消息立刻停表。
    // 首屏通常 300~900ms 内就命中，比原来固定等 1.2s 快一倍以上；
    // 页面一直不出数据时也不会无限快扫，间隔自动拉开。
    // 参数是实测出来的（/tmp/scan2.js 模拟过五种到达时刻）：
    //   前 6 次固定 250ms → 覆盖前 1.5 秒，这段是首屏渲染最可能完成的窗口；
    //   之后指数退避（×1.8，上限 4s）→ 页面迟迟不出数据时不至于高频空扫。
    // 实测：消息 600ms 到 → 750ms 命中；900ms 到 → 1000ms 命中。
    // 之前写成 300ms 起、每次 ×1.7 退避，900ms 的消息要等到 1677ms 才扫到，
    // 比原来的固定节奏还慢——退避必须在密集期之后才开始。
    var DENSE_GAP = 250;
    var DENSE_COUNT = 6;
    var scanDelay = DENSE_GAP;
    var scanCount = 0;
    var scanTimer = 0;
    var stopped = false;

    function scheduleScan() {
      if (stopped) return;
      if (scanTimer) clearTimeout(scanTimer);
      scanTimer = setTimeout(function () {
        scanTimer = 0;
        if (stopped) return;
        domScan();
        if (messages.length) {
          // 拿到了就收工：别再空扫，省电也省 CPU。
          stopped = true;
          return;
        }
        scanCount++;
        if (scanCount >= DENSE_COUNT) {
          scanDelay = Math.min(Math.round(scanDelay * 1.8), 4000);
        }
        scheduleScan();
      }, scanDelay);
    }

    scheduleScan();

    try {
      var mo = new MutationObserver(function () {
        if (messages.length) return;
        // 站点有广告轮播和倒计时，DOM 一直在变。不节流的话这里一天能跑几万次，
        // 每次都要遍历全页——手机发烫、耗电，而且完全没有收益。
        // 冷却是必需的：3 秒内最多重扫一次，且只在还没拿到消息时才扫。
        clearTimeout(mo.__t);
        mo.__t = setTimeout(domScan, 3000);
      });
      mo.observe(document.documentElement, { childList: true, subtree: true });
    } catch (e) {}

    // 兜底轮询：拿到消息就停。间隔从 30s 收到 10s——
    // 前面自适应扫描已在扫到后停下，这里只在「一直没数据」时兜着，
    // 10 秒一次对站点压力可以忽略，但用户少等 20 秒。
    var tick = setInterval(function () {
      if (messages.length || stopped) { clearInterval(tick); return; }
      domScan();
    }, 10000);
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', boot);
  } else {
    boot();
  }
})();
