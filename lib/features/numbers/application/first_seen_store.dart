/// 号码「首次被站点收录」时间的**抓取、缓存与落盘**。
///
/// 解析规则在 `domain/first_seen.dart`（纯函数，能在纯 Dart 里测）。
/// 这里放它够不着 IO 的那部分：store、provider、串行补齐器、单个抓取。
///
/// ## 为什么要抓
///
/// 站点只把收录时间放在号码详情页里，列表页没有。所以只能按需抓：
/// 用户点开某个号的收件箱时顺手抓一次，结果永久缓存，之后首页直接带出来。
/// **不预抓整表** —— 百来个号就是百来次请求，那正是站点风控的源头。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fus_inbox/core/proxy/proxy_engine_provider.dart';
import 'package:fus_inbox/core/log.dart';
import 'package:fus_inbox/core/prefs/storage_keys.dart';
import 'package:fus_inbox/core/webview/http_headers.dart';
import 'package:fus_inbox/features/numbers/application/numbers_provider.dart';
import 'package:fus_inbox/features/numbers/domain/first_seen.dart';

/// 号码 → 收录时间。键用 E.164 纯数字（`14197797678`）。
class FirstSeenStore() extends Notifier<Map<String, DateTime>> {
  /// 读盘完成。**所有写操作先等它**（见 [_restore] 的注释）。
  final Completer<void> _ready = Completer<void>();

  /// 等读盘结束。带 3 秒兜底 —— 读盘卡死时写操作也不会被永久挡住。
  ///
  /// 和 `ProxyNotifier.ready` 是同一套：那边是为了防「还没读完就落盘，
  /// 把用户数据覆盖成默认值」，这边是为了防「读完回来把新数据覆盖掉」。
  Future<void> get ready =>
      _ready.future.timeout(const Duration(seconds: 3), onTimeout: () {});

  @override
  Map<String, DateTime> build() {
    // 不 watch 任何东西：这份缓存只由 put() 写入。
    _restore();
    return const {};
  }

  Future<void> _restore() async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = kFirstSeenKey.readString(p);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      final out = <String, DateTime>{};
      for (final e in decoded.entries) {
        final k = e.key;
        final v = e.value;
        if (k is! String || v is! String) continue;
        final t = DateTime.tryParse(v);
        if (t != null) out[k] = t;
      }
      // **合并，不是覆盖。**
      //
      // 读盘期间用户可能已经点开过某个号、`put()` 进了新的收录时间
      // （`build()` 是立刻返回空状态的，`_restore()` 还在 await 读盘）。
      // 一句 `state = out` 会把那些刚写进去的**当场抹掉** —— 界面上的
      // 「收录于…」闪一下就不见了。
      //
      // 冲突时以**内存里的**为准：它是这次会话刚抓到的，比盘上的新。
      // （写操作现在都会先 `await ready`，正常不会再撞上；这条合并是
      //  兜住「3 秒兜底超时之后才写盘」那种边角情况，多一层保险不亏。）
      if (out.isNotEmpty) state = {...out, ...state};
    } catch (_) {
      // 缓存坏了当没有：附注信息不值得任何补救路径。
    } finally {
      // 成功、失败、压根没缓存 —— 都要放开闸门，否则写操作会一直等到超时。
      if (!_ready.isCompleted) _ready.complete();
    }
  }

  DateTime? get(String number) => state[number];

  /// 只保留 [keep] 里出现过的号码，其余丢掉。
  ///
  /// 站点会轮换号池：今天下架的号在本地的收录时间就再也不会有用了，
  /// 不清的话缓存只增不减。每次目录刷新后调用一次。
  /// 数量没变就跳过，避免每次都白写一遍盘。
  Future<void> retainOnly(Set<String> keep) async {
    await ready;
    final next = <String, DateTime>{
      for (final e in state.entries)
        if (keep.contains(e.key)) e.key: e.value,
    };
    if (next.length == state.length) return;
    state = next;
    await _save();
  }

  /// 还缺哪些号码的收录时间。
  ///
  /// 目录缓存和收录时间缓存共用号码这个键，两个缓存之间就是靠它对应的。
  /// 这里直接算差集，于是「哪些要抓」这件事只由数据决定，不需要额外的标记位。
  List<String> missingFrom(Iterable<String> numbers) => [
    for (final n in numbers)
      if (!state.containsKey(n)) n,
  ];

  /// 写入一条并落盘。已经有的不重复写。
  Future<void> put(String number, DateTime at) async {
    await ready;
    if (state[number] == at) return;
    state = {...state, number: at};
    await _save();
  }

  Future<void> _save() async {
    try {
      final p = await SharedPreferences.getInstance();
      await kFirstSeenKey.writeString(
        p,
        jsonEncode({
          for (final e in state.entries) e.key: e.value.toIso8601String(),
        }),
      );
    } catch (_) {
      // 落盘失败只影响下次启动，本次会话仍可用。
    }
  }
}

