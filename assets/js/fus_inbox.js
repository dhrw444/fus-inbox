/* fus_inbox.js — freeussms 抓取层（精确字段版）
 *
 * 为什么必须在页面里跑：
 *   freeussms 的 `/sms-api/v1/*` 受 Cloudflare Turnstile 会话 + 每请求
 *   WebCrypto 签名（X-FUS-Proof）保护，请求签名用的私钥只存在于页面上下文
 *   （IndexedDB `fus-reader-v1`）。外部 HTTP 客户端拿不到，必须借页面自己的
 *   请求能力。所以这里挂钩页面的 fetch / XMLHttpRequest，把响应抄一份回来。
 *
 * 字段名不是猜的——来自站点自己的 `assets/live.js`：
 *   messageCard(m) 读 m.event_id / m.sender / m.content / m.received_at /
 *                  m.copy_code / m.protected / m.receiver / m.number_id
 *   update()       读 /sms-api/v1/numbers 的 d.numbers[] → {id, number, message_count}
 *   DOM 卡片是 `article.sms-message[data-event-id]`，广告节点带 `data-fus-promotion`
 *
 * 宿主：Flutter WebView（webview_flutter）
 * 通道：FusInbox.postMessage(JSON 字符串)
 *
 * 上行消息：
 *   {type:'messages', items:[{id,sender,text,code,time,phone,protected}], hits, src, phase}
 *   {type:'catalog',  items:[{id,number,count}], hits}
 *   {type:'status',   text}
 */
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

  function post(obj) {
    try {
      if (window.FusInbox && window.FusInbox.postMessage) {
        window.FusInbox.postMessage(JSON.stringify(obj));
      }
    } catch (e) { lastErr = 'post:' + e.message; }
  }

  function status(text) { post({ type: 'status', text: text }); }

  function pushMessages(phase) {
    var key = JSON.stringify(messages);
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

  /* ---------------- 归一化 ---------------- */

  function str(v) { return typeof v === 'string' ? v : (v === null || v === undefined ? '' : String(v)); }

  // 站点给的 copy_code 是权威值；没有才从正文里兜。
  function codeFrom(text) {
    var m = str(text).match(/(?:^|[^\d])(\d{4,8})(?:[^\d]|$)/);
    return m ? m[1] : '';
  }

  var lastKey2 = '';
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
      if (!byId[n.id]) order.unshift(n.id);
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
    messages = out;
  }

  /* ---------------- 抄页面自己的接口响应 ---------------- */

  function digest(json) {
    if (!json || typeof json !== 'object') return false;

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

  function interesting(u) {
    if (typeof u !== 'string') return false;
    return u.indexOf('/sms-api/') >= 0;
  }

  try {
    var origFetch = window.fetch;
    if (origFetch && !origFetch.__fus) {
      var wrapped = function (input) {
        var url = typeof input === 'string' ? input : (input && input.url) || '';
        var p = origFetch.apply(this, arguments);
        if (interesting(url)) {
          try {
            p.then(function (res) {
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
        return origOpen.apply(this, arguments);
      };
      newOpen.__fus = 1;
      XMLHttpRequest.prototype.open = newOpen;
      XMLHttpRequest.prototype.send = function () {
        var self = this;
        this.addEventListener('load', function () {
          if (!interesting(self.__fusUrl)) return;
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

  window.__fusInbox = {
    rescan: function () { domScan(); pushMessages('rescan'); },
    digest: digest,
    dump: function () { return JSON.stringify(messages); },
  };

  /* ---------------- 启动 ---------------- */
  function boot() {
    status('抓取层已就绪');
    // 站点自己的渲染节奏：先接口，后 DOM。多打几次保底。
    var delays = [1200, 3000, 6000, 10000, 15000, 22000];
    for (var i = 0; i < delays.length; i++) setTimeout(domScan, delays[i]);
    try {
      var mo = new MutationObserver(function () {
        clearTimeout(mo.__t);
        mo.__t = setTimeout(domScan, 800);
      });
      mo.observe(document.documentElement, { childList: true, subtree: true });
    } catch (e) {}
    setInterval(function () { if (!messages.length) domScan(); }, 12000);
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', boot);
  } else {
    boot();
  }
})();
