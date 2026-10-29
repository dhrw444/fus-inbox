/// 内置代理清单的读取。
///
/// 清单在 `assets/proxies/builtin.txt`（全部是带账号密码的
/// SOCKS5）。用户删掉的记在排除表里，所以「恢复内置代理」是清空那张表，
/// 而不是把资源重新拷一遍。
library;

import 'package:flutter/services.dart' show rootBundle;

import 'package:fus_inbox/core/proxy/proxy_config.dart';

/// 内置代理清单的加载与「删掉」记录。
///
/// ## 为什么内置的也能删
///
/// 内置清单是 APK 里的一个资源文件（`assets/proxies/builtin.txt`），
/// 本身只读。用户删一条时不能改资源，所以这里维护一份**排除表**：
/// 被删掉的内置代理记下它的 key，加载时跳过。
///
/// 这样「内置」和「手动添加」在界面上是同一种东西 —— 都能删，
/// 删掉都真的不出现。区别只在：内置的删了之后，清空排除表就能
/// 恢复；手动添加的删了就没了。
class const BuiltinProxies() {
  static const _assetPath = 'assets/proxies/builtin.txt';

  /// 读资源并解析成配置列表。
  ///
  /// [excluded] 是被用户删掉的内置代理 key 集合，命中的跳过。
  Future<List<ProxyConfig>> load({Set<String> excluded = const {}}) async {
    String raw;
    try {
      raw = await rootBundle.loadString(_assetPath);
    } catch (_) {
      // 资源缺失不该让整个代理功能挂掉 —— 用户手动添加的照样能用。
      return const [];
    }
    final out = <ProxyConfig>[];
    for (final line in raw.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
      final cfg = parseProxyLine(trimmed);
      if (cfg == null) continue;
      if (excluded.contains(cfg.id)) continue;
      out.add(cfg);
    }
    return out;
  }
}
