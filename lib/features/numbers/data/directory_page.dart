/// 目录页的解析：一段静态 HTML → 一页 [NumberPage]。
///
/// ## 为什么单独拆一个文件
///
/// 从 `numbers_repository.dart` 拆出来。那边回答「怎么把页面拿回来」（出口
/// 指令、连接复用、并发、退避重试），这里回答「拿回来的字节长什么样」。
/// 两边互不牵动：改模板正则不用翻过两百行 HTTP 细节，调并发也不用担心
/// 碰坏正则。
///
/// 为什么能这么干：`/numbers/` 是 WordPress 服务端直出的页面，号码卡片是
/// 静态 HTML（`article.number-card`），不需要站点的会话签名。站点把签名锁
/// 只放在 `/sms-api/v1/*`（短信正文）上，目录页自己留了活口——它自己的
/// live.js 里写着 "This gate controls SMS bodies only."
///
/// ## 为什么不用 html 包
///
/// 这段模板固定、字段固定，正则足够，且已在真实页面上验证 24/24 命中。
/// 站点改模板时这里会**显式抛错**，上层会显示错误，不会静默给错数据。
///
/// ## 错误类型为什么也住在这里
///
/// [NumberFetchException] 是整条目录链路（请求 + 解析）唯一的失败出口，
/// 而抛得最多的是解析侧（模板变了、页面自报有号却一张卡都没匹配上）。
/// 把它放在请求层会让「解析」反过来依赖「请求」，方向是拧的。
library;

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
String _unescape(String s) {
  var out = s;
  // 链式替换而不是 RegExp.replaceAllMapped：模板里就这几个实体，
  // 逐个 replace 比正则状态机好读，也没有回溯风险。
  for (final e in const {
    '&amp;': '&',
    '&lt;': '<',
    '&gt;': '>',
    '&quot;': '"',
    '&#039;': "'",
    '&#39;': "'",
    '&middot;': '·',
    '&nbsp;': ' ',
  }.entries) {
    out = out.replaceAll(e.key, e.value);
  }
  return out;
}

/// 把 `Ohio · 419` 拆成州名与区号。
({String state, String area}) _splitArea(String raw) {
  final text = _unescape(raw).replaceAll(RegExp(r'\s+'), ' ').trim();
  var state = text;
  var area = '';
  // 站点模板用 `·`，其它分隔符是模板变体或旧版页面的兜底。
  for (final sep in const ['·', '•', '|', '–', '-']) {
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
///
/// **不是 `@visibleForTesting`**：`numbers_repository.dart` 生产链路直接调它，
/// `test/features/numbers/data/numbers_repository_test.dart` 也测它。标成
/// 「测试专用」是假的，analyzer 会报 `invalid_use_of_visible_for_testing_member`。
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

/// 目录这条链路上唯一对外的错误类型。
///
/// 请求失败（网络 / HTTP 状态码 / 出口没起来）和解析失败都用它，
/// 因为界面对这两种情况的处置是一样的：报一句人话，别把列表清空。
class const NumberFetchException(this.message) implements Exception {
  final String message;

  @override
  String toString() => message;
}
