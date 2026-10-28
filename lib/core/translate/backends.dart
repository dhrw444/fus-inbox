/// 三家翻译引擎。一家一个类，都实现 [TranslateBackend]。
///
/// ## 为什么是一家一个类，而不是一个类里三个方法
///
/// 三家的差别不只是端点：**请求怎么成形**和**响应长什么样**完全不同 ——
/// 谷歌回嵌套数组、微软回 `[{translations:[{text}]}]`、Yandex 要先用
/// 另一个端点问源语言。挤在一个类里时，这三种形状的分支互相穿插，
/// 加第四家就得在一个已经很长的 `switch` 里再插一段。
///
/// 拆开之后加一家 = 写一个类 + 在 `Translator` 的候选表里加一项。
///
/// ## 共同点只有一条
///
/// 全都**没有 SLA**，所以整条链路必须可降级：任何一家抛
/// [TranslationException] 都只是「这家不行」，上层换下一家。
library;

import 'package:fus_inbox/core/translate/translation.dart';
import 'package:fus_inbox/core/translate/transport.dart';

/// 一家翻译引擎。
abstract class const TranslateBackend(this.transport) {
  final TranslateTransport transport;

  /// 这家是谁。用于把结果标回来源（界面显示「上次用的谁」）。
  TranslateEngine get engine;

  /// 翻一段。失败抛 [TranslationException]，上层据此换下一家。
  Future<Translation> translate(String text, {required String toLang});
}

/// 谷歌。
///
/// 三家里最准，但**国内网络经常连不通** —— 所以它不可能是唯一候选，
/// 降级链必须存在。
class const GoogleBackend(super.transport) extends TranslateBackend {
  @override
  TranslateEngine get engine => TranslateEngine.google;

  @override
  Future<Translation> translate(String text, {required String toLang}) async {
    final uri = Uri.parse(TranslateEndpoints.google).replace(
      queryParameters: {
        'client': 'gtx',
        'sl': 'auto',
        'tl': toLang,
        'dt': 't',
        'q': text,
      },
    );

    final body = await transport.get(uri, TranslateEndpoints.defaultUa);
    final decoded = TranslateTransport.decode(body);
    // 谷歌回的是 `[[["译文","原文",...],...],"en",...]`。
    // 先收窄成 List，后面的下标访问才不会被 analyzer 判成可能为 null。
    if (decoded is! List || decoded.isEmpty) {
      throw const TranslationException(
        reason: TranslationFailure.network,
        detail: '响应不是非空数组',
      );
    }

    final buf = StringBuffer();
    final segs = decoded[0];
    if (segs is List) {
      for (final s in segs) {
        if (s is List && s.isNotEmpty && s[0] is String) {
          buf.write(s[0] as String);
        }
      }
    }

    final detected = decoded.length > 2 && decoded[2] is String
        ? decoded[2] as String
        : 'auto';

    return Translation(
      text: TranslateTransport.ensureText(buf),
      sourceLang: detected,
      toLang: toLang,
      engine: engine,
    );
  }
}

/// 微软（Edge 内置翻译的端点）。**默认首选**。
///
/// 选它当首选不是因为最准，是因为最稳：不需要 token、不需要 cookie、
/// 不需要先抓页面，POST 一个 JSON 数组就回译文，还能自动识别源语言。
/// 国内可直连 —— 而首选不通时第一条短信要白等满 8 秒超时。
class const BingBackend(super.transport) extends TranslateBackend {
  @override
  TranslateEngine get engine => TranslateEngine.bing;

  /// 我们的语言码 → 微软的。微软认 `zh-Hans` / `zh-Hant`。
  static String langFor(String lang) => switch (lang) {
    'zh-TW' => 'zh-Hant',
    'zh-CN' => 'zh-Hans',
    _ => lang,
  };

  @override
  Future<Translation> translate(String text, {required String toLang}) async {
    final uri = Uri.parse(TranslateEndpoints.bing).replace(
      queryParameters: {'to': langFor(toLang), 'isEnterpriseClient': 'false'},
    );

    // 端点吃的是 JSON 数组，一次可以带多段；我们单条发。
    final body = await transport.postJson(uri, [
      text,
    ], TranslateEndpoints.bingUa);
    final root = TranslateTransport.decode(body);

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
      engine: engine,
    );
  }
}

/// Yandex。降级链末位。
class const YandexBackend(super.transport) extends TranslateBackend {
  @override
  TranslateEngine get engine => TranslateEngine.yandex;

  /// 我们的语言码 → Yandex 的。
  ///
  /// **已知取舍，写在这里免得下次被当成 bug 改**：Yandex 的 v1 只有 `zh`，
  /// 不分简繁 —— 用户选「繁體」而前两家都不通、降级到 Yandex 时，拿到的是
  /// 简体译文，和设置不符。
  ///
  /// 没有把它从候选里排除，是因为排掉的代价更大：国内谷歌基本连不通，
  /// 排掉 Yandex 之后 zh-TW 就只剩微软一家，微软挂一次就完全不出译文
  /// （界面回落到显示英文原文）。「繁体用户拿到简体」比「什么都没有」
  /// 更接近他的目的。真要排除，就在 `Translator` 的候选表里按 toLang 过滤。
  static String langFor(String lang) => switch (lang) {
    'zh-CN' || 'zh-TW' || 'zh-Hans' || 'zh-Hant' => 'zh',
    _ => lang,
  };

  /// Yandex browser 端点要带的客户端标识，detect 和 translate 一致。
  static const _srv = 'browser_video_translation';

  /// 两个 form POST 都带的公共字段。
  static const _retryFields = {'maxRetryCount': '2'};

  /// 问 Yandex 这段是什么语言。
  ///
  /// 它的 translate 端点不接受 `auto`，所以这一步是**必需的**，
  /// 不是优化 —— 少了它会直接被拒。
  Future<String> detect(String text) async {
    final uri = Uri.parse(TranslateEndpoints.yandexDetect)
        .replace(queryParameters: {'srv': _srv, 'text': text});
    final body = await transport.postForm(
      uri,
      _retryFields,
      TranslateEndpoints.yandexUa,
    );
    final root = TranslateTransport.decode(body);
    final lang = root is Map ? root['lang'] : null;
    if (lang is! String || lang.isEmpty) {
      throw const TranslationException(
        reason: TranslationFailure.network,
        detail: '检测不到源语言',
      );
    }
    return lang;
  }

  @override
  Future<Translation> translate(String text, {required String toLang}) async {
    final src = await detect(text);
    final lang = '$src-${langFor(toLang)}';

    final uri = Uri.parse(TranslateEndpoints.yandex)
        .replace(queryParameters: {'srv': _srv, 'lang': lang, 'text': text});

    final body = await transport.postForm(uri, {
      ..._retryFields,
      'fetchAbortTimeout': '500',
    }, TranslateEndpoints.yandexUa);
    final root = TranslateTransport.decode(body);

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
      engine: engine,
    );
  }
}
