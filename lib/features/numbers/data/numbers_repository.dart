/// 号码目录抓取：原生 HTTP + 模板解析，完全不依赖 WebView。
///
/// 为什么能这么干：`/numbers/` 是 WordPress 服务端直出的页面，号码卡片是
/// 静态 HTML（`article.number-card`），不需要站点的会话签名。站点把签名锁
/// 只放在 `/sms-api/v1/*`（短信正文）上，目录页自己留了活口——它自己的
/// live.js 里写着 "This gate controls SMS bodies only."
///
/// 为什么不用 html 包：这段模板固定、字段固定，正则足够，且已在真实页面上
/// 验证 24/24 命中。站点改模板时这里会返回空列表 —— 上层会显示错误，
/// 不会静默给错数据。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'package:fus_inbox/core/webview/browser_identity.dart';
import 'package:fus_inbox/features/numbers/domain/available_number.dart';

/// 一页目录抓下来的结果。
class const NumberPage({required this.numbers, this.total}) {
  final List<AvailableNumber> numbers;

  /// 页面自报的号码总数（`N available numbers`），拿不到就是 null。
  final int? total;
}

/// 单张卡片的字段正则。
///
/// 全部按站点现有模板写死；任何一条不中，对应字段退回默认值而不是整卡丢弃。
final _cardRe = RegExp(
  r'<article\b[^>]*\bclass="[^"]*\bnumber-card\b[^"]*"[^>]*>.*?</article>',
  dotAll: true,
);
final _idRe = RegExp(r'data-live-card="([0-9a-fA-F]{8,})"');
final _numberRe = RegExp(r'/numbers/(\d{10,15})/');
final _areaRe = RegExp(r'class="number-area"[^>]*>(.*?)<', dotAll: true);
final _countRe = RegExp(r'data-count="(\d+)"');
final _timeRe = RegExp(r'<time\b[^>]*\bdata-rel-time="([^"]+)"');
final _freshRe = RegExp(r'\bis-fresh\b');
final _totalRe = RegExp(r'(\d+)\s+available numbers');

/// 只解模板里会出现的几个实体，不做通用解码。
String _unescape(String s) => s
    .replaceAll('&amp;', '&')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&#039;', "'")
    .replaceAll('&#39;', "'")
    .replaceAll('&middot;', '·')
    .replaceAll('&nbsp;', ' ');

/// 把 `Ohio · 419` 拆成州名与区号。
({String state, String area}) _splitArea(String raw) {
  final text = _unescape(raw).replaceAll(RegExp(r'\s+'), ' ').trim();
  var state = text;
  var area = '';
  final seps = ['·', '•', '|', '–', '-'];
  for (final sep in seps) {
    final i = text.indexOf(sep);
    if (i > 0) {
      state = text.substring(0, i).trim();
      area = text.substring(i + sep.length).trim();
      break;
    }
  }
  // 区号只留数字，形如 “419”。
  area = area.replaceAll(RegExp(r'[^\d]'), '');
  return (state: state, area: area);
}

/// 解析一页目录 HTML。
@visibleForTesting
NumberPage parseDirectory(String html) {
  final out = <AvailableNumber>[];
  final seen = <String>{};

  for (final m in _cardRe.allMatches(html)) {
    final card = m.group(0)!;
    final numMatch = _numberRe.firstMatch(card);
    if (numMatch == null) continue;
    final number = numMatch.group(1)!;

    final idMatch = _idRe.firstMatch(card);
    final id = idMatch?.group(1) ?? number;

    final areaMatch = _areaRe.firstMatch(card);
    final region = areaMatch == null
        ? (state: '', area: '')
        : _splitArea(areaMatch.group(1)!);

    final countMatch = _countRe.firstMatch(card);
    final count = int.tryParse(countMatch?.group(1) ?? '') ?? 0;

    if (!seen.add(number)) continue;
    out.add(
      AvailableNumber(
        id: id,
        number: number,
        state: region.state,
        areaCode: region.area,
        messageCount: count,
        lastTextAt: _timeRe.firstMatch(card)?.group(1),
        isFresh: _freshRe.hasMatch(card),
      ),
    );
  }

  final totalMatch = _totalRe.firstMatch(html);
  final total = int.tryParse(totalMatch?.group(1) ?? '');
  // 页面自报有号、却一张卡都没解析出来 = 站点模板变了。显式抛错，
  // 别让上层把「解析失败」显示成「这里没有号码」。
  if (out.isEmpty && total != null && total > 0) {
    throw NumberFetchException('目录解析失败：页面自报 $total 个号，但一张卡片都没匹配上，站点模板可能变了');
  }
  return NumberPage(numbers: out, total: total);
}

