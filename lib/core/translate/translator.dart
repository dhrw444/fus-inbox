/// 短信正文翻译。
///
/// 站点是英文的，验证码短信也是英文（"Your verification code is..."）。
/// 用户要的是「一眼看懂」，所以正文在卡片里给中文译文，原文仍可展开查看。
///
/// 用 Google 的公开 translate_a/single 端点：不需要 key、响应快、
/// 对短文本足够准。它没有 SLA，所以整条链路必须可降级——
/// 翻译失败就显示原文，绝不能因为翻译挂了让短信看不见。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 一条消息的翻译结果。
class const Translation({
  required this.text,
  required this.sourceLang,
  required this.toLang,
}) {
  /// 译文。
  final String text;

  /// 检测到的源语言（服务端给什么就用什么）。
  final String sourceLang;

  /// 目标语言。
  final String toLang;
}

/// 翻译失败的原因分类。
///
/// 区分「网络挂了」和「内容不用翻」：前者值得重试，后者重试是浪费。
enum TranslationFailure() {
  /// 网络 / 服务端错误，可重试。
  network(),

  /// 内容为空或已是目标语言，不必翻。
  notNeeded(),

  /// 被限流，稍后再说。
  rateLimited(),
}

/// 翻译失败。
class const TranslationException({required this.reason, required this.detail})
    implements Exception {
  final TranslationFailure reason;
  final String detail;

  @override
  String toString() => 'TranslationException($reason): $detail';
}

/// Google 公开接口的客户端。
///
/// 设计要点：
/// - 同一个 [Translator] 复用一个 [HttpClient]，避免每条消息新建连接。
/// - 内存缓存按「原文 -> 译文」存。短信用语高度重复（同一家服务的验证码
///   文案一模一样），缓存命中率很高，能省掉绝大部分请求。
/// - 并发请求串行化：公开端点对突发并发很敏感，逐条翻更稳。
class Translator({this.client, this.toLang = 'zh-CN'}) {
  /// 可注入的 HTTP 客户端；为空时自建一个，由本实例负责关闭。
  final HttpClient? client;

  /// 目标语言。默认简体中文。
  final String toLang;

  late final HttpClient _http = client ?? HttpClient();

  /// 原文到译文的缓存。上限 [maxCache]，满了清空——短信场景里
  /// 老文案复用价值低，不值得做 LRU。
  final Map<String, Translation> _cache = {};

  /// 缓存上限。
  static const maxCache = 300;

  /// 串行化用：上一条翻完再发下一条。
  Future<void> _queue = Future<void>.value();

  static const _endpoint =
      'https://translate.googleapis.com/translate_a/single';

  static final _cjk = RegExp(r'[\u4e00-\u9fff]');
  static final _latin = RegExp(r'[A-Za-z]');

  /// 判断这段文本是否值得翻译。
  ///
  /// 纯数字、纯符号、以及已经是中文的内容直接跳过——把它们发给服务端
  /// 既浪费配额，也会让译文出现「已翻译」的假象。
  static bool needsTranslation(String text) {
    final t = text.trim();
    if (t.length < 2) return false;
    // 已经是中文：不需要翻。
    if (_cjk.hasMatch(t) && !_latin.hasMatch(t)) return false;
    // 一个拉丁字母都没有（纯数字验证码 / 纯符号），翻了也是原样。
    if (!_latin.hasMatch(t)) return false;
    return true;
  }

  /// 翻译一段文本。
  ///
  /// 命中缓存直接返回。失败抛 [TranslationException]，
  /// 调用方负责降级到原文显示。
  Future<Translation> translate(String text) {
    final t = text.trim();
    final cached = _cache[t];
    if (cached != null) return Future<Translation>.value(cached);

    if (!needsTranslation(t)) {
      throw TranslationException(
        reason: TranslationFailure.notNeeded,
        detail: '内容无需翻译',
      );
    }

    // 排队：上一条结束再发下一条。链上任何一次失败都不能卡住后来者，
    // 所以 catchError 把异常吞掉只用于放行队列。
    final result = _queue.then((_) => _request(t));
    _queue = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  Future<Translation> _request(String text) async {
    final uri = Uri.https('translate.googleapis.com', '/translate_a/single', {
      'client': 'gtx',
      'sl': 'auto',
      'tl': toLang,
      'dt': 't',
      'q': text,
    });

    try {
      final req = await _http.getUrl(uri).timeout(const Duration(seconds: 12));
      req.headers.set(HttpHeaders.userAgentHeader, _ua);
      final res = await req.close().timeout(const Duration(seconds: 12));

      if (res.statusCode == HttpStatus.tooManyRequests) {
        unawaited(res.drain<void>().catchError((Object _) {}));
        throw const TranslationException(
          reason: TranslationFailure.rateLimited,
          detail: 'HTTP 429',
        );
      }
      if (res.statusCode != HttpStatus.ok) {
        unawaited(res.drain<void>().catchError((Object _) {}));
        throw TranslationException(
          reason: TranslationFailure.network,
          detail: 'HTTP ${res.statusCode}',
        );
      }

      final body = await res.transform(utf8.decoder).join();
      final parsed = _parse(body);
      if (_cache.length >= maxCache) _cache.clear();
      _cache[text] = parsed;
      return parsed;
    } on TranslationException {
      rethrow;
    } on Exception catch (e) {
      throw TranslationException(
        reason: TranslationFailure.network,
        detail: '$e',
      );
    }
  }

  /// 解析 translate_a/single 的响应。
  ///
  /// 形状是嵌套数组：`[[[译文, 原文, ...], ...], ...]`。
  /// 各段译文要拼起来才是完整结果（长文本会被切段）。
  static Translation _parse(String body) {
    late final List<dynamic> root;
    try {
      root = jsonDecode(body) as List<dynamic>;
    } on Object catch (e) {
      throw TranslationException(
        reason: TranslationFailure.network,
        detail: '响应不是 JSON：$e',
      );
    }
    if (root.isEmpty) {
      throw const TranslationException(
        reason: TranslationFailure.network,
        detail: '响应为空数组',
      );
    }

    final buf = StringBuffer();
    final segs = root[0];
    if (segs is List) {
      for (final s in segs) {
        if (s is List && s.isNotEmpty && s[0] is String) {
          buf.write(s[0] as String);
        }
      }
    }

    final detected = root.length > 2 && root[2] is String
        ? root[2] as String
        : 'auto';

    final out = buf.toString().trim();
    if (out.isEmpty) {
      throw const TranslationException(
        reason: TranslationFailure.network,
        detail: '译文为空',
      );
    }
    return Translation(text: out, sourceLang: detected, toLang: 'zh-CN');
  }

  /// 关掉连接池。
  void dispose() => _http.close(force: true);

  static const _ua =
      'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';
}
