/// 收藏的号码。本地持久化，跟着机器走。
///
/// 存的键是站点的 32 位 hex id（`AvailableNumber.id`），不是号码本身 ——
/// 号码卡片和收藏页都用同一个 id 来问 `contains`。
///
/// 落 SharedPreferences 的一个字符串列表：量级只有几十条，不值得上数据库；
/// 读不到就当没收藏，绝不因此挡住主流程。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fus_inbox/core/prefs/storage_keys.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SavedNumbersNotifier() extends Notifier<Set<String>> {
  @override
  Set<String> build() {
    _restore();
    return const {};
  }

  bool _restored = false;

  Future<void> _restore() async {
    if (_restored) return;
    _restored = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = kSavedNumbersKey.readStringList(prefs) ?? const [];
      state = raw.toSet();
    } catch (_) {
      // 读不到就当没收藏，不影响主流程。
    }
  }

  Future<void> toggle(String id) async {
    final next = Set<String>.from(state);
    if (!next.remove(id)) next.add(id);
    state = next;
    try {
      final prefs = await SharedPreferences.getInstance();
      await kSavedNumbersKey.writeStringList(prefs, next.toList());
    } catch (_) {
      // 落盘失败不回滚内存状态：用户改的这一下已经生效了，回滚会让他
      // 看到选项自己弹回去。下次成功写入时自然补上。
    }
  }

  bool contains(String id) => state.contains(id);
}

final savedNumbersProvider =
    NotifierProvider<SavedNumbersNotifier, Set<String>>(
      SavedNumbersNotifier.new,
    );
