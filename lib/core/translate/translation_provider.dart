/// 把 [Translator] 包成一个可缓存的 provider。
///
/// 缓存的是「进行中的请求」，不是结果：ListView 滚动会反复 build 同一张卡片，
/// 每次都新建 Future 就会重复发请求。把 Future 本身握在手里，
/// 同一条消息整场会话最多只请求一次，无论被 build 多少次。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fus_inbox/core/prefs/prefs_provider.dart';
import 'package:fus_inbox/core/translate/translator.dart';

/// 翻译服务实例。整个 App 复用一个，连接池也复用。
///
/// 目标语言来自设置：语言一变就重建实例（旧的连接池 dispose），
/// 这样请求本身就带着新的 tl 参数，不需要在调用处到处传。
final translatorProvider = Provider<Translator>((ref) {
  final toLang = ref.watch(prefsProvider.select((p) => p.targetLang));
  final engine = ref.watch(prefsProvider.select((p) => p.engine));
  final t = Translator(toLang: toLang, preferred: engine);
  ref.onDispose(t.dispose);
  return t;
});

/// 一条消息的翻译状态。
class const TranslationEntry({
  required this.text,
  this.loading = true,
  this.failed = false,
}) {
  /// 译文；加载中或失败时为空串。
  final String text;

  /// 是否还在请求中。
  final bool loading;

  /// 是否失败（网络 / 限流）。失败的条目不重试，显示原文即可。
  final bool failed;

  /// 是否需要把原文也显示出来。
  ///
  /// 三种情况要显示原文：还没翻完、翻失败、译文为空。
  /// 这个判断放在这里而不是 UI 里，是为了让卡片渲染逻辑保持简单。
  bool get needsFallback => loading || failed || text.isEmpty;
}

/// 按原文缓存翻译状态的仓库。
///
/// 键永远是消息原文本身。Dart 的 map 字面量里，裸标识符按**变量**求值：
/// `{...state, key: v}` 的键是变量 key 的值；写 `'key': v` 才是字符串。
/// 两者只差一对引号，踩过就得记着。
class TranslationStore() extends Notifier<Map<String, TranslationEntry>> {
  /// 进行中的请求，键同 [state]。
  final Map<String, Future<void>> _inflight = {};

  /// 代际。清空缓存或切换目标语言时 +1。
  ///
  /// 只清 `_inflight` 是不够的：真正的网络请求还在跑，回来以后照样会
  /// `_put` 把旧结果写回新状态——用户点了「清除缓存」，几秒后译文又冒出来。
  /// 请求发起时记下代际，落盘时对不上就丢弃。
  int _gen = 0;

  @override
  Map<String, TranslationEntry> build() {
    // 目标语言一变，之前所有译文都作废。监听并清空，
    // 否则用户切到繁体后会一直看到旧的简体结果。
    ref.watch(prefsProvider.select((p) => p.targetLang));
    // 语言变了：旧的 in-flight 结果全部作废。
    _gen++;
    _inflight.clear();
    return const {};
  }

  /// 请求翻译。同一个 [text] 重复调用不会再发请求。
  ///
  /// 无需翻译的内容（纯数字、已是中文）直接标记为完成且译文为空，
  /// 调用方据 [TranslationEntry.needsFallback] 显示原文。
  void request(String text) {
    final key = text.trim();
    if (key.isEmpty) return;
    if (state.containsKey(key) || _inflight.containsKey(key)) return;

    if (!Translator.needsTranslation(key)) {
      _put(key, const TranslationEntry(text: '', loading: false));
      return;
    }

    // 先落一个「加载中」，卡片立刻能画出来，不用等网络。
    _put(key, const TranslationEntry(text: ''));

    final gen = _gen;
    late final Future<void> f;
    f = _run(key, gen).whenComplete(() => _inflight.remove(key));
    _inflight[key] = f;
    unawaited(f);
  }

  /// 清空所有缓存。
  ///
  /// 设置页的「清除翻译缓存」用。连进行中的请求一起丢掉——
  /// 用户按了清除，就不该有旧请求悄悄把结果写回来。
  void clear() {
    _gen++;
    _inflight.clear();
    state = const {};
  }

  /// 写入一个条目。
  ///
  /// `{...state, key: entry}` 里的 `key` 是变量，Dart 取的是**变量值**作键
  /// （实测：变量 `k='hello'` 时 `{k: 1}` 产生键 `hello`，不是字符串 `key`）。
  /// 危险的是把变量名写成字符串字面量，例如 `'key': entry`。
  void _put(String key, TranslationEntry entry) {
    state = {...state, key: entry};
  }

  Future<void> _run(String key, int gen) async {
    try {
      final r = await ref.read(translatorProvider).translate(key);
      if (gen != _gen) return;
      _put(key, TranslationEntry(text: r.text, loading: false));
    } on TranslationException catch (e) {
      // 限流或网络挂了都不重试：界面上反复重试只会把限流拖得更久。
      // 用户下次进来是新的一次会话，那时自然会重新请求。
      debugPrint('翻译失败（${e.reason}）：${e.detail}');
      if (gen != _gen) return;
      _put(key, const TranslationEntry(text: '', loading: false, failed: true));
    } on Object catch (e) {
      debugPrint('翻译异常：$e');
      if (gen != _gen) return;
      _put(key, const TranslationEntry(text: '', loading: false, failed: true));
    }
  }
}

final translationStoreProvider =
    NotifierProvider<TranslationStore, Map<String, TranslationEntry>>(
      TranslationStore.new,
    );
