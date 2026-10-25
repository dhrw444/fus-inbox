/// 号码目录抓取。
///
/// freeussms 的 `/numbers/` 及其分页 `/numbers/page/N/` 是服务端直出的公开页面
/// （没有 Turnstile，也不需要签名会话），所以这里纯 HTTP + HTML 解析。
/// 页面结构（每张卡）：
///   article.number-card[data-live-card=<32hex>]
///     .number-area                -> "Ohio · 419"
///     a[href*="/numbers/<digits>/"] -> 号码
///     [data-count]                -> 已收条数
///     time[data-rel-time]         -> 最后一条时间
///     .is-fresh                   -> 最近有短信
library;

import 'dart:convert';

import 'package:html/parser.dart' as html_parser;
import 'package:html/dom.dart';
import 'package:http/http.dart' as http;

import 'package:freedium_mobile/features/numbers/domain/available_number.dart';

class NumbersRepository() {
  final http.Client _client = http.Client();

  static const _base = 'https://freeussms.com';
  static const _ua =
      'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';

  static const _maxPages = 12;

  Map<String, String> get _headers => {
    'User-Agent': _ua,
    'Accept': 'text/html,application/xhtml+xml',
    'Accept-Language': 'en-US,en;q=0.9',
    'Referer': '$_base/numbers/',
  };

  String _pageUrl(int page) =>
      page <= 1 ? '$_base/numbers/' : '$_base/numbers/page/$page/';

  /// 抓一页，返回该页的号码。
  Future<List<AvailableNumber>> fetchPage(int page) async {
    final res = await _client
        .get(Uri.parse(_pageUrl(page)), headers: _headers)
        .timeout(const Duration(seconds: 20));
    if (res.statusCode != 200) {
      throw NumbersException('目录第 $page 页返回 ${res.statusCode}');
    }
    // 站点是 UTF-8；显式解码，避免 latin1 兜底毁掉州名。
    return parseDirectory(utf8.decode(res.bodyBytes, allowMalformed: true));
  }

  /// 抓完整目录（逐页直到空页或超出上限）。
  ///
  /// onProgress 用于界面显示 "已加载 N 个号"。
  Future<List<AvailableNumber>> fetchAll({
    void Function(int loaded, int page)? onProgress,
  }) async {
    final out = <AvailableNumber>[];
    final seen = <String>{};
    for (var page = 1; page <= _maxPages; page++) {
      List<AvailableNumber> batch;
      try {
        batch = await fetchPage(page);
      } catch (e) {
        if (out.isEmpty) rethrow;
        break; // 已经有数据就停，别让分页把整次刷新搞失败
      }
      if (batch.isEmpty) break;
      var added = 0;
      for (final n in batch) {
        if (seen.add(n.id)) {
          out.add(n);
          added++;
        }
      }
      onProgress?.call(out.length, page);
      if (added == 0) break; // 分页开始重复 -> 到头了
    }
    return out;
  }

  void dispose() => _client.close();
}

/// 从目录页 HTML 里提取号码卡。
///
/// 抽成静态方法便于单测直接喂 HTML，不用起网络。
List<AvailableNumber> parseDirectory(String html) {
  final doc = html_parser.parse(html);
  final cards = doc.querySelectorAll('article.number-card');
  final out = <AvailableNumber>[];

  for (final card in cards) {
    final id = card.attributes['data-live-card'] ?? '';
    final link = _firstNumberLink(card);
    if (link == null) continue;

    final number = link;
    final area = _text(card, '.number-area');
    var state = area;
    var areaCode = '';
    if (area.contains('·')) {
      final parts = area.split('·');
      state = parts.first.trim();
      areaCode = parts.length > 1 ? parts[1].trim() : '';
    }

    final countRaw = _firstWithAttr(card, '[data-count]', 'data-count');
    final lastText = _firstWithAttr(
      card,
      'time[data-rel-time]',
      'data-rel-time',
    );
    final cls = card.attributes['class'] ?? '';

    out.add(
      AvailableNumber(
        id: id.isEmpty ? number : id,
        number: number,
        state: state,
        areaCode: areaCode,
        messageCount: int.tryParse(countRaw) ?? 0,
        lastTextAt: lastText.isEmpty ? null : lastText,
        isFresh: cls.contains('is-fresh'),
      ),
    );
  }
  return out;
}

/// 从卡里取出 `/numbers/<digits>/` 的数字部分。
String? _firstNumberLink(Element card) {
  final re = RegExp(r'/numbers/(\d{10,15})/');
  for (final a in card.querySelectorAll('a[href]')) {
    final m = re.firstMatch(a.attributes['href'] ?? '');
    if (m != null) return m.group(1);
  }
  return null;
}

String _text(Element root, String selector) {
  final el = root.querySelector(selector);
  return el == null ? '' : el.text.trim();
}

String _firstWithAttr(Element root, String selector, String attr) {
  final el = root.querySelector(selector);
  if (el == null) return '';
  return el.attributes[attr] ?? '';
}

class NumbersException implements Exception {
  const NumbersException(this.message);
  final String message;
  @override
  String toString() => message;
}
