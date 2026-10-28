/// 翻译的值类型与失败分类。
///
/// 从 `translator.dart` 拆出来的：这几个「只有字段的类」没有任何依赖，
/// 单独放一个文件，传输层（`transport.dart`）、三家引擎（`backends.dart`）和
/// 调度器（`translator.dart`）都能直接引用，纯逻辑测试也不用拖上 HTTP 代码。
library;

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
  /// 为什么失败。
  final TranslationFailure reason;

  /// 给日志看的细节；用户界面按 [reason] 分类显示，不直接展示它。
  final String detail;

  @override
  String toString() => 'TranslationException($reason): $detail';
}