/// 目录数据源。
///
/// 不能是 `const` 主构造：[client] 是 `late final`，需要非 const 初始化。
class NumbersRepository({this.client}) {
  /// 可注入的 HTTP 客户端；为空时自建一个，由本实例负责关闭。
  final HttpClient? client;

  static const _base = 'https://freeussms.com';

  late final HttpClient _http = client ?? HttpClient()
    // Cloudflare 会给首次访问下发 cf_clearance / __cf_bm 这类 cookie，
    // 后续请求带上它们才像「同一个浏览器在连续访问」。
    // dart:io 的 HttpClient 默认就带 cookie 罐，但连接复用和空闲超时
    // 默认值偏小，翻页间隔 1.5~2.4 秒时容易重新建连接 + 丢 cookie，
    // 服务端看到的就是「一批互不相关的陌生请求」。
    ..connectionTimeout = const Duration(seconds: 15)
    ..idleTimeout = const Duration(seconds: 30);

  String _pageUrl(int page) =>
      page <= 1 ? '$_base/numbers/' : '$_base/numbers/page/$page/';

  /// 抓一页。失败抛 [NumberFetchException]。
  ///
  /// 用 `dart:io` 而不是 `package:http`：这里只需要「GET 一个页面、按 UTF-8 解码」，
  /// 内置客户端够用，还能少一个依赖。注意 [HttpClient] 不会自动带 User-Agent，
  /// 站点按 UA 区分移动端模板，必须显式设。
  Future<NumberPage> fetchPage(int page) async {
    final uri = Uri.parse(_pageUrl(page));
    late final HttpClientResponse res;
    try {
      final req = await _http.getUrl(uri).timeout(const Duration(seconds: 20));
      req.headers
        // 用当前浏览器身份里的 UA。
        // 必须和收件箱 WebView 用同一个值——同一台设备对同一站点
        // 呈现两种 UA 是最可疑的信号。用户点「换浏览器身份」后，
        // 这里也会自动跟着变。
        ..set(HttpHeaders.userAgentHeader, currentUserAgent)
        // 请求头要凑齐一整套：只有 UA 一个头本身就是特征。
        // 真实 Chrome 发目录页时至少带这些。
        ..set(
          HttpHeaders.acceptHeader,
          'text/html,application/xhtml+xml,application/xml;q=0.9,'
          'image/avif,image/webp,*/*;q=0.8',
        )
        ..set(HttpHeaders.acceptLanguageHeader, 'en-US,en;q=0.9')
        ..set(HttpHeaders.refererHeader, '$_base/numbers/')
        ..set(
          'sec-ch-ua',
          '"Chromium";v="120", "Google Chrome";v="120", "Not?A_Brand";v="99"',
        )
        ..set('sec-ch-ua-mobile', '?1')
        ..set('sec-ch-ua-platform', '"Android"')
        ..set('sec-fetch-dest', 'document')
        ..set('sec-fetch-mode', 'navigate')
        ..set('sec-fetch-site', 'same-origin')
        ..set('sec-fetch-user', '?1')
        ..set('upgrade-insecure-requests', '1');
      res = await req.close().timeout(const Duration(seconds: 20));
    } on Exception catch (e) {
      throw NumberFetchException('网络请求失败：$e');
    }
    if (res.statusCode != HttpStatus.ok) {
      // 响应体不读会占着连接不放。
      unawaited(res.drain<void>().catchError((Object _) {}));
      throw NumberFetchException('目录返回 HTTP ${res.statusCode}');
    }
    final body = await res.transform(utf8.decoder).join();
    return parseDirectory(body);
  }

  /// 站点模板固定每页 24 条（实测）。
  static const _pageSize = 24;

  /// 纯保险丝：号码池异常膨胀时别把请求数堆成无穷。
  static const _pageCap = 40;

  /// 页与页之间的间隔。
  ///
  /// 站点挂在 Cloudflare 后面，短时间连发请求最容易触发风控。
  /// 上一版是 120ms —— 抓完 5 页只花半秒，等于对站点做了一次小规模爆破。
  /// 现在给到 1.5 秒起步，再叠加随机抖动，让请求节奏看着像人。
  static const _pageGap = Duration(milliseconds: 1500);

