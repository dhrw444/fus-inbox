/* fus_inbox.js — freeussms 收件箱抓取
 *
 * freeussms 的收件箱受 Cloudflare Turnstile + WebCrypto 每请求签名保护，
 * 外部 HTTP 客户端拿不到数据。所以做法是：在承载页面的 WebView 里挂钩
 * 页面自身的 fetch / XMLHttpRequest，把 /sms-api/ 的响应 JSON 截下来，
 * 挖出验证码，通过 window.FusInbox 通道回传给 Flutter，由原生界面渲染。
 * 挂钩失败时退回 DOM 扫描。
 *
 * 宿主：android/app（Flutter webview_flutter）
 * 通道：FusInbox.postMessage(JSON 字符串)
 *   上行 {type:'messages', items:[...], src:'接口|页面', hits:N}
 *   上行 {type:'status',   text:'...'}
 */
(function () {
  'use strict';

  if (window.__fusInboxHooked) { try { window.__fusInbox && window.__fusInbox.rescan(); } catch (e) {} return; }
  window.__fusInboxHooked = true;

  var seen = {};
  try { seen = JSON.parse(localStorage.getItem('fus-inbox-seen-v2') || '{}') || {}; } catch (e) { seen = {}; }

  var msgs = [];
  var src = '等待中';
  var hits = 0;
  var lastErr = '';

  function post(obj) {
    try {
      if (window.FusInbox && window.FusInbox.postMessage) window.FusInbox.postMessage(JSON.stringify(obj));
    } catch (e) { lastErr = 'post: ' + e.message; }
  }
  function push(extra) {
    var p = { type: 'messages', items: msgs, src: src, hits: hits, count: msgs.length, url: location.href };
    if (lastErr) p.err = lastErr;
    if (extra) for (var k in extra) p[k] = extra[k];
    post(p);
  }

  /* ---------- 工具 ---------- */
  function isCode(s) { return typeof s === 'string' && /^\s*\d{4,8}\s*$/.test(s); }
  function codeIn(s) {
    if (typeof s !== 'string') return null;
    var m = s.match(/(?:^|[^\d])(\d{4,8})(?:[^\d]|$)/);
    return m ? m[1] : null;
  }
  function looksTime(s) {
    if (typeof s !== 'string') return false;
    if (/^\d{4}-\d{2}-\d{2}[T ]/.test(s)) return true;
    return /\d+\s*(秒|分钟|小时|天|min|sec|hour|day|ago)/i.test(s);
  }
  function looksId(s) { return typeof s === 'string' && /^[0-9a-f]{16,64}$/i.test(s); }
  function relTime(t) {
    if (!t) return '';
    var d = Date.parse(t);
    if (!isNaN(d)) {
      var diff = Math.floor((Date.now() - d) / 1000);
      if (diff < 60) return diff + ' 秒前';
      if (diff < 3600) return Math.floor(diff / 60) + ' 分钟前';
      if (diff < 86400) return Math.floor(diff / 3600) + ' 小时前';
      return Math.floor(diff / 86400) + ' 天前';
    }
    return t;
  }

  /* ---------- 从任意 JSON 挖消息 ---------- */
  function pushMsg(o) {
    var keys = Object.keys(o), strings = [];
    var code = null, text = '', time = '', id = '', phone = '';
    keys.forEach(function (k) {
      var v = o[k];
      if (typeof v === 'string') strings.push({ k: k, v: v });
      else if (typeof v === 'number' && String(v).length >= 4 && String(v).length <= 8 && !code) code = String(v);
    });
    strings.forEach(function (p) {
      if (!code && /^(code|otp|pin|verification_code|sms_code)$/i.test(p.k) && codeIn(p.v)) code = codeIn(p.v);
    });
    strings.forEach(function (p) { if (!code && isCode(p.v)) code = p.v.trim(); });
    var bodyKeys = /^(body|text|message|content|msg|sms|message_body)$/i;
    strings.forEach(function (p) { if (bodyKeys.test(p.k) && p.v.length > text.length) text = p.v; });
    if (!text) {
      strings.forEach(function (p) {
        if (p.v.length > text.length && !isCode(p.v) && !looksId(p.v) && !looksTime(p.v) && !/^https?:/.test(p.v)) text = p.v;
      });
    }
    if (!code) strings.forEach(function (p) { if (!code && codeIn(p.v) && !looksId(p.v)) code = codeIn(p.v); });
    strings.forEach(function (p) {
      if (!time && looksTime(p.v)) time = p.v;
      if (!id && looksId(p.v)) id = p.v;
      var digits = p.v.replace(/[^\d]/g, '');
      if (!phone && digits.length >= 10 && digits.length <= 15 && /^\+?[\d\s()+-]+$/.test(p.v)) phone = p.v;
    });
    if (!code && !text) return;
    var key = id || (code + '|' + text).slice(0, 80);
    if (msgs.some(function (m) { return m.key === key; })) return;
    msgs.push({
      key: key,
      code: code || '',
      text: text,
      time: relTime(time),
      phone: phone,
      isNew: !seen[key]
    });
    seen[key] = 1;
    try { localStorage.setItem('fus-inbox-seen-v2', JSON.stringify(seen)); } catch (e) {}
  }

  function harvest(node, depth) {
    if (depth > 8 || node === null || typeof node !== 'object') return;
    if (Array.isArray(node)) {
      if (node.length && node.every(function (x) { return x && typeof x === 'object' && !Array.isArray(x); })) {
        var score = 0;
        for (var i = 0; i < Math.min(node.length, 5); i++) {
          var vals = Object.keys(node[i]).map(function (k) { return node[i][k]; });
          if (vals.some(function (v) { return isCode(v) || codeIn(v); })) score++;
          if (vals.some(function (v) { return typeof v === 'string' && v.length > 8 && !isCode(v); })) score++;
        }
        if (score >= node.length) node.forEach(pushMsg);
      }
      node.forEach(function (x) { harvest(x, depth + 1); });
      return;
    }
    Object.keys(node).forEach(function (k) { harvest(node[k], depth + 1); });
  }

  function digest(json) {
    hits++;
    src = '接口';
    var before = msgs.length;
    try { harvest(json, 0); } catch (e) { lastErr = 'parse: ' + e.message; }
    push();
    return msgs.length !== before;
  }

  /* ---------- 挂钩 fetch / XHR ---------- */
  function interesting(u) {
    return typeof u === 'string' &&
      (u.indexOf('/sms-api/') >= 0 || u.indexOf('inbox') >= 0 || u.indexOf('messages') >= 0);
  }

  try {
    var of = window.fetch;
    if (of && !of.__fus) {
      var nf = function (input) {
        var u = (typeof input === 'string') ? input : (input && input.url) || '';
        var p = of.apply(this, arguments);
        try {
          if (interesting(u)) p.then(function (res) { try { res.clone().json().then(digest).catch(function () {}); } catch (e) {} }).catch(function () {});
        } catch (e) {}
        return p;
      };
      nf.__fus = 1;
      window.fetch = nf;
    }
  } catch (e) {}

  try {
    var oo = XMLHttpRequest.prototype.open, os = XMLHttpRequest.prototype.send;
    if (!oo.__fus) {
      var no = function (m, u) { this.__fusUrl = u; return oo.apply(this, arguments); };
      no.__fus = 1;
      XMLHttpRequest.prototype.open = no;
      XMLHttpRequest.prototype.send = function () {
        var self = this;
        this.addEventListener('load', function () {
          if (!interesting(self.__fusUrl)) return;
          try { digest(JSON.parse(self.responseText)); } catch (e) {}
        });
        return os.apply(this, arguments);
      };
    }
  } catch (e) {}

  /* ---------- DOM 兜底扫描 ---------- */
  function domScan() {
    var found = 0;
    var nodes = document.querySelectorAll('li,tr,div,p,span,td,article');
    for (var i = 0; i < nodes.length && found < 60; i++) {
      var el = nodes[i];
      if (el.children.length > 6) continue;
      var tx = (el.textContent || '').trim();
      if (tx.length < 4 || tx.length > 300) continue;
      var m = tx.match(/\b\d{4,8}\b/);
      if (!m) continue;
      var key = 'dom|' + m[0] + '|' + tx.slice(0, 60);
      if (msgs.some(function (x) { return x.key === key; })) continue;
      msgs.push({ key: key, code: m[0], text: tx.slice(0, 200), time: '', phone: '', isNew: !seen[key] });
      seen[key] = 1;
      found++;
    }
    if (found) {
      if (src === '等待中') src = '页面';
      try { localStorage.setItem('fus-inbox-seen-v2', JSON.stringify(seen)); } catch (e) {}
      push();
    }
    return found;
  }

  window.__fusInbox = { rescan: function () { domScan(); push(); }, digest: digest };

  /* ---------- 启动 ---------- */
  function boot() {
    post({ type: 'status', text: '脚本已注入，等待数据…' });
    push({ hint: 'boot' });
    setTimeout(domScan, 1500);
    setTimeout(domScan, 4000);
    setTimeout(domScan, 9000);
    setTimeout(function () { push({ hint: 'idle-check' }); }, 12000);
    try {
      var mo = new MutationObserver(function () {
        clearTimeout(mo.__t);
        mo.__t = setTimeout(domScan, 900);
      });
      mo.observe(document.documentElement, { childList: true, subtree: true });
    } catch (e) {}
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', boot);
  else boot();
})();
