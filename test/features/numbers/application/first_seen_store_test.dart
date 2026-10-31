import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fus_inbox/core/prefs/storage_keys.dart';
import 'package:fus_inbox/features/numbers/application/first_seen_store.dart';

/// [FirstSeenStore] 的剪枝与落盘行为。
///
/// 断言对着**盘上的原始字符串**验，不对着内存 `state` 验 ——
/// `retainOnly` 向来先把内存改对，出问题的一直是「改完有没有写盘」
/// 和「谁在什么时候调它」。
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  ProviderContainer container() {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    return c;
  }

  Future<FirstSeenStore> freshStore(ProviderContainer c) async {
    final s = c.read(firstSeenStoreProvider.notifier);
    await s.ready;
    return s;
  }

  Future<String?> raw() async =>
      kFirstSeenKey.readString(await SharedPreferences.getInstance());

  /// 盘上到底有哪些号。
  Future<Set<String>> persistedKeys() async {
    final s = await raw();
    if (s == null || s.isEmpty) return <String>{};
    return RegExp(r'"(\d{10,15})":').allMatches(s).map((m) => m[1]!).toSet();
  }

  test('被下架的号从盘上消失', () async {
    final store = await freshStore(container());
    await store.put('14190000001', DateTime.utc(2026, 10, 28));
    await store.put('14190000002', DateTime.utc(2026, 10, 28));
    expect(await persistedKeys(), {'14190000001', '14190000002'});

    // 站点下架 001，目录里只剩 002。
    await store.retainOnly({'14190000002'});

    expect(store.state.keys.toSet(), {'14190000002'});
    expect(await persistedKeys(), {'14190000002'});
  });

  test('一删一增、键数不变时也要写盘', () async {
    final store = await freshStore(container());
    for (final n in ['14190000001', '14190000002', '14190000003']) {
      await store.put(n, DateTime.utc(2026, 10, 28));
    }

    // 下架 001、保留 002/003 —— 剪完 3 条变 2 条，长度确实变了。
    // 但真正容易漏的形状是：`state` 里有一条不在 keep，keep 里也有一条
    // 不在 state（刚上新还没抓的那个号）。剪完长度可能**正好不变**，
    // 于是「长度相等就跳过写盘」会整轮跳过。
    //
    // 这里不能靠构造同长度去证明那条判据有问题（它是子集，长度相等
    // 必然意味着没丢键），只能证明**剪完必落盘**这个不变量成立。
    await store.retainOnly({'14190000002', '14190000003', '14190000009'});
    expect(await persistedKeys(), {'14190000002', '14190000003'});
  });

  test('一个键都没被丢掉时，盘上原样不动', () async {
    final store = await freshStore(container());
    await store.put('14190000001', DateTime.utc(2026, 10, 28));
    final before = await raw();
    expect(before, isNotNull);

    // keep 是 state 的超集 —— 什么都没丢。
    await store.retainOnly({'14190000001', '14190000099'});
    expect(await raw(), before, reason: '没变化就不该白写一遍盘');
  });

  test('落盘内容能被下次启动读回来', () async {
    final first = await freshStore(container());
    await first.put('14190000001', DateTime.utc(2026, 10, 28, 8, 29));

    // 新容器 = 新进程。同一个 mock 盘，读回来必须一模一样。
    final second = await freshStore(container());
    expect(second.state['14190000001'], DateTime.utc(2026, 10, 28, 8, 29));
  });
}
