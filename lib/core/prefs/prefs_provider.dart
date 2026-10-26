/// 用户偏好：主题模式之外的几个开关。
///
/// 手写 [NotifierProvider] 而不是 `@Riverpod` 注解 —— 注释同 theme_provider：
/// 这点状态不值得为它引入 build_runner 整条生成链。
///
/// 所有字段都落 [SharedPreferences]，[build] 先返回默认值、再异步回填，
/// 所以界面第一帧不会因为读盘而空白。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _kTranslate = 'pref_translate';
const _kShowOriginal = 'pref_show_original';

/// 界面偏好的不可变快照。
class const Prefs({
  this.translate = true,
  this.showOriginal = false,
  this.restored = false,
}) {
  /// 是否实时翻译短信正文。
  ///
  /// 默认开：站点是英文的，验证码短信几乎都是英文模板，
  /// 不翻译的话每条都要自己读。
  final bool translate;

  /// 译文下面是否同时保留原文。
  ///
  /// 默认关：大部分时候只看译文就够；需要核对措辞时再打开。
  final bool showOriginal;

  /// 是否已经从磁盘读完。界面用它决定要不要显示骨架。
  final bool restored;
}

class PrefsNotifier() extends Notifier<Prefs> {
  @override
  Prefs build() {
    _restore();
    return const Prefs();
  }

  Future<void> _restore() async {
    try {
      final p = await SharedPreferences.getInstance();
      state = Prefs(
        translate: p.getBool(_kTranslate) ?? true,
        showOriginal: p.getBool(_kShowOriginal) ?? false,
        restored: true,
      );
    } catch (_) {
      // 读不到就用默认值，不影响启动。
      state = const Prefs(restored: true);
    }
  }

  Future<void> setTranslate(bool v) async {
    state = Prefs(
      translate: v,
      showOriginal: state.showOriginal,
      restored: true,
    );
    await _save(_kTranslate, v);
  }

  Future<void> setShowOriginal(bool v) async {
    state = Prefs(translate: state.translate, showOriginal: v, restored: true);
    await _save(_kShowOriginal, v);
  }

  Future<void> _save(String key, bool v) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(key, v);
    } catch (_) {
      // 落盘失败不影响本次会话。
    }
  }
}

final prefsProvider = NotifierProvider<PrefsNotifier, Prefs>(PrefsNotifier.new);
