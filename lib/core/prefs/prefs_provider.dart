/// 用户偏好。
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
const _kFontScale = 'pref_font_scale';
const _kLocale = 'pref_locale';
const _kTargetLang = 'pref_target_lang';

/// 界面偏好的不可变快照。
class const Prefs({
  this.translate = true,
  this.showOriginal = false,
  this.fontScale = 1.0,
  this.localeCode = '',
  this.targetLang = 'zh-CN',
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

  /// 正文字号倍数。
  ///
  /// 0.85 ~ 1.4，1.0 是设计基准。短信正文密度高，
  /// 不同人对这个值的容忍度差别很大，交给用户调。
  final double fontScale;

  /// 界面语言。空串表示跟随系统。
  ///
  /// 目前 App 只有中文，这个开关留在这里是为了不把结构写死——
  /// 真要加英文时只改 strings 层，不用动设置页。
  final String localeCode;

  /// 译文目标语言。
  ///
  /// 和 [localeCode] 是两件事：localeCode 是界面语言（目前只有中文），
  /// targetLang 是把英文短信翻成哪种中文。
  final String targetLang;

  /// 是否已经从磁盘读完。界面用它决定要不要显示骨架。
  final bool restored;

  Prefs copyWith({
    bool? translate,
    bool? showOriginal,
    double? fontScale,
    String? localeCode,
    String? targetLang,
    bool? restored,
  }) => Prefs(
    translate: translate ?? this.translate,
    showOriginal: showOriginal ?? this.showOriginal,
    fontScale: fontScale ?? this.fontScale,
    localeCode: localeCode ?? this.localeCode,
    targetLang: targetLang ?? this.targetLang,
    restored: restored ?? this.restored,
  );
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
      final scale = p.getDouble(_kFontScale) ?? 1.0;
      state = Prefs(
        translate: p.getBool(_kTranslate) ?? true,
        showOriginal: p.getBool(_kShowOriginal) ?? false,
        // 夹一下：手改配置文件塞进离谱值时不要让界面炸掉。
        fontScale: scale.clamp(0.85, 1.4),
        localeCode: p.getString(_kLocale) ?? '',
        targetLang: p.getString(_kTargetLang) ?? 'zh-CN',
        restored: true,
      );
    } catch (_) {
      // 读不到就用默认值，不影响启动。
      state = const Prefs(restored: true);
    }
  }

  Future<void> setTranslate(bool v) async {
    state = state.copyWith(translate: v, restored: true);
    await _saveBool(_kTranslate, v);
  }

  Future<void> setShowOriginal(bool v) async {
    state = state.copyWith(showOriginal: v, restored: true);
    await _saveBool(_kShowOriginal, v);
  }

  Future<void> setFontScale(double v) async {
    final clamped = v.clamp(0.85, 1.4);
    state = state.copyWith(fontScale: clamped, restored: true);
    try {
      final p = await SharedPreferences.getInstance();
      await p.setDouble(_kFontScale, clamped);
    } catch (_) {}
  }

  Future<void> setLocale(String code) async {
    state = state.copyWith(localeCode: code, restored: true);
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_kLocale, code);
    } catch (_) {}
  }

  Future<void> setTargetLang(String code) async {
    state = state.copyWith(targetLang: code, restored: true);
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_kTargetLang, code);
    } catch (_) {}
  }

  Future<void> _saveBool(String key, bool v) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(key, v);
    } catch (_) {
      // 落盘失败不影响本次会话。
    }
  }
}

final prefsProvider = NotifierProvider<PrefsNotifier, Prefs>(PrefsNotifier.new);
