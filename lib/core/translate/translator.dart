/// 短信正文翻译。
///
/// 站点是英文的，验证码短信也是英文（"Your verification code is..."）。
/// 用户要的是「一眼看懂」，所以正文在卡片里给中文译文，原文仍可展开查看。
///
/// 三家引擎轮着上，全是各家网页端在用的公开端点，不需要 key：
///
/// - **微软** `edge.microsoft.com/translate/translatetext`
///   Edge 浏览器内置翻译在用的端点。**不需要 token、不需要 cookie、
///   不需要先抓页面**，POST 一个 JSON 数组就回译文，还能自动识别源语言。
///   国内可直连。这是三家实现里最干净的一条，也是默认首选。
/// - **Google** `translate.googleapis.com/translate_a/single?client=gtx`
///   最准，但国内网络经常连不通。
/// - **Yandex** `browser.translate.yandex.net/api/v1/tr.json/translate`
///   只要一个浏览器 UA，最轻量；但 `lang` 必须显式给源语言，所以先调 detect。
///
/// 全部没有 SLA，所以整条链路必须可降级——翻译失败就显示原文，
/// 绝不能因为翻译挂了让短信看不见。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 一条消息的翻译结果。
class const Translation({
  required this.text,
  required this.sourceLang,
  required this.toLang,
  required this.engine,
}) {
  /// 译文。
  final String text;

  /// 检测到的源语言（服务端给什么就用什么）。
  final String sourceLang;

  /// 目标语言。
  final String toLang;

  /// 实际出结果的引擎。设置页用它显示「上次用的谁」。
  final TranslateEngine engine;
}

/// 可用的翻译引擎。
enum TranslateEngine() {
  /// 微软。Edge 内置翻译的端点，无需 token，国内可直连。默认首选。
  bing(),

  /// 谷歌。质量最好，但国内常连不通。
  google(),

  /// Yandex。最轻，只认一个 UA。
  yandex();

  /// 从存盘的名字还原。认不出来就回落默认引擎。
  ///
  /// 放在枚举上而不是 prefs 里：存盘用的是 [name]，读回也必须用同一套
  /// 规则，两处各写一份迟早会漂。改名时要在这里加兼容映射，否则旧存档
  /// 会被静默当成默认值——用户会以为设置被重置了。
  static TranslateEngine fromName(String? name) {
    for (final e in TranslateEngine.values) {
      if (e.name == name) return e;
    }
    return TranslateEngine.bing;
  }

  /// 设置页显示的名字。
  String get label => switch (this) {
    TranslateEngine.google => '谷歌',
    TranslateEngine.bing => '微软',
    TranslateEngine.yandex => 'Yandex',
  };
}

/// 翻译失败的原因分类。
///
/// 区分「网络挂了」和「内容不用翻」：前者值得换引擎重试，后者重试是浪费。
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

/// 多引擎翻译客户端。
///
/// 设计要点：
/// - 同一个 [Translator] 复用一个 [HttpClient]，避免每条消息新建连接。
/// - 内存缓存按「原文 -> 译文」存。短信用语高度重复（同一家服务的验证码
///   文案一模一样），缓存命中率很高，能省掉绝大部分请求。
/// - 并发请求串行化：公开端点对突发并发很敏感，逐条翻更稳。
/// - [preferred] 排在最前，其余按 [fallbackOrder] 依次补位；
///   任一引擎成功就停，全部失败才抛异常。
class Translator({this.client, this.toLang = 'zh-CN', this.preferred}) {
  /// 可注入的 HTTP 客户端；为空时自建一个，由本实例负责关闭。
  final HttpClient? client;

  /// 目标语言。默认简体中文。
  final String toLang;

  /// 优先尝试的引擎；为空时用 [TranslateEngine.bing]。
  final TranslateEngine? preferred;

  late final HttpClient _http = client ?? HttpClient();

  /// 原文到译文的缓存。上限 [maxCache]，满了清空——短信场景里
  /// 老文案复用价值低，不值得做 LRU。
  final Map<String, Translation> _cache = {};

  /// 每个引擎连续失败的次数。用来在本次会话里把坏引擎排到后面，
  /// 避免每条短信都先等谷歌超时 12 秒。
  final Map<TranslateEngine, int> _fails = {};

  /// 上次成功的引擎。它排在最前，省掉重试坏引擎的时间。
  TranslateEngine? _lastGood;

  /// 连续失败几次就降到末位。
  ///
  /// 设 1 而不是 2：谷歌在不通的网络里每次都要吃满超时，
  /// 试第二次纯粹是浪费用户 6 秒。失败一次就沉底，成功一次就复位。
  static const _demoteAfter = 1;

