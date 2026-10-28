/// 全项目 SharedPreferences 键的**唯一**定义处。
///
/// ## 为什么要收在一个文件里
///
/// 之前这些键散在六个文件里，而且用了**五套互不相同的命名风格**：
///
/// | 风格 | 例子 | 出现在 |
/// |---|---|---|
/// | `fus:<区>:<名>:v1` | `fus:proxy:pool:v1` | proxy_store / native_capabilities |
/// | `<区>_<名>_v1` | `fus_saved_numbers_v1` | saved_provider |
/// | `<区>.<名>.v1` | `proxy.builtin.excluded.v1` | builtin_proxies |
/// | `pref_<名>` | `pref_translate` | prefs_provider |
/// | 裸名字 | `theme_mode` | theme_provider |
///
/// 后果不是「难看」，是**真的会写错**：要清空某个功能的数据时，得先想起
/// 它当初用的是哪套命名；想不起就得全仓搜一遍。而且没有版本后缀的键
/// （`theme_mode`）改结构时无处可退。
///
/// ## 现在的约定
///
/// **`fus:<区>:<名>:v1`** —— 全小写、冒号分隔、`fus:` 前缀、`v1` 版本后缀。
/// 区是功能域（`proxy` / `identity` / `prefs` / `saved`），名用连字符。
///
/// 改数据结构时把 `v1` 提到 `v2`，旧键原地留着不管 —— 那是最省事的
/// 一次「清空重来」，不会读到半新半旧的形状。
///
/// ## legacy 是干什么的
///
/// 已经装过 App 的用户，磁盘上写的是旧键名。直接换新名字等于**静默清空**
/// 他的代理池、身份和设置。所以每个改过名的键都带一个 [StorageKey.legacy]：
/// 新键读不到时回落去读旧键，读到就直接用（下一次写盘会自动落到新键上）。
///
/// 没改过名的键（本来就是 `fus:` 风格那几个）`legacy` 是 null。
library;

import 'package:shared_preferences/shared_preferences.dart';

/// 一个存储键：新名字 + 可选的旧名字。
class const StorageKey(this.name, {this.legacy}) {
  /// 现在的键名。
  final String name;

  /// 改名前用的键名。null = 从来没改过名。
  ///
  /// **不要删它**，除非确认所有用户的机器上都写过至少一次新键
  /// （那要等一个版本之后）。
  final String? legacy;

  // ── 读：新键优先，读不到落旧键 ────────────────────────────────

  String? readString(SharedPreferences p) {
    final v = p.getString(name);
    if (v != null) return v;
    final old = legacy;
    return old == null ? null : p.getString(old);
  }

  bool? readBool(SharedPreferences p) {
    final v = p.getBool(name);
    if (v != null) return v;
    final old = legacy;
    return old == null ? null : p.getBool(old);
  }

  double? readDouble(SharedPreferences p) {
    final v = p.getDouble(name);
    if (v != null) return v;
    final old = legacy;
    return old == null ? null : p.getDouble(old);
  }

  int? readInt(SharedPreferences p) {
    final v = p.getInt(name);
    if (v != null) return v;
    final old = legacy;
    return old == null ? null : p.getInt(old);
  }

  List<String>? readStringList(SharedPreferences p) {
    final v = p.getStringList(name);
    if (v != null) return v;
    final old = legacy;
    return old == null ? null : p.getStringList(old);
  }

  // ── 写：只写新键 ──────────────────────────────────────────────
  //
  // 写完不删旧键：删了的话，用户降级回旧版 App 就什么都没了。
  // 旧键那几个字节不值得为它冒这个险。

  Future<bool> writeString(SharedPreferences p, String v) =>
      p.setString(name, v);

  Future<bool> writeBool(SharedPreferences p, bool v) => p.setBool(name, v);

  Future<bool> writeDouble(SharedPreferences p, double v) =>
      p.setDouble(name, v);

