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
  final t = Translator(toLang: toLang);
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
/// 键永远是消息原文本身。注意不要把局部变量名直接当 map 字面量的键写——
/// `{...state, text: v}` 在 Dart 里是「键为字符串 'text'」，
/// 不是「键为变量 text 的值」，两者差一个字符就会静默写错位置。
class TranslationStore() extends Notifier<Map<String, TranslationEntry>> {
  /// 进行中的请求，键同 [state]。
  final Map<String, Future<void>> _inflight = {};

  @override
  Map<String, TranslationEntry> build() {
    // 目标语言一变，之前所有译文都作废。监听并清空，
    // 否则用户切到繁体后会一直看到旧的简体结果。
    ref.watch(prefsProvider.select((p) => p.targetLang));
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

    late final Future<void> f;
    f = _run(key).whenComplete(() => _inflight.remove(key));
    _inflight[key] = f;
    unawaited(f);
  }

  /// 清空所有缓存。
  ///
  /// 设置页的「清除翻译缓存」用。连进行中的请求一起丢掉——
  /// 用户按了清除，就不该有旧请求悄悄把结果写回来。
  void clear() {
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

  Future<void> _run(String key) async {
    try {
      final r = await ref.read(translatorProvider).translate(key);
      _put(key, TranslationEntry(text: r.text, loading: false));
    } on TranslationException catch (e) {
      // 限流或网络挂了都不重试：界面上反复重试只会把限流拖得更久。
      // 用户下次进来是新的一次会话，那时自然会重新请求。
      debugPrint('翻译失败（${e.reason}）：${e.detail}');
      _put(key, const TranslationEntry(text: '', loading: false, failed: true));
    } on Object catch (e) {
      debugPrint('翻译异常：$e');
      _put(key, const TranslationEntry(text: '', loading: false, failed: true));
    }
  }
}

final translationStoreProvider =
    NotifierProvider<TranslationStore, Map<String, TranslationEntry>>(
      TranslationStore.new,
    );
