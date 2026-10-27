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

import 'package:fus_inbox/core/translate/translator.dart';

const _kTranslate = 'pref_translate';
const _kShowOriginal = 'pref_show_original';
const _kFontScale = 'pref_font_scale';
const _kTargetLang = 'pref_target_lang';
const _kEngine = 'pref_translate_engine';

/// 界面偏好的不可变快照。
class const Prefs({
  this.translate = true,
  this.showOriginal = false,
  this.fontScale = 1.0,
  this.targetLang = 'zh-CN',
  this.engine = TranslateEngine.bing,
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

  /// 译文目标语言：zh-CN（简体）或 zh-TW（繁体）。
  ///
  /// 注意别和「界面语言」混为一谈——界面只有中文，这个只决定
  /// 英文短信翻成哪种中文。
  final String targetLang;

  /// 优先使用的翻译引擎。
  ///
  /// 只是「首选」：它挂了会自动换下一家，所以选谷歌但网络不通时
  /// 仍然能翻出中文，只是慢一点。
  ///
  /// 默认微软：谷歌在国内网络基本连不通，而首选不通时第一条短信
  /// 要白等满 8 秒超时。微软的 Edge 端点在实测里 300ms 内必回。
  final TranslateEngine engine;

  /// 是否已经从磁盘读完。界面用它决定要不要显示骨架。
  final bool restored;

  Prefs copyWith({
    bool? translate,
    bool? showOriginal,
    double? fontScale,
    String? targetLang,
    TranslateEngine? engine,
    bool? restored,
  }) => Prefs(
    translate: translate ?? this.translate,
    showOriginal: showOriginal ?? this.showOriginal,
    fontScale: fontScale ?? this.fontScale,
    targetLang: targetLang ?? this.targetLang,
    engine: engine ?? this.engine,
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
        targetLang: p.getString(_kTargetLang) ?? 'zh-CN',
        engine: TranslateEngine.fromName(p.getString(_kEngine)),
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

  /// 改字号。
  ///
  /// [persist] 为 false 时只更新内存、不写盘——滑块拖动过程中会连续
  /// 触发几十次回调，每次都落盘既浪费又会让 SharedPreferences 抖动。
  /// 拖动结束再用默认值（true）落一次。
  Future<void> setFontScale(double v, {bool persist = true}) async {
    final clamped = v.clamp(0.85, 1.4);
    state = state.copyWith(fontScale: clamped, restored: true);
    if (!persist) return;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setDouble(_kFontScale, clamped);
    } catch (_) {}
  }

  Future<void> setTargetLang(String code) async {
    state = state.copyWith(targetLang: code, restored: true);
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_kTargetLang, code);
    } catch (_) {}
  }

  /// 换优先引擎。
  ///
  /// 只改偏好、不动缓存：已翻好的译文仍然有效，
  /// 换引擎只影响之后的新短信。
  Future<void> setEngine(TranslateEngine e) async {
    state = state.copyWith(engine: e, restored: true);
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_kEngine, e.name);
    } catch (_) {}
  }

  /// 存档里存的是枚举名。存档里出现未知名字（降级、手改配置）时
  /// 回落到默认，不让界面崩。

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