  /// 缓存上限。
  static const maxCache = 300;

  /// 串行化用：上一条翻完再发下一条。
  Future<void> _queue = Future<void>.value();

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

  /// 本次会话里各引擎的实际尝试顺序。
  ///
  /// 规则：
  /// 1. 上次成功的引擎排最前——它已经被证明在这台设备上能用。
  /// 2. 首选其次，用户的选择仍然受尊重。
  /// 3. 失败过 `demoteAfter` 次的沉到末尾。
  ///
  /// 光靠「首选在前」不够：谷歌不通时每条短信都要先吃满超时再降级，
  /// 用户看到的是每张卡片都卡几秒。让成功过的引擎记住位置才真的快。
  List<TranslateEngine> get engineOrder => orderEngines(
    preferred: preferred,
    lastGood: _lastGood,
    fails: _fails,
    demoteAfter: _demoteAfter,
  );

  /// [engineOrder] 的纯逻辑本体。
  ///
  /// 抽成静态纯函数是为了能真测：[engineOrder] 依赖实例里的私有状态，
  /// 测试没法把「某引擎已经失败过一次」注入进去，只能靠真跑一次网络
  /// 失败来间接验证——而那个间接验证会被 [_lastGood] 盖住（成功过的
  /// 引擎本来就排第一，沉底逻辑没机会显形）。变异测试实锤过这一点。
  ///
  /// 规则：
  /// 1. 上次成功的引擎排最前——它已被证明在这台设备上能用。
  /// 2. 首选其次，用户的选择仍然受尊重。
  /// 3. 失败次数达到 [demoteAfter] 的，沉到末尾。
  static List<TranslateEngine> orderEngines({
    required TranslateEngine? preferred,
    required TranslateEngine? lastGood,
    required Map<TranslateEngine, int> fails,
    required int demoteAfter,
  }) {
    final head = preferred ?? TranslateEngine.bing;
    // 这里不排 lastGood 与 head 的重复：下面 healthy 的 contains 判断
    // 就是去重。实测过——把 e != lastGood 加回去，行为一模一样，
    // 也就是说那个条件是不可测的冗余分支。
    final base = <TranslateEngine>[
      if (lastGood != null) lastGood,
      head,
      for (final e in TranslateEngine.values)
        if (e != head) e,
    ];
    final healthy = <TranslateEngine>[];
    final sick = <TranslateEngine>[];
    for (final e in base) {
      if ((fails[e] ?? 0) >= demoteAfter) {
        sick.add(e);
      } else if (!healthy.contains(e)) {
        healthy.add(e);
      }
    }
    return [...healthy, ...sick];
  }

