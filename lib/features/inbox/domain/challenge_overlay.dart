/// 在收件页里渲染「只含验证框」的覆盖层。
///
/// ## 为什么在收件页里做，不另开页面
///
/// 试过另开页面（`loadData` 装一段 HTML），真机卡在「正在准备验证…」。根因是安卓 WebView 给 `loadData` 生成的
/// 文档的 origin 是 **`null`**：页面里 `fetch('/sms-api/v1/session')`
/// 跨域被拦、`crypto.subtle` 在非安全上下文直接抛。`baseUrl` 只影响
/// 相对 URL 的解析，**改不了 origin**。
///
/// 收件页本身就是站点源 —— 有 cookie、有 `crypto.subtle`、站点自己的
/// `turnstile` loader 也已经加载好。所以在这里盖一层最省事也最可靠。
///
/// 参数来自 `SiteHold.challenge`（站点在
/// `403 + reader_verification_required` 的 body 里给的
/// `sitekey` / `action` / `cdata`）。
library;

import 'dart:convert';

/// 生成覆盖层脚本。
///
/// 只做三件事：盖一层白底、在里面渲染 Turnstile、把 token 交回来。
/// 不碰站点自己的页面结构 —— 它可能正在用那个文档做别的事。
///
/// [sitekey] / [action] / [cdata] 三个值**原样**塞进去（`jsonEncode`
/// 保证引号安全）。`cdata` 把这次挑战和后续 grant 绑在一起，自己编一个
/// 的话验证通过了也换不到 grant。
String challengeOverlayScript({
  required String sitekey,
  required String action,
  required String cdata,
}) {
  final jsSitekey = jsonEncode(sitekey);
  final jsAction = jsonEncode(action);
  final jsCdata = jsonEncode(cdata);
  return '''
(function () {
  var old = document.getElementById('__fus_cf');
  if (old && old.parentNode) old.parentNode.removeChild(old);

  var box = document.createElement('div');
  box.id = '__fus_cf';
  box.style.cssText = 'position:fixed;inset:0;z-index:2147483647;'
    + 'background:#fff;display:flex;align-items:center;justify-content:center';

  var inner = document.createElement('div');
  inner.id = '__fus_cf_slot';
  inner.style.cssText = 'padding:24px';
  box.appendChild(inner);
  document.body.appendChild(box);

  function hint(t) {
    var el = document.getElementById('__fus_cf_hint');
    if (!el) {
      el = document.createElement('div');
      el.id = '__fus_cf_hint';
      el.style.cssText = 'margin-top:18px;font-size:14px;color:#5f6368;'
        + 'text-align:center;max-width:320px;line-height:1.5';
      inner.appendChild(el);
    }
    el.textContent = t;
  }

  function render() {
    try {
      window.turnstile.render(inner, {
        sitekey: $jsSitekey,
        action: $jsAction,
        cData: $jsCdata,
        theme: 'light',
        language: 'en',
        callback: function (token) {
          hint('验证通过，正在继续…');
          if (window.FusInbox && window.FusInbox.postMessage) {
            window.FusInbox.postMessage(JSON.stringify({
              type: 'challengeToken', token: token
            }));
          }
        },
        'error-callback': function (code) {
          hint('验证失败（' + code + '），点上面重试。');
        },
        'expired-callback': function () {
          hint('验证已过期，正在重新加载…');
          render();
        }
      });
      hint('请完成下面的验证');
    } catch (e) {
      hint('渲染失败：' + (e && e.message ? e.message : e));
    }
  }

  if (!window.turnstile || !window.turnstile.render) {
    hint('验证组件还没就绪，稍等…');
    var tries = 0;
    var tick = setInterval(function () {
      if (window.turnstile && window.turnstile.render) {
        clearInterval(tick);
        render();
      } else if (++tries > 100) {
        clearInterval(tick);
        hint('验证组件加载超时，请重试。');
      }
    }, 150);
  } else {
    render();
  }
})();
''';
}
