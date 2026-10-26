/// 把 [Translator] 包成一个可缓存的 provider。
///
/// 为什么缓存的是 `Future` 而不是结果：ListView 滚动时会反复 build 同一个
/// 卡片，`FutureBuilder` 每次拿到一个新的 Future 就会重新发请求。把 Future
/// 本身存下来，同一条消息在整场会话里最多只请求一次，无论它被 build 多少次。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fus_inbox/core/translate/translator.dart';

/// 翻译服务实例。整个 App 复用一个，连接池也复用。
final translatorProvider = Provider<Translator>((ref) {
  final t = Translator();
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
  final bool loading;
  final bool failed;
}

/// 按原文缓存翻译 Future 的仓库。
class TranslationStore() extends Notifier<Map<String, TranslationEntry>> {
  /// 进行中的请求。键是原文，值是 Future —— 同一个键只会有一个在飞。
  final Map<String, Future<void>> _inflight = {};

  @override
  Map<String, TranslationEntry> build() => const {};

  /// 请求翻译。重复调用同一个 [text] 不会再发请求。
  ///
  /// 无需翻译的内容（纯数字、已是中文）直接标记为完成且译文为空，
  /// 调用方据此显示原文即可。
  void request(String text) {
    final t = text.trim();
    if (t.isEmpty) return;
    if (state.containsKey(t) || _inflight.containsKey(t)) return;

    if (!Translator.needsTranslation(t)) {
      state = {...state, t: const TranslationEntry(text: '', loading: false)};
      return;
    }

    state = {...state, t: const TranslationEntry(text: '')};

    final f = _run(t);
    _inflight[t] = f;
    unawaited(f);
  }

  Future<void> _run(String text) async {
    try {
      final r = await ref.read(translatorProvider).translate(text);
      state = {...state, text: TranslationEntry(text: r.text, loading: false)};
    } on TranslationException catch (e) {
      // 被限流或网络挂了都不重试：用户下次进来还会重新请求，
      // 而在界面上反复重试只会把限流拖得更久。
      debugPrint('翻译失败：${e.reason}');
      state = {
        ...state,
        text: const TranslationEntry(text: '', loading: false, failed: true),
      };
    } on Object catch (e) {
      debugPrint('翻译异常：$e');
      state = {
        ...state,
        text: const TranslationEntry(text: '', loading: false, failed: true),
      };
    } finally {
      _inflight.remove(text);
    }
  }
}

final translationStoreProvider =
    NotifierProvider<TranslationStore, Map<String, TranslationEntry>>(
      TranslationStore.new,
    );
