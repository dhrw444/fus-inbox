/// 收藏的号码。本地持久化，跟着机器走。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _kSavedKey = 'fus_saved_numbers_v1';

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
      final raw = prefs.getStringList(_kSavedKey) ?? const [];
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
      await prefs.setStringList(_kSavedKey, next.toList());
    } catch (_) {}
  }

  bool contains(String id) => state.contains(id);
}

final savedNumbersProvider =
    NotifierProvider<SavedNumbersNotifier, Set<String>>(
      SavedNumbersNotifier.new,
    );
