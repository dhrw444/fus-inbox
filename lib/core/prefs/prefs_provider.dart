/// 用户偏好。
///
/// 手写 [NotifierProvider] 而不是 `@Riverpod` 注解 —— 注释同 theme_provider：
/// 这点状态不值得为它引入 build_runner 整条生成链。
///
/// 所有字段都落 [SharedPreferences]，[build] 先返回默认值、再异步回填，
/// 所以界面第一帧不会因为读盘而空白。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fus_inbox/core/prefs/storage_keys.dart';
import 'package:fus_inbox/core/translate/translator.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 界面偏好的不可变快照。
class const Prefs({
  this.translate = true,
  this.showOriginal = false,
  this.fontScale = 1.0,
  this.targetLang = 'zh-CN',
  this.engine = TranslateEngine.bing,
  this.directoryViaProxy = false,
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

  /// 号码目录是否走代理。
  ///
  /// ## 默认关（走真实 IP）
  ///
  /// 代理的价值在于绕过站点对**开号**的每 IP 额度（账本一条代理 3 个号）。
  /// 目录页是公开列表，不消耗额度，所以：
  ///
  /// 1. 拿目录请求去占用一条代理是浪费；
  /// 2. 目录一次抓 5 页、并发 3 条，跑在免费 SOCKS5 上容易先把它打废，
  ///    等真要开号时反而不能用了；
  /// 3. 目录是 App 入口，依赖代理意味着没配代理就打不开 App。
  ///
  /// ## 打开后
  ///
  /// 目录与收件页共用当前那条出口（同一条本地桥）。此时出口必须先
  /// 就绪，否则**请求失败**而不是退回直连 —— 见
  /// `NumbersRepository._findProxy` 与 `NumberDirectoryNotifier._ensureEgress`。
  ///
  /// 注意：`dart:io` 的 `HttpClient` 不经过 WebView 的 `ProxyController`，
  /// 这条链路要自己挂 `findProxy`。不挂就是直连，而且是**静默**的。
  final bool directoryViaProxy;

  /// 是否已经从磁盘读完。界面用它决定要不要显示骨架。
  final bool restored;

  Prefs copyWith({
    bool? translate,
    bool? showOriginal,
    double? fontScale,
    String? targetLang,
    TranslateEngine? engine,
    bool? directoryViaProxy,
    bool? restored,
  }) => Prefs(
    translate: translate ?? this.translate,
    showOriginal: showOriginal ?? this.showOriginal,
    fontScale: fontScale ?? this.fontScale,
    targetLang: targetLang ?? this.targetLang,
    engine: engine ?? this.engine,
    directoryViaProxy: directoryViaProxy ?? this.directoryViaProxy,
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
      final scale = kPrefFontScaleKey.readDouble(p) ?? 1.0;
      state = Prefs(
        translate: kPrefTranslateKey.readBool(p) ?? true,
        showOriginal: kPrefShowOriginalKey.readBool(p) ?? false,
        // 夹一下：手改配置文件塞进离谱值时不要让界面炸掉。
        fontScale: scale.clamp(0.85, 1.4),
        targetLang: kPrefTargetLangKey.readString(p) ?? 'zh-CN',
        engine: TranslateEngine.fromName(kPrefTranslateEngineKey.readString(p)),
        directoryViaProxy: kPrefDirectoryViaProxyKey.readBool(p) ?? false,
        restored: true,
      );
    } catch (_) {
      // 读不到就用默认值，不影响启动。
      state = const Prefs(restored: true);
    }
  }

  Future<void> setTranslate(bool v) async {
    state = state.copyWith(translate: v, restored: true);
    await _saveBool(kPrefTranslateKey, v);
  }

  Future<void> setShowOriginal(bool v) async {
    state = state.copyWith(showOriginal: v, restored: true);
    await _saveBool(kPrefShowOriginalKey, v);
  }

  /// 号码目录走不走代理。
  ///
  /// 改这个开关**不影响**已经打开的收件页：那边的出口由账本按号决定，
  /// 这里只管目录这一条链路。
  Future<void> setDirectoryViaProxy(bool v) async {
    state = state.copyWith(directoryViaProxy: v, restored: true);
    await _saveBool(kPrefDirectoryViaProxyKey, v);
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
    await _persist((p) => kPrefFontScaleKey.writeDouble(p, clamped));
  }

  Future<void> setTargetLang(String code) async {
    state = state.copyWith(targetLang: code, restored: true);
    await _persist((p) => kPrefTargetLangKey.writeString(p, code));
  }

  /// 换优先引擎。
  ///
  /// 会连带清空翻译缓存（见 [TranslationStore.build]）。曾经写成「不动缓存」，
  /// 但失败过的条目不重试，用户换引擎几乎总是因为当前这家不通——
  /// 不清就是他换完什么都没变，看着像坏了。已翻好的译文一并重来，
  /// 换的是「换完立刻按新引擎重翻」这个可预期的行为。
  ///
  /// 存档里存的是枚举名。存档里出现未知名字（降级、手改配置）时
  /// [TranslateEngine.fromName] 回落到默认，不让界面崩。
  Future<void> setEngine(TranslateEngine e) async {
    state = state.copyWith(engine: e, restored: true);
    await _persist((p) => kPrefTranslateEngineKey.writeString(p, e.name));
  }

  /// 写盘。**失败不回滚内存状态**。
  ///
  /// 用户改的这一下已经生效了，回滚会让他看到选项自己弹回去 —— 那比
  /// 丢一次落盘糟得多。下次写成功时自然补上。
  ///
  /// 所有 setter 共用这一处：以前 `setFontScale` / `setTargetLang` /
  /// `setEngine` / `_saveBool` 各写一遍同样的 try-catch + 同一段注释。
  Future<void> _persist(
    Future<void> Function(SharedPreferences p) write,
  ) async {
    try {
      await write(await SharedPreferences.getInstance());
    } catch (_) {
      // 理由见上。
    }
  }

  Future<void> _saveBool(StorageKey key, bool v) =>
      _persist((p) => key.writeBool(p, v));
}

final prefsProvider = NotifierProvider<PrefsNotifier, Prefs>(PrefsNotifier.new);