final firstSeenStoreProvider =
    NotifierProvider<FirstSeenStore, Map<String, DateTime>>(FirstSeenStore.new);

/// 全 App 一个填充器：两处同时跑会互相看不到对方的进度，
/// 结果是对同一批号码重复发请求。
final firstSeenFillerProvider = Provider<FirstSeenFiller>((ref) {
  final f = FirstSeenFiller(
    // 和号码目录**同一个**回调 —— 见 `numbersEgress` 的文档。
    // 用裸的 `nativeEgressDirective` 会出事：它不看「目录走代理」这个
    // 开关，用户没开也会走代理（行为不一致）。
    egress: () => numbersEgress(ref),
  );
  ref.onDispose(() {
    // 两个都要做：cancel 让循环尽快退出，dispose 关掉连接池。
    // 只 cancel 不 dispose 会泄漏 socket。
    f.cancel();
    f.dispose();
  });
  return f;
});

/// 批量补齐收录时间。
///
/// 首次启动时把目录里还没有缓存的号逐个补上，之后每次只补新增的号。
///
/// 三条硬约束：
///   1. **串行**，不并发。详情页是站点自己的页面，一次打十几个并发请求
///      就是最典型的风控特征。
///   2. **有间隔，但不等太久**。两次之间 120ms + 抖动。
///   3. **可中断**。用户切走或重进页面时旧任务要能停下，否则会一直跑到
///      队列末尾，白白多打几十个请求。
/// 补齐收录时间。
///
/// ## 必须和号码目录走**同一条出口**
///
/// 这里原先自己 new 一个裸 `HttpClient`，从不设 `findProxy` ——
/// 而 `dart:io` 不走 WebView 的 `ProxyController`，不挂 `findProxy`
/// 就是**直连**。于是「号码目录走代理」这个开关只对目录主体生效，
/// 补齐收录时间这条链路把 100+ 个详情页请求全交给**真实 IP**，
/// 界面一个字都不说。
///
/// 用户打开那个开关的全部动机就是不拿真实 IP 打站点（配额按出口 IP
/// 算），这条链路把它整个绕过去了。所以 [egress] 是**必填**的。
class FirstSeenFiller({
  /// 出口指令（`HttpClient.findProxy` 的返回值）。
  ///
  /// 和 `NumbersRepository.egress` 是**同一个**回调 —— 上层注入一次，
  /// 两边共用。返回 null 表示「要代理但引擎还没起来」，这时抛异常
  /// 让请求失败，绝不悄悄直连。
  required this.egress,
}) {
  final String? Function() egress;
  bool _running = false;
  bool _cancelled = false;

  /// 整轮补齐复用同一个 HttpClient。
  ///
  /// 之前每个号都 new 一个 —— 105 个号就是 105 次 TLS 握手，
  /// 而握手实测要 1.5 秒以上，光握手就吃掉一百多秒。
  /// 复用一个客户端后走 keep-alive，第二个号开始几乎没有握手开销。
  /// 延迟初始化：`findProxy` 要读 `this._findProxy`，而字段初始化器
  /// 里读不到 `this` —— 只能等第一次用到时再建。
  late final HttpClient _http = HttpClient()
    ..maxConnectionsPerHost = 2
    ..connectionTimeout = const Duration(seconds: 8)
    ..idleTimeout = const Duration(seconds: 30)
    // 和号码目录走同一条出口 —— 不挂这句就是直连（见类文档）。
    ..findProxy = _findProxy;

  /// 出口闸门。判据和 `NumbersRepository._findProxy` 完全一致：
  /// 回调返回 null/空 就**抛**，不返回 `DIRECT`。
  ///
  /// 返回 `DIRECT` 的话请求会成功，但那是拿真实 IP 打站点 ——
  /// 比失败更糟，因为没人会发现。
  String _findProxy(Uri uri) {
    final directive = egress();
    if (directive == null || directive.isEmpty) {
      throw StateError('出口没起来，已拒绝直连');
    }
    return directive;
  }

  /// 关掉连接池。provider 销毁时调用。
  void dispose() => _http.close(force: true);

  /// 停掉当前这一轮。下一轮会从头扫「还缺哪些」。
  void cancel() => _cancelled = true;

  /// 把 [numbers] 里所有还没有缓存的号补齐。
  ///
  /// [onOne] 每补到一条回调一次，让列表能逐行刷新，而不是最后一次性冒出来。
  /// 返回这轮实际新补了多少条。
  Future<int> fillMissing(
    FirstSeenStore store,
    List<String> numbers, {
    void Function(String number, DateTime at)? onOne,
    int limit = 200,
  }) async {
    if (_running) return 0;
    _running = true;
    // 每轮开始都清掉上一轮的取消标记，否则上一轮 cancel 过之后
    // 这一轮会在第一个号之前就 break。
    _cancelled = false;
    var added = 0;
    try {
      // 先等读盘。`missingFrom` 是拿内存里的 state 算差集，而 state 在
      // 读盘回来之前是空的 —— 不等的话这一轮会把**所有号**都当成缺的，
      // 白抓一遍（抓回来 `put` 又发现值没变，连盘都不写，只剩纯粹的请求）。
      await store.ready;
      // 差集逻辑只有一处（store.missingFrom），这里不要再自己写一遍：
      // 两份实现迟早会漂移，而「该不该抓」判断错了要么重复请求、
      // 要么永远不补。
      final missing = store.missingFrom(numbers);
      final todo = missing.length > limit ? missing.sublist(0, limit) : missing;
      if (todo.isEmpty) return 0;

      for (final number in todo) {
        if (_cancelled) break;
        final at = await fetchFirstSeen(number, client: _http);
        if (_cancelled) break;
        if (at != null) {
          await store.put(number, at);
          added++;
          onOne?.call(number, at);
        }
        // 间隔 120ms + 0~80ms 抖动。
        //
        // 之前是 700~1200ms：105 个号要跑 100 秒以上，用户以为卡死。
        // 关键是串行 + 有节奏，不是慢 —— 120ms 串行在服务端看来
        // 仍然是「一页一页翻」，但 105 个只需 15 秒左右。
        // 抓空一个（站点没收录该号）也算一次，所以延时在循环末尾。
        await Future<void>.delayed(
          Duration(milliseconds: 120 + _rnd.nextInt(80)),
        );
      }
    } finally {
      _running = false;
    }
    return added;
  }

  static final _rnd = Random();
}