  /// 单页重试次数。风控多半是临时的，退避后重试比直接放弃好；
  /// 但重试本身也是请求，所以最多两次。
  static const _maxRetry = 2;

  /// 抖动用的随机源。每次进程启动换一个种子，不追求密码学随机。
  static final _rnd = Random();

  /// 带抖动的页间隔。固定间隔在服务端看来同样可疑。
  Future<void> _pace(int page) async {
    if (page <= 1) return;
    // 1500ms + 0~900ms 随机抖动。
    // 之前写成 900*(page%3)~/3 —— 只会在 0/300/600 三个值上循环，
    // 是周期信号，服务端看得比固定间隔还清楚。
    final jitter = _rnd.nextInt(900);
    await Future<void>.delayed(_pageGap + Duration(milliseconds: jitter));
  }

  /// 顺序抓完整个目录。
  ///
  /// 站点每页 24 条、总数约百来条，所以顺序抓即可，不并发轰它。
  /// 任何一页失败且还没有数据时才抛错；已经拿到数据就保留已抓到的部分。
  ///
  /// 页数由「站点自报总数」精确推导，[maxPages] 只用来收紧上限。
  /// 注意不要再给总页数加余量：多抓一页就多一次请求，
  /// 而站点自己在最后一页就会给出不足 24 条的结果，循环自然结束。
  ///
  /// [onProgress] 每页抓完后回调一次，用于界面显示「已加载 N 个号」。
  /// [onPage] 每页抓完把「当前已有的完整列表快照」交出去，供上层立刻渲染。
  Future<List<AvailableNumber>> fetchAll({
    int? maxPages,
    void Function(int loaded, int page)? onProgress,
    void Function(List<AvailableNumber> soFar)? onPage,
  }) async {
    final out = <AvailableNumber>[];
    final seen = <String>{};
    var limit = maxPages ?? _pageCap;
    if (limit <= 0 || limit > _pageCap) limit = _pageCap;

    for (var page = 1; page <= limit; page++) {
      await _pace(page);

      // 单页失败先退避重试；重试仍失败再决定是放弃还是保留已有数据。
      NumberPage? batch;
      Object? lastError;
      for (var attempt = 0; attempt <= _maxRetry; attempt++) {
        try {
          batch = await fetchPage(page);
          break;
        } on Object catch (e) {
          // 只 catch NumberFetchException 是不够的：连接被重置、
          // 超时、TLS 握手失败都是 SocketException/HandshakeException，
          // 会直接穿透整个 fetchAll，一页抖动就让整次加载失败。
          lastError = e;
          if (attempt < _maxRetry) {
            // 退避：2s、5s。风控退避比立刻重试有效得多。
            await Future<void>.delayed(Duration(seconds: attempt == 0 ? 2 : 5));
          }
        }
      }

      if (batch == null) {
        if (out.isEmpty) {
          throw NumberFetchException('$lastError');
        }
        debugPrint('目录第 $page 页失败，保留已抓到的 ${out.length} 条：$lastError');
        break;
      }
      if (batch.numbers.isEmpty) break;

      // 首页拿到总数后精确收紧上限，不加余量。
      final total = batch.total;
      if (page == 1 && total != null && total > 0) {
        final needed = (total / _pageSize).ceil();
        if (needed < limit) limit = needed;
      }

      final before = out.length;
      for (final n in batch.numbers) {
        if (seen.add(n.number)) out.add(n);
      }
      // 整页都是重复的，说明已经绕回来了，收工。
      if (out.length == before) break;

      onProgress?.call(out.length, page);
      // 每页都给一次快照：首页拿到就能上屏，不用等 5 页全抓完。
      // List.unmodifiable 是必需的——上层会直接把这个 list 塞进 state，
      // 后续 add 会让界面看到正在变化的同一个对象。
      onPage?.call(List<AvailableNumber>.unmodifiable(out));

      // 不足一页 = 这是最后一页，不用再猜。
      if (batch.numbers.length < _pageSize) break;
    }
    return out;
  }

  /// 释放 HTTP 客户端。provider 销毁时调用。
  /// 关掉连接池。`force: true` 顺手掐掉还在飞的请求，页面销毁时不必等。
  void dispose() => _http.close(force: true);
}

class const NumberFetchException(this.message) implements Exception {
  final String message;

  @override
  String toString() => message;
}
