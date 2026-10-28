/// 短信正文翻译。
///
/// 值类型见 `translation.dart`（在这里转出去，引用方不用多写一行 import）；
/// 传输层见 `transport.dart`；三家引擎见 `backends.dart`。
///
/// 这个文件只做**调度**：缓存、串行化、降级顺序、失败计数。
///
/// ## 为什么要翻
///
/// 站点是英文的，验证码短信也是英文（"Your verification code is..."）。
/// 用户要的是「一眼看懂」，所以正文在卡片里给中文译文，原文仍可展开查看。
///
/// ## 为什么是三家轮着上
///
/// 它们全是各家网页端在用的公开端点，不需要 key，也就**全都没有 SLA**。
/// 单靠一家意味着那家一挂就彻底没译文，所以降级链是必需品而不是锦上添花：
///
/// - **微软**（默认首选）不需要 token / cookie / 先抓页面，
///   POST 一个 JSON 数组就回译文；国内可直连。
/// - **谷歌**最准，但国内网络经常连不通。
/// - **Yandex** 最轻量，代价是 `lang` 必须显式给源语言，得先调一次 detect。
library;

import 'dart:async';
import 'dart:io';

import 'package:fus_inbox/core/translate/backends.dart';
import 'package:fus_inbox/core/translate/translation.dart';
import 'package:fus_inbox/core/translate/transport.dart';
export 'package:fus_inbox/core/translate/translation.dart';

/// 多引擎翻译客户端。
///
/// 设计要点：
/// - 同一个 [Translator] 复用一个 [HttpClient]（在 [TranslateTransport] 里），
///   避免每条消息新建连接。
/// - 内存缓存按「原文 -> 译文」存。短信用语高度重复（同一家服务的验证码
///   文案一模一样），缓存命中率很高，能省掉绝大部分请求。
/// - 并发请求串行化：公开端点对突发并发很敏感，逐条翻更稳。
/// - [preferred] 排在最前，其余按 [engineOrder] 依次补位；
///   任一引擎成功就停，全部失败才抛异常。
class Translator {
  // 带构造体语句（要建 transport 和三家的候选表），主构造器表达不了。
  // ignore: use_primary_constructors
  Translator({this.client, this.toLang = 'zh-CN', this.preferred}) {
    _transport = TranslateTransport(client: client);
    _backends = {
      TranslateEngine.google: GoogleBackend(_transport),
      TranslateEngine.bing: BingBackend(_transport),
      TranslateEngine.yandex: YandexBackend(_transport),
    };
  }

  /// 可注入的 HTTP 客户端；为空时自建一个，由本实例负责关闭。
  final HttpClient? client;

  /// 目标语言。默认简体中文。
  final String toLang;

  /// 优先尝试的引擎；为空时用微软。
  final TranslateEngine? preferred;

  late final TranslateTransport _transport;
  late final Map<TranslateEngine, TranslateBackend> _backends;

  /// 原文到译文的缓存。上限 [maxCache]，满了清空 —— 短信场景里
  /// 老文案复用价值低，不值得做 LRU。
  final Map<String, Translation> _cache = {};

  /// 每个引擎连续失败的次数。用来在本次会话里把坏引擎排到后面，
  /// 避免每条短信都先等谷歌超时。
  final Map<TranslateEngine, int> _fails = {};

  /// 上次成功的引擎。它排在最前，省掉重试坏引擎的时间。
  TranslateEngine? _lastGood;

  /// 连续失败几次就降到末位。
  ///
  /// 设 1 而不是 2：谷歌在不通的网络里每次都要吃满超时，
  /// 试第二次纯粹是浪费用户几秒。失败一次就沉底，成功一次就复位。
  static const _demoteAfter = 1;

  /// 缓存上限。
  static const maxCache = 300;

  /// 串行化用：上一条翻完再发下一条。
  Future<void> _queue = Future<void>.value();

  static final _cjk = RegExp(r'[\u4e00-\u9fff]');
  static final _latin = RegExp(r'[A-Za-z]');

  /// 判断这段文本是否值得翻译。
  ///
  /// 纯数字、纯符号、以及已经是中文的内容直接跳过 —— 把它们发给服务端
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

  /// 本次会话里各引擎的实际尝试顺序。见 [orderEngines] 的规则。
  List<TranslateEngine> get engineOrder => orderEngines(
    preferred: preferred,
    lastGood: _lastGood,
    fails: _fails,
    demoteAfter: _demoteAfter,
  );

  /// [engineOrder] 的纯逻辑本体。
  ///
  /// 抽成静态纯函数是为了能真测：[engineOrder] 依赖实例里的私有状态，
  /// 测试没法把「某引擎已经失败过一次」注入进去。
  ///
  /// 规则：
  /// 1. 上次成功的引擎排最前 —— 它已被证明在这台设备上能用。
  /// 2. 首选其次，用户的选择仍然受尊重。
  /// 3. 失败次数达到 [demoteAfter] 的，沉到末尾。
  ///
  /// 光靠「首选在前」不够：谷歌不通时每条短信都要先吃满超时再降级，
  /// 用户看到的是每张卡片都卡几秒。让成功过的引擎记住位置才真的快。
  static List<TranslateEngine> orderEngines({
    required TranslateEngine? preferred,
    required TranslateEngine? lastGood,
    required Map<TranslateEngine, int> fails,
    required int demoteAfter,
  }) {
    final head = preferred ?? TranslateEngine.bing;
    // base 必须无重复，两个来源都要排：lastGood 可能是 head 本身，
    // 也可能在 values 里再出现一次。以前只靠 healthy 的 contains 去重，
    // sick 分支漏了，于是首选失败时会多吐一个重复项。
    final base = <TranslateEngine>[
      if (lastGood != null && lastGood != head) lastGood,
      head,
      for (final e in TranslateEngine.values)
        if (e != head && e != lastGood) e,
    ];
    // base 已保证无重复，这里只是稳定分区，不需要 contains。
    final healthy = <TranslateEngine>[];
    final sick = <TranslateEngine>[];
    for (final e in base) {
      ((fails[e] ?? 0) >= demoteAfter ? sick : healthy).add(e);
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
  /// 注意「无需翻译」不是失败：它直接抛出，不触发降级 ——
  /// 换三家引擎翻同一条纯数字没有意义。
  Future<Translation> _request(String text) async {
    TranslationFailure? lastReason;
    String? lastDetail;
    var tried = 0;

    for (final engine in engineOrder) {
      try {
        final r = await _backends[engine]!.translate(text, toLang: toLang);
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

  void dispose() => _transport.dispose();
}
