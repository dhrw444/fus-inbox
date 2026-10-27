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

import 'package:flutter/foundation.dart';

import 'package:fus_inbox/core/webview/http_headers.dart';
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
    // 连接复用是这里唯一真正有效的提速手段。
    //
    // 实测单页耗时构成：DNS 0.27s + TCP 0.28s + **TLS 握手 1.5~1.8s**
    // + 传输。TLS 占了六成以上，而它只在新建连接时发生一次。
    // 只要把 5 页塞进同一条 keep-alive 连接，后 4 页能省掉 4 次握手，
    // 合计少 6~7 秒——比调整任何页间隔都管用。
    //
    // maxConnectionsPerHost 给到 6：并发抓 3 页时每个都要独立连接，
    // 默认值在某些平台上偏小，会导致请求排队等连接。
    ..maxConnectionsPerHost = 6
    ..connectionTimeout = const Duration(seconds: 15)
    // idleTimeout 要盖住整个抓取过程（并发后约 5 秒），
    // 太短会在页与页之间被回收，等于每次重握手。
    ..idleTimeout = const Duration(seconds: 45)
    // 站点返回 gzip，解压由客户端做，省带宽也省时间。
    ..autoUncompress = true;

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
      applyBrowserHeaders(req.headers, base: _base, referer: _pageUrl(page));
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

  /// 单页重试次数。风控多半是临时的，退避后重试比直接放弃好；
  /// 但重试本身也是请求，所以最多两次。
  static const _maxRetry = 2;

  /// 带抖动的页间隔。固定间隔在服务端看来同样可疑。
  /// 抓完整个目录。
  ///
  /// 策略是「先探后并」：
  ///   1. 先单独抓第 1 页 —— 拿到站点自报总数，就能确定到底有几页
  ///   2. 剩下的页**并发**抓，用信号量限制同时最多 3 个在飞
  ///
  /// 为什么并发：单页实测 2~4 秒（站点在 Cloudflare 后面，握手本身慢），
  /// 5 页串行就是 10 秒起。这是加载慢的真正原因，不是页间隔。
  /// 限到 3 个并发是折中：既不像爆破，又能把 10 秒压到 4 秒左右。
  ///
  /// 页数由「站点自报总数」精确推导，[maxPages] 只用来收紧上限。
  ///
  /// [onProgress] 每完成一页回调一次，用于界面显示「已加载 N 个号」。
  /// [onPage] 每次有页完成就把当前完整快照交出去，供上层立刻渲染。
  Future<List<AvailableNumber>> fetchAll({
    int? maxPages,
    void Function(int loaded, int page)? onProgress,
    void Function(List<AvailableNumber> soFar)? onPage,
  }) async {
    var limit = maxPages ?? _pageCap;
    if (limit <= 0 || limit > _pageCap) limit = _pageCap;

    // 第 1 页：必须单独先来，因为要读它自报的总数。
    final first = await _fetchWithRetry(1);
    if (first == null || first.numbers.isEmpty) {
      throw NumberFetchException('首页抓取失败');
    }

    final total = first.total;
    if (total != null && total > 0) {
      final needed = (total / _pageSize).ceil();
      if (needed < limit) limit = needed;
    }

    final seen = <String>{};
    final out = <AvailableNumber>[];
    for (final n in first.numbers) {
      if (seen.add(n.number)) out.add(n);
    }
    onProgress?.call(out.length, 1);
    onPage?.call(List<AvailableNumber>.unmodifiable(out));

    if (limit <= 1 || first.numbers.length < _pageSize) {
      return out;
    }

    // 剩余页并发。
    //
    // 三个必须注意的点（第一版全踩了）：
    //   1. 任务分配要在**同步段**里完成：先 removeAt 再 await。
    //      否则两个 worker 可能在 await 间隙拿到同一页，重复请求。
    //   2. 单页失败不能让 worker 退出——它退出后队列里剩下的页就没人抓了。
    //      正确做法是记一笔继续取下一页。
    //   3. out / seen 的写入要串行化。Dart 虽然单线程，但 await 之间
    //      交错的写入会让 onPage 快照出现「号码忽多忽少」的抖动。
    final queue = <int>[for (var p = 2; p <= limit; p++) p];
    var done = 1;
    var failed = 0;

    /// 把一个任务的结果并入主列表。
    /// 抽成同步函数，保证「改 out + 回调」是一个不可分割的片段。
    void mergeBatch(NumberPage batch) {
      done++;
      for (final n in batch.numbers) {
        if (seen.add(n.number)) out.add(n);
      }
      onProgress?.call(out.length, done);
      onPage?.call(List<AvailableNumber>.unmodifiable(out));
    }

    Future<void> worker() async {
      while (true) {
        // 取值和判空在同一个同步片段里，中间没有 await。
        if (queue.isEmpty) return;
        final page = queue.removeAt(0);

        final batch = await _fetchWithRetry(page);
        if (batch == null) {
          // 这一页彻底失败了，但**不退出**——继续抓剩下的。
          failed++;
          continue;
        }
        if (batch.numbers.isEmpty) {
          // 空页意味着站点已经没有更多了，清空队列让所有 worker 收工。
          queue.clear();
          return;
        }
        mergeBatch(batch);
      }
    }

    const concurrency = 3;
    await Future.wait([
      for (var i = 0; i < concurrency && i < limit - 1; i++) worker(),
    ]);

    if (out.isEmpty) {
      throw NumberFetchException('目录抓取失败（$failed 页出错）');
    }
    // 全部页都失败时 out 只有首页那批，这里补一条日志便于排查。
    if (failed > 0) {
      debugPrint('目录：$failed 页抓取失败，已拿到 ${out.length} 个号');
    }
    return out;
  }

  /// 抓单页并带退避重试。失败返回 null。
  Future<NumberPage?> _fetchWithRetry(int page) async {
    Object? lastError;
    for (var attempt = 0; attempt <= _maxRetry; attempt++) {
      try {
        return await fetchPage(page);
      } on Object catch (e) {
        // 只 catch 自定义异常不够：连接重置、超时、TLS 握手失败都是
        // SocketException / HandshakeException，会穿透整个 fetchAll。
        lastError = e;
        if (attempt < _maxRetry) {
          // 退避 600ms / 1.5s。真正的风控拒绝会持续 403/429，
          // 多等几秒也救不回来；偶发网络抖动则是重试越早越好。
          await Future<void>.delayed(
            Duration(milliseconds: attempt == 0 ? 600 : 1500),
          );
        }
      }
    }
    debugPrint('目录第 $page 页失败：$lastError');
    return null;
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