/// 抓单个号码详情页里的收录时间。
///
/// 失败返回 null —— 收录时间只是附注，不能因为它拦住收件箱。
Future<DateTime?> fetchFirstSeen(
  String e164, {
  HttpClient? client,
  String? Function()? egress,
}) async {
  /// 没有出口回调时的兜底：直连。
  ///
  /// **只给「不关心出口」的调用方用**（比如测试）。真正跑 App 时
  /// 一定要传 `egress` —— 否则就是拿真实 IP 打站点。
  String _direct(Uri uri) => 'DIRECT';

  /// 把「无参出口回调」包成 `findProxy` 要的形状。
  ///
  /// 判据和 `NumbersRepository._findProxy` 完全一致：回调返回 null/空
  /// 就**抛**，不返回 `DIRECT` —— 返回 DIRECT 的话请求会成功，但那是
  /// 拿真实 IP 打站点，比失败更糟（没人会发现）。
  String _gate(String? Function() hook, Uri uri) {
    final directive = hook();
    if (directive == null || directive.isEmpty) {
      throw StateError('出口没起来，已拒绝直连');
    }
    return directive;
  }

  final hook = egress;
  final http =
      client ??
      (HttpClient()
        ..findProxy = hook == null ? _direct : (u) => _gate(hook, u));
  final own = client == null;
  try {
    final req = await http
        .getUrl(Uri.parse('https://freeussms.com/numbers/$e164/'))
        .timeout(const Duration(seconds: 8));
    applyBrowserHeaders(req.headers, referer: 'https://freeussms.com/numbers/');
    final res = await req.close().timeout(const Duration(seconds: 10));
    if (res.statusCode != HttpStatus.ok) {
      // 响应体不读会占着连接不放。
      unawaited(res.drain<void>().catchError((Object _) {}));
      return null;
    }
    return parseFirstSeen(await res.transform(utf8.decoder).join());
  } catch (e) {
    // 失败就当这个号「没有收录时间」：界面少一行附注，功能照常。
    logLine('抓收录时间失败（$e164）：$e');
    return null;
  } finally {
    if (own) http.close(force: true);
  }
}
