/// 翻译的传输层：发请求、读正文、解 JSON。
///
/// ## 为什么单独一个文件
///
/// 这一层**没有引擎概念** —— 谁调用它都一样。以前它和三家引擎挤在
/// 一个类里，读那个文件要先跳过 200 行 HTTP 细节才看得到「微软那边
/// 怎么成形」。
///
/// ## 三件事必须留在这里，挪出去就会各写一遍
///
/// 1. **正文读取限时**。`Future.timeout()` 只给 Future 计时，**不中断
///    底层 socket** —— 站点回了 200 头之后慢慢滴正文，`join()` 会永远
///    挂着。
/// 2. **429 单独归类**。它是「换引擎也没用、等一下再说」，和「网络挂了」
///    是两种处置，不能都压成 network。
/// 3. **超时把连接掐掉**。只让 Future 抛异常而留着半开 socket，它会一直
///    占着池里的槽；站点每条短信都滴一次就把池耗光。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fus_inbox/core/translate/translation.dart';

/// 一次请求的超时。
///
/// 公开是因为调用方建 `HttpClient` 时要把 `connectionTimeout` 和
/// `idleTimeout` 也设成同一个值 —— 那两处管的是「建立连接」和「连接空闲」，
/// 和这里管「整个请求」的 Future 超时是三件事，漏一个就会在某条路径上挂住。
const translateTimeout = Duration(seconds: 8);

/// Google 的公开端点（网页版在用，不需要 key）。
const _googleEndpoint = 'https://translate.googleapis.com/translate_a/single';

/// 微软 Edge 浏览器内置翻译的端点。
///
/// 比 `cn.bing.com/ttranslatev3` 干净得多：那边要先抓一次首页、正则挖
/// `IG` / `data-iid` / `params_AbusePreventionHelper`，票据还有寿命；
/// 这边什么都不用，POST 一个 JSON 数组就回译文。国内可直连。
/// 协议参考 `plainheart/bing-translate-api` 的 `src/met/index.js`。
const _bingEndpoint = 'https://edge.microsoft.com/translate/translatetext';

const _yandexEndpoint =
    'https://browser.translate.yandex.net/api/v1/tr.json/translate';

/// Yandex 的语言探测端点。它的 translate 端点不吃 `auto`，
/// 源语言必须先问这里（见 `YandexBackend.detect`）。
const _yandexDetectEndpoint =
    'https://browser.translate.yandex.net/api/v1/tr.json/detect';

const _ua =
    'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';

/// 微软端点认 Edge 的 UA，谷歌端点不挑。
const _bingUa =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/153.0.0.0 Safari/537.36 Edg/153.0.0.0';

/// Yandex 的 browser 端点只认 YaBrowser 的 UA。
const _yandexUa =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/124.0.0.0 '
    'YaBrowser/24.1.5.825 Yowser/2.5 Safari/537.36';

/// 三家引擎的合集，供后端实现取用。
///
/// 做成一个类而不是散落的顶层常量：`const` 的顶层常量没问题，但这样
/// 一眼能看出「这些是同一批配置」。
///
/// 全静态常量的命名空间类。末尾 `()` 是主构造器的空标记（本仓统一写法）。
abstract final class TranslateEndpoints() {
  static const google = _googleEndpoint;
  static const bing = _bingEndpoint;
  static const yandex = _yandexEndpoint;
  static const yandexDetect = _yandexDetectEndpoint;
  static const defaultUa = _ua;
  static const bingUa = _bingUa;
  static const yandexUa = _yandexUa;
}

/// 一个复用的 HTTP 客户端 + 三类请求（GET / JSON POST / form POST）。
class TranslateTransport({HttpClient? client, Duration? timeout}) {
  /// 请求超时。构造参数给了就用它，没给用默认值。
  ///
  /// 主构造器的**参数在字段初始化器里可见**（所以这里能写 `timeout`），
  /// 但字段初始化器读不到别的**字段** —— 下面 `_http` 因此把
  /// `timeout ?? translateTimeout` 又写了一遍，而不是引用 `_timeout`。
  /// 这一小段重复换来的是：不需要构造函数体，也就不用 ignore
  /// `use_primary_constructors`。
  final Duration _timeout = timeout ?? translateTimeout;

  // 不能写 `late final`：惰性初始化器和普通方法一样读不到主构造器参数。
  final HttpClient _http =
      client ??
      (HttpClient()
        // `connectionTimeout` 管**建立**连接，`idleTimeout` 管连接建立
        // 之后闲置多久回收。正文读取那边还有显式超时（见 [_readBody]），
        // 但池里别的半开连接得靠这个收。
        ..connectionTimeout = timeout ?? translateTimeout
        ..idleTimeout = timeout ?? translateTimeout);

  /// 发 GET，返回 body。失败一律抛 [TranslationException]。
  Future<String> get(Uri uri, String ua) async {
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

  /// 发 JSON POST（body 是字符串数组），返回 body。
  /// 失败一律抛 [TranslationException]。
  Future<String> postJson(Uri uri, List<String> payload, String ua) async {
    return _send(() => _http.postUrl(uri), (req) {
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(payload));
    }, ua);
  }

  /// 发 form POST，返回 body。失败一律抛 [TranslationException]。
  Future<String> postForm(
    Uri uri,
    Map<String, String> fields,
    String ua,
  ) async {
    return _send(() => _http.postUrl(uri), (req) {
      req.headers.contentType = ContentType(
        'application',
        'x-www-form-urlencoded',
        charset: 'utf-8',
      );
      req.write(Uri(queryParameters: fields).query);
    }, ua);
  }

  /// GET 和两种 POST 的公共骨架：开请求 → 设 UA → 发 body → 读响应。
  ///
  /// 三段 try/catch 写三遍和写一遍没有区别，不同的只有「往请求里写什么」，
  /// 所以把它抽出来。失败一律包成 [TranslationException]。
  Future<String> _send(
    Future<HttpClientRequest> Function() open,
    void Function(HttpClientRequest) fill,
    String ua,
  ) async {
    try {
      final req = await open().timeout(_timeout);
      req.headers.set(HttpHeaders.userAgentHeader, ua);
      fill(req);
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
    try {
      return await res.transform(utf8.decoder).join().timeout(_timeout);
    } on TimeoutException {
      // 把这条连接掐掉 —— 只让 Future 抛异常而留着半开 socket，它会一直
      // 占着池里的一个槽。`detachSocket` 之后 `destroy` 是最干脆的收尾。
      unawaited(
        res
            .detachSocket()
            .then((socket) => socket.destroy())
            .catchError((Object _) {}),
      );
      throw const TranslationException(
        reason: TranslationFailure.network,
        detail: '读响应体超时',
      );
    }
  }

  /// 解 JSON，失败归为网络错误（多半是拿到了 HTML 错误页）。
  ///
  /// 返回 `Object?` 而不是 `dynamic`：`dynamic` 会让调用处的
  /// `first is! Map` 之类的判断失去编译期检查，写错也没人拦。
  static Object? decode(String body) {
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
  static String ensureText(StringBuffer buf) {
    final out = buf.toString().trim();
    if (out.isEmpty) {
      throw const TranslationException(
        reason: TranslationFailure.network,
        detail: '译文为空',
      );
    }
    return out;
  }

  /// 关闭底层连接池。和 [Translator.dispose] 成对。
  void dispose() => _http.close(force: true);
}