  Future<bool> writeInt(SharedPreferences p, int v) => p.setInt(name, v);

  Future<bool> writeStringList(SharedPreferences p, List<String> v) =>
      p.setStringList(name, v);

  /// 删掉这个键。**新旧名字都删**。
  ///
  /// 只删新键的话，旧键还躺在磁盘上：一旦新键读不到（比如上面那个
  /// `readString` 的回落），被删的数据又回来了 —— 「清除缓存」按钮
  /// 看着生效、重启就复活。
  Future<void> remove(SharedPreferences p) async {
    await p.remove(name);
    final old = legacy;
    if (old != null) await p.remove(old);
  }
}

// ── 代理 ────────────────────────────────────────────────────────

/// 用户手动添加的代理清单（JSON 数组）。
const kProxyPoolKey = StorageKey('fus:proxy:pool:v1');

/// 当前选中的出口 id。
const kProxyCurrentKey = StorageKey('fus:proxy:current:v1');

/// 用满额度后自动换出口。
const kProxyAutoRotateKey = StorageKey('fus:proxy:auto:v1');

/// 被用户删掉的内置代理 id（排除表）。
const kProxyBuiltinExcludedKey = StorageKey(
  'fus:proxy:builtin-excluded:v1',
  legacy: 'proxy.builtin.excluded.v1',
);

// ── 身份 ────────────────────────────────────────────────────────

/// 代理 ↔ 身份 ↔ 号码 的账本（JSON）。
const kIdentityLedgerKey = StorageKey('fus:identity:ledger:v1');

/// 当前浏览器身份（JSON）。
const kIdentityCurrentKey = StorageKey('fus:identity:current:v1');

/// 内核大版本基准。**和上面那个分开存**，见 browser_identity.dart。
const kIdentityKernelKey = StorageKey('fus:identity:kernel:v1');

// ── 偏好 ────────────────────────────────────────────────────────

/// 深浅色模式。
const kThemeModeKey = StorageKey(
  'fus:prefs:theme-mode:v1',
  legacy: 'theme_mode',
);

/// 是否翻译短信正文。
const kPrefTranslateKey = StorageKey(
  'fus:prefs:translate:v1',
  legacy: 'pref_translate',
);

/// 译文下面是否保留原文。
const kPrefShowOriginalKey = StorageKey(
  'fus:prefs:show-original:v1',
  legacy: 'pref_show_original',
);

/// 正文字号倍数。
const kPrefFontScaleKey = StorageKey(
  'fus:prefs:font-scale:v1',
  legacy: 'pref_font_scale',
);

/// 译文目标语言。
const kPrefTargetLangKey = StorageKey(
  'fus:prefs:target-lang:v1',
  legacy: 'pref_target_lang',
);

/// 首选翻译引擎。
const kPrefTranslateEngineKey = StorageKey(
  'fus:prefs:translate-engine:v1',
  legacy: 'pref_translate_engine',
);

/// 号码目录是否走代理。
const kPrefDirectoryViaProxyKey = StorageKey(
  'fus:prefs:directory-via-proxy:v1',
  legacy: 'pref_directory_via_proxy',
);

// ── 号码目录缓存 ────────────────────────────────────────────────

/// 号码目录的磁盘缓存（抓到的整页号码 JSON）。
const kDirectoryCacheKey = StorageKey(
  'fus:numbers:directory-cache:v1',
  legacy: 'number_dir_cache_v1',
);

/// 号码「首次被站点收录」的时间表。
const kFirstSeenKey = StorageKey(
  'fus:numbers:first-seen:v1',
  legacy: 'number_first_seen_v1',
);

// ── 收藏 ────────────────────────────────────────────────────────

/// 收藏的号码 id 列表。
const kSavedNumbersKey = StorageKey(
  'fus:saved:numbers:v1',
  legacy: 'fus_saved_numbers_v1',
);
