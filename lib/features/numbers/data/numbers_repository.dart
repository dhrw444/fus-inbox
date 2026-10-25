/// 号码目录抓取：原生 HTTP + 模板解析，完全不依赖 WebView。
///
/// 为什么能这么干：`/numbers/` 是 WordPress 服务端直出的页面，号码卡片是
/// 静态 HTML（`article.number-card`），不需要站点的会话签名。站点把签名锁
/// 只放在 `/sms-api/v1/*`（短信正文）上，目录页自己留了活口——它自己的
/// live.js 里写着 "This gate controls SMS bodies only."
///
/// 为什么不用 html 包：CI 用 `flutter pub get --enforce-lockfile`，新增依赖
/// 会让 lockfile 失配直接失败。这段模板固定、字段固定，正则足够且已在真实
/// 页面上验证 24/24 命中。站点改模板时这里会返回空列表 —— 上层会显示错误，
/// 不会静默给错数据。
library;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

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
/// 不能是 `const` 主构造：[_http] 是 `late final`，需要非 const 初始化。
class NumbersRepository({this.client}) {
  final http.Client? client;

  static const _base = 'https://freeussms.com';
  static const _ua =
      'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';

  /// 未注入时自建一个，由本实例负责关闭——共用静态客户端的话
  /// [dispose] 会把别人的连接一起关掉。
  late final http.Client _http = client ?? http.Client();

  String _pageUrl(int page) =>
      page <= 1 ? '$_base/numbers/' : '$_base/numbers/page/$page/';

  /// 抓一页。失败抛 [NumberFetchException]。
  Future<NumberPage> fetchPage(int page) async {
    final uri = Uri.parse(_pageUrl(page));
    late final http.Response res;
    try {
      res = await _http
          .get(
            uri,
            headers: {
              'User-Agent': _ua,
              'Accept': 'text/html,application/xhtml+xml',
              'Accept-Language': 'en-US,en;q=0.9',
              'Referer': '$_base/numbers/',
            },
          )
          .timeout(const Duration(seconds: 20));
    } on Exception catch (e) {
      throw NumberFetchException('网络请求失败：$e');
    }
    if (res.statusCode != 200) {
      throw NumberFetchException('目录返回 HTTP ${res.statusCode}');
    }
    return parseDirectory(res.body);
  }

  /// 顺序抓完整个目录。
  ///
  /// 站点每页 24 条、总数约百来条，所以顺序抓即可，不并发轰它。
  /// 任何一页失败且还没有数据时才抛错；已经拿到数据就保留已抓到的部分。
  ///
  /// [onProgress] 每页抓完后回调一次，用于界面显示「已加载 N 个号」。
  Future<List<AvailableNumber>> fetchAll({
    int maxPages = 15,
    void Function(int loaded, int page)? onProgress,
  }) async {
    final out = <AvailableNumber>[];
    final seen = <String>{};

    for (var page = 1; page <= maxPages; page++) {
      late final NumberPage batch;
      try {
        batch = await fetchPage(page);
      } on NumberFetchException catch (e) {
        if (out.isEmpty) rethrow;
        debugPrint('目录第 $page 页失败，保留已抓到的 ${out.length} 条：$e');
        break;
      }
      if (batch.numbers.isEmpty) break;

      final before = out.length;
      for (final n in batch.numbers) {
        if (seen.add(n.number)) out.add(n);
      }
      // 整页都是重复的，说明已经绕回来了，收工。
      if (out.length == before) break;

      onProgress?.call(out.length, page);

      if (page < maxPages) {
        await Future<void>.delayed(const Duration(milliseconds: 120));
      }
    }
    return out;
  }

  /// 释放 HTTP 客户端。provider 销毁时调用。
  void dispose() => _http.close();
}

class const NumberFetchException(this.message) implements Exception {
  final String message;

  @override
  String toString() => message;
}