  /// 翻译一段文本。
  ///
  /// 命中缓存直接返回。全部引擎都失败才抛 [TranslationException]，
  /// 调用方负责降级到原文显示。
  Future<Translation> translate(String text) {
    final t = text.trim();
    final cached = _cache[t];
    if (cached != null) return Future<Translation>.value(cached);

    if (!needsTranslation(t)) {
      throw const TranslationException(
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

  /// 依次试各引擎，第一个成功就返回。
  ///
  /// 注意「无需翻译」不是失败：它直接抛出，不触发降级——
  /// 换三家引擎翻同一条纯数字没有意义。
  Future<Translation> _request(String text) async {
    TranslationFailure? lastReason;
    String? lastDetail;
    var tried = 0;

    for (final engine in engineOrder) {
      try {
        final r = await _run(engine, text);
        _fails[engine] = 0;
        _lastGood = engine;
        if (_cache.length >= maxCache) _cache.clear();
        _cache[text] = r;
        return r;
      } on TranslationException catch (e) {
        if (e.reason == TranslationFailure.notNeeded) rethrow;
        tried++;
        lastReason = e.reason;
        lastDetail = '${engine.label}: ${e.detail}';
        _fails[engine] = (_fails[engine] ?? 0) + 1;
      }
    }

    throw TranslationException(
      reason: lastReason ?? TranslationFailure.network,
      detail: tried == 0 ? '没有可用引擎' : '$tried 个引擎都失败（$lastDetail）',
    );
  }

  Future<Translation> _run(TranslateEngine engine, String text) =>
      switch (engine) {
        TranslateEngine.google => _google(text),
        TranslateEngine.bing => _bingTranslate(text),
        TranslateEngine.yandex => _yandex(text),
      };

  // ── Google ───────────────────────────────────────────────────────────

  Future<Translation> _google(String text) async {
    final uri = Uri.parse(_googleEndpoint).replace(
      queryParameters: {
        'client': 'gtx',
        'sl': 'auto',
        'tl': toLang,
        'dt': 't',
        'q': text,
      },
    );

    final body = await _get(uri, _ua);
    final decoded = _decode(body);
    // 谷歌回的是 `[[["译文","原文",...],...],"en",...]`。
    // 先收窄成 List，后面的下标访问才不会被 analyzer 判成可能为 null。
    if (decoded is! List || decoded.isEmpty) {
      throw const TranslationException(
        reason: TranslationFailure.network,
        detail: '响应不是非空数组',
      );
    }
    final root = decoded;

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

    return Translation(
      text: _ensureText(buf),
      sourceLang: detected,
      toLang: toLang,
      engine: TranslateEngine.google,
    );
  }

  // ── 微软 ─────────────────────────────────────────────────────────────

  /// Edge 浏览器内置翻译用的端点。
  ///
  /// 比 `cn.bing.com/ttranslatev3` 干净得多：那边要先抓一次首页、正则挖
  /// `IG` / `data-iid` / `params_AbusePreventionHelper`，票据还有寿命；
  /// 这边什么都不用，POST 一个 JSON 数组就回译文。
  /// 协议参考 `plainheart/bing-translate-api` 的 `src/met/index.js`。
  Future<Translation> _bingTranslate(String text) async {
    final uri = Uri.parse(_bingEndpoint).replace(
      queryParameters: {'to': _bingLang(toLang), 'isEnterpriseClient': 'false'},
    );

    // 端点吃的是 JSON 数组，一次可以带多段；我们单条发。
    final body = await _postJson(uri, [text], _bingUa);
    final root = _decode(body);

    // 单条发出去，回来也是长度 1 的数组。
    final first = root is List && root.isNotEmpty ? root[0] : null;
    if (first is! Map) {
      throw const TranslationException(
        reason: TranslationFailure.network,
        detail: '响应形状不对',
      );
    }

    final list = first['translations'];
    final seg = list is List && list.isNotEmpty ? list[0] : null;
    if (seg is! Map || seg['text'] is! String) {
      throw const TranslationException(
        reason: TranslationFailure.network,
        detail: '没有译文',
      );
    }

    final detected = first['detectedLanguage'];
    final src = detected is Map && detected['language'] is String
        ? detected['language'] as String
        : 'auto';

    return Translation(
      text: (seg['text'] as String).trim(),
      sourceLang: src,
      toLang: toLang,
      engine: TranslateEngine.bing,
    );
  }

  /// 我们的语言码 → 微软的。微软认 `zh-Hans` / `zh-Hant`。
  static String _bingLang(String lang) => switch (lang) {
    'zh-TW' => 'zh-Hant',
    'zh-CN' => 'zh-Hans',
    _ => lang,
  };

  // ── Yandex ───────────────────────────────────────────────────────────

  Future<Translation> _yandex(String text) async {
    // Yandex 的 translate 不接受 auto，必须先问一次源语言。
    final src = await _yandexDetect(text);
    final lang = '$src-${_yandexLang(toLang)}';

    final uri = Uri.parse(_yandexEndpoint).replace(
      queryParameters: {
        'srv': 'browser_video_translation',
        'lang': lang,
        'text': text,
      },
    );

    final body = await _postForm(uri, {
      'maxRetryCount': '2',
      'fetchAbortTimeout': '500',
    }, _yandexUa);
    final root = _decode(body);

    if (root is! Map) {
      throw const TranslationException(
        reason: TranslationFailure.network,
        detail: '响应形状不对',
      );
    }
    final code = root['code'];
    if (code != 200) {
      throw TranslationException(
        reason: code == 429
            ? TranslationFailure.rateLimited
            : TranslationFailure.network,
        detail: 'code=$code ${root['message'] ?? ''}'.trim(),
      );
    }

    final list = root['text'];
    if (list is! List || list.isEmpty) {
      throw const TranslationException(
        reason: TranslationFailure.network,
        detail: '没有译文',
      );
    }

    return Translation(
      text: list.map((e) => '$e').join().trim(),
      sourceLang: src,
      toLang: toLang,
      engine: TranslateEngine.yandex,
    );
  }

  /// 问 Yandex 这段是什么语言。
  Future<String> _yandexDetect(String text) async {
    final uri = Uri.parse(_yandexDetectEndpoint).replace(
      queryParameters: {'srv': 'browser_video_translation', 'text': text},
    );
    final body = await _postForm(uri, {'maxRetryCount': '2'}, _yandexUa);
    final root = _decode(body);
    final lang = root is Map ? root['lang'] : null;
    if (lang is! String || lang.isEmpty) {
      throw const TranslationException(
        reason: TranslationFailure.network,
        detail: '检测不到源语言',
      );
    }
    return lang;
  }

  /// 我们的语言码 → Yandex 的。
  ///
  /// Yandex 的 v1 只有 `zh`，不分简繁——繁体用户拿到的仍是简体。
  static String _yandexLang(String lang) => switch (lang) {
    'zh-CN' || 'zh-TW' || 'zh-Hans' || 'zh-Hant' => 'zh',
    _ => lang,
  };

  // ── 传输层 ───────────────────────────────────────────────────────────

  /// 发 GET，返回 body 字符串。
  Future<String> _get(Uri uri, String ua) async {
    try {
      final req = await _http.getUrl(uri).timeout(_timeout);
      req.headers.set(HttpHeaders.userAgentHeader, ua);
      final res = await req.close().timeout(_timeout);
      return await _readBody(res);
    } on TranslationException {
      rethrow;
    } on Exception catch (e) {
      throw TranslationException(
        reason: TranslationFailure.network,
        detail: '$e',
      );
    }
  }

  /// 发 JSON POST，返回 body 字符串。
  Future<String> _postJson(Uri uri, List<String> payload, String ua) async {
    try {
      final req = await _http.postUrl(uri).timeout(_timeout);
      req.headers.set(HttpHeaders.userAgentHeader, ua);
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(payload));
      final res = await req.close().timeout(_timeout);
      return await _readBody(res);
    } on TranslationException {
      rethrow;
    } on Exception catch (e) {
      throw TranslationException(
        reason: TranslationFailure.network,
        detail: '$e',
      );
    }
  }

  /// 发 form POST，返回 body 字符串。
  Future<String> _postForm(
    Uri uri,
    Map<String, String> fields,
    String ua,
  ) async {
    try {
      final req = await _http.postUrl(uri).timeout(_timeout);
      req.headers.set(HttpHeaders.userAgentHeader, ua);
      req.headers.contentType = ContentType(
        'application',
        'x-www-form-urlencoded',
        charset: 'utf-8',
      );
      req.write(Uri(queryParameters: fields).query);
      final res = await req.close().timeout(_timeout);
      return await _readBody(res);
    } on TranslationException {
      rethrow;
    } on Exception catch (e) {
      throw TranslationException(
        reason: TranslationFailure.network,
        detail: '$e',
      );
    }
  }

  /// 读响应体，顺带把非 200 归类成异常。
  Future<String> _readBody(HttpClientResponse res) async {
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
    return res.transform(utf8.decoder).join();
  }

  /// 解 JSON，失败归为网络错误（多半是拿到了 HTML 错误页）。
  ///
  /// 返回 `Object?` 而不是 `dynamic`：`dynamic` 会让调用处的
  /// `first is! Map` 之类的判断变成非 bool 条件，analyzer 会报
  /// `non_bool_condition`，而且真的写错时也没人拦。
  static Object? _decode(String body) {
    try {
      return jsonDecode(body);
    } on Object catch (e) {
      throw TranslationException(
        reason: TranslationFailure.network,
        detail: '响应不是 JSON：$e',
      );
    }
  }

  /// 把拼接出来的译文收尾，空的就当失败。
  static String _ensureText(StringBuffer buf) {
    final out = buf.toString().trim();
    if (out.isEmpty) {
      throw const TranslationException(
        reason: TranslationFailure.network,
        detail: '译文为空',
      );
    }
    return out;
  }

  /// 关掉连接池。
  void dispose() => _http.close(force: true);

  /// 单个请求的超时。
  ///
  /// 8 秒而不是 12：谷歌在不通的网络里每次都要吃满这个值，
  /// 配合「失败一次就沉底」，只有第一条会等这么久。
  static const _timeout = Duration(seconds: 8);

  static const _googleEndpoint =
      'https://translate.googleapis.com/translate_a/single';

  /// 微软 Edge 浏览器内置翻译的端点。协议参考
  /// `plainheart/bing-translate-api` 的 `src/met/index.js`。
  static const _bingEndpoint =
      'https://edge.microsoft.com/translate/translatetext';

  static const _yandexEndpoint =
      'https://browser.translate.yandex.net/api/v1/tr.json/translate';
  static const _yandexDetectEndpoint =
      'https://browser.translate.yandex.net/api/v1/tr.json/detect';

  static const _ua =
      'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';

  /// 微软端点认 Edge 的 UA。
  static const _bingUa =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/153.0.0.0 Safari/537.36 Edg/153.0.0.0';

  /// Yandex 的 browser 端点只认 YaBrowser 的 UA。
  static const _yandexUa =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 '
      'YaBrowser/24.1.5.825 Yowser/2.5 Safari/537.36';
}
