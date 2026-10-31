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
  ///
  /// 「数量没变」在这里等价于「一个键都没丢」：[next] 的键只能是 [state]
  /// 键的子集，长度相等就意味着没有条目被过滤掉。不用另设一个 `dropped`
  /// 标记。
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
/// 首次启动时把目录里还没有缓存的号补上，之后每次只补新增的号。
///
/// ## 节奏：**两路并发**，超过就被站点限流
///
/// 这里原来写的是「6 路并发」，依据是「20 个号同时打过去 20/20 都是
/// 200」。那个结论是错的，重测推翻了它 —— 关键是**测法**：单次 20 个号
/// 恰好落在计数器还没攒满的时候，看起来没事；连续打 118 个才现原形。
///
/// 实测（`flutter test`，走产品自己的 `NumbersRepository` 抓 118 个号，
/// 同一份号码清单、只改并发与间隔）：
///
/// | 并发 | 间隔 | 结果 |
/// |---|---|---|
/// | 1 | 200ms | 40/40 全 200 |
/// | 2 | 200ms | 40/40 全 200 |
/// | 3 | 200ms | 41 个 200 / **19 个 429** |
/// | 3 | 150ms | 33 个 200 / **27 个 429** |
/// | 3 | 100ms | 30 个 200 / **30 个 429** |
/// | 4 | 200ms | 30 个 200 / **10 个 429** |
/// | 6 | 120ms | 32 个 200 / **8 个 429** |
///
/// 阈值就在 **2 req/s 附近**：并发 2 + 200ms 是唯一全过的配置，并发 3
/// 把间隔拉到 200ms 也仍有三分之一被拒。所以并发取 2，间隔 200ms。
///
/// 118 个号在 1.9 req/s 下约 **62 秒**。这比 6 路慢，但 6 路那条路
/// 有 70% 的号拿不到收录时间 —— 快而残缺没有意义。
///
/// ## 429 必须重试，不能当「这个号没有收录时间」
///
/// 上面那张表的 429 原来被静默吞掉：`fetchFirstSeen` 见 `statusCode != 200`
/// 就 `return null`，调用方当成「页面里没这个字段」，这个号就**永久**缺
/// 收录时间。结果是 118 个号只补到 31 个，界面上一大半卡片光秃秃的。
///
/// 实测 429 响应头带 `retry-after: 9`（Cloudflare 的短期退避，不是那种
/// 要等几千秒的配额封禁），所以退避重试是有效的：等它说的时间，再打一次。
/// 连续被拒几次才放弃，避免在真封禁上死磕。
///
/// 其余两条约束仍然成立：
///   1. **可中断**。用户切走或重进页面时旧任务要能停下，否则会一直跑到
///      队列末尾，白白多打几十个请求。
///   2. **有间隔**。每路之间 200ms + 抖动，两路合起来约 1.9 req/s。
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

  /// 详情页基址。默认站点本身；测试指向本地服务。
  this.baseUrl = 'https://freeussms.com',
}) {
  final String? Function() egress;

  /// 详情页基址。见构造函数。
  final String baseUrl;

  /// 每调一次 [cancel] 就加一。正在跑的轮记住自己开始时的值，值变了就收工。
  ///
  /// ## 为什么用世代号而不是 bool
  ///
  /// `bool` 在「排队」这套结构里会串味：A 轮在跑 → 用户点开收件页 → `cancel`
  /// 置真 → A 收工 → 用户从收件页返回 → B 轮排队进来。B 轮开头会把标记
  /// 清成 false，但**如果 B 是在 A 收工之前排进来的**，它在 `await prev`
  /// 之后就看到了 A 留下的 `true`，于是自己也放弃 —— 返回之后永远补不上。
  ///
  /// 世代号让「谁被取消了」变成精确的：B 记住的是自己开始那一刻的值，
  /// A 期间的 `cancel` 只影响 A。清标记这件事也就不需要了。
  int _generation = 0;

  /// 整轮补齐复用同一个 HttpClient。
  ///
  /// 之前每个号都 new 一个 —— 105 个号就是 105 次 TLS 握手，
  /// 而握手实测要 1.5 秒以上，光握手就吃掉一百多秒。
  /// 复用一个客户端后走 keep-alive，第二个号开始几乎没有握手开销。
  /// 延迟初始化：`findProxy` 要读 `this._findProxy`，而字段初始化器
  /// 里读不到 `this` —— 只能等第一次用到时再建。
  late final HttpClient _http = HttpClient()
    // 和并发数对齐：`maxConnectionsPerHost` 比并发数小的话，多出来的
    // worker 会排在连接池里等，等于把并发又变回串行。两路并发 → 留 2 条。
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

  /// 停掉当前这一轮（以及任何还在排队等它的轮）。下一轮会从头扫「还缺哪些」。
  ///
  /// 语义是「现在这一刻之前发起的全部作废」：正在跑的收工，排队中的也不再
  /// 开跑。之后新发起的轮记住的是新世代号，不受这次影响 —— 从收件页返回
  /// 时续上的那一轮就靠这个。
  void cancel() => _generation++;

  /// 把 [numbers] 里所有还没有缓存的号补齐。
  ///
  /// [onOne] 每补到一条回调一次，让列表能逐行刷新，而不是最后一次性冒出来。
  /// 返回这轮实际新补了多少条。
  ///
  /// ## 同时只有一轮在飞，但**后到的调用是排队，不是丢弃**
  ///
  /// 两轮同时跑会各自算一份差集、互相看不到对方刚写进 store 的结果，
  /// 对同一批号重复发请求。所以闸门必须有。
  ///
  /// 但闸门不能直接 `return 0`。`_boot` 一启动就开始补一批，100 多个号
  /// 要跑三十秒，用户在这期间下拉刷新是**很常见**的时序 —— 直接丢掉那次
  /// 调用，刷新拉回来的新号一个都补不上，得等下次冷启动。
  ///
  /// 所以后到的调用等前一轮收工再跑自己那一轮。两轮的 todo 各自从
  /// `store.missingFrom` 重新算，第二轮的差集里不会再有第一轮已经补上的号。
  Future<int> fillMissing(
    FirstSeenStore store,
    List<String> numbers, {
    void Function(String number, DateTime at)? onOne,
    int limit = 200,
  }) {
    // 同步段里取旧值 + 登记新值，中间没有 await —— 单线程下不会交错。
    final prev = _round;
    final self = Completer<int>();
    _round = self.future;
    return _fillQueued(
      self,
      prev: prev,
      store: store,
      numbers: numbers,
      onOne: onOne,
      limit: limit,
    );
  }

  /// 正在跑（或正在排队）的那一轮。null = 空闲。
  Future<int>? _round;

  Future<int> _fillQueued(
    Completer<int> self, {
    required Future<int>? prev,
    required FirstSeenStore store,
    required List<String> numbers,
    required void Function(String number, DateTime at)? onOne,
    required int limit,
  }) async {
    // 这一轮开始时的世代号。中途任何一次 `cancel()` 都会让它变化，
    // 变化就意味着「有人不要这一轮了」。
    final gen = _generation;
    try {
      if (prev != null) {
        // 前一轮的失败不该让这一轮跟着失败 —— 两轮各自独立，前一轮没补上
        // 的号这一轮会重新算进差集里。
        try {
          await prev;
        } catch (_) {}
        // 等它期间有人喊停（点开收件页）。这一轮还没开始，直接放弃 ——
        // 免得用户已经进了收件页，后台还在往外打详情页请求。
        if (_generation != gen) {
          self.complete(0);
          return 0;
        }
      }
      final added = await _fillRound(
        store,
        numbers,
        gen: gen,
        onOne: onOne,
        limit: limit,
      );
      self.complete(added);
      return added;
    } catch (e, st) {
      // 给排队中那一轮一个**正常结束**的值，否则它会一直挂在这里等
      // 一个永远不完成的 Future。
      self.completeError(e, st);
      // 错误同时挂在 `_round` 上，没有排队者的话就成了未捕获的异步错误。
      self.future.ignore();
      rethrow;
    } finally {
      // 只有「没有后来者接替」时才把闸门放开 —— 否则会把排队中那一轮的
      // 登记抹掉，第三个调用方就会以为自己是第一个、和前一轮并行跑起来。
      if (identical(_round, self.future)) _round = null;
    }
  }

  Future<int> _fillRound(
    FirstSeenStore store,
    List<String> numbers, {
    required int gen,
    void Function(String number, DateTime at)? onOne,
    int limit = 200,
  }) async {
    var added = 0;
    // 先等读盘。`missingFrom` 是拿内存里的 state 算差集，而 state 在
    // 读盘回来之前是空的 —— 不等的话这一轮会把**所有号**都当成缺的，
    // 白抓一遍（抓回来 `put` 又发现值没变，连盘都不写，只剩纯粹的请求）。
    await store.ready;
    if (_generation != gen) return 0;
    // 差集逻辑只有一处（store.missingFrom），这里不要再自己写一遍：
    // 两份实现迟早会漂移，而「该不该抓」判断错了要么重复请求、
    // 要么永远不补。
    final missing = store.missingFrom(numbers);
    final todo = missing.length > limit ? missing.sublist(0, limit) : missing;
    if (todo.isEmpty) return 0;

    // 并发数。实测见类文档那张表：2 是唯一全过的配置，3 就有三分之一
    // 被 429 拒掉。
    const kConcurrency = 2;
    // 单个号最多试几次。429 会退避重试，但连续被拒说明这个出口已经被
    // 盯上了，再打只会更糟 —— 放弃这一轮，下次刷新再来。
    const kMaxAttempts = 4;

    final workers = <Future<void>>[];
    var next = 0;
    var stopped = false;

    Future<void> worker() async {
      while (!stopped) {
        if (_generation != gen) return;
        final i = next++;
        if (i >= todo.length) return;
        final number = todo[i];

        DateTime? at;
        for (var attempt = 1; attempt <= kMaxAttempts; attempt++) {
          if (_generation != gen) return;
          try {
            at = await fetchFirstSeen(number, client: _http, baseUrl: baseUrl);
            break;
          } on FirstSeenRateLimited catch (e) {
            // 站点说等多久就等多久。这是唯一值得重试的失败：它不是
            // 「这个号没有收录时间」，只是这一下打快了。
            if (attempt == kMaxAttempts) {
              logLine('抓收录时间连续被限流（$number），本轮放弃');
              break;
            }
            // 等待期间也要能被取消打断。
            await _sleepCancellable(e.after, gen);
            if (_generation != gen) return;
          } catch (e) {
            // 网络、超时、5xx：试一次就够。重复打同一个坏请求没意义。
            logLine('抓收录时间失败（$number）：$e');
            break;
          }
        }

        // 取消之后拿到的结果照样落盘 —— 已经花掉的请求不该白费，
        // 但不再继续排队。
        if (at != null) {
          await store.put(number, at);
          added++;
          onOne?.call(number, at);
        }
        if (_generation != gen) {
          stopped = true;
          return;
        }
        // 间隔 200ms + 0~100ms 抖动。两路合起来约 1.9 req/s —— 实测
        // 阈值就在 2 req/s 附近，再快就有 429。
        await _sleepCancellable(
          Duration(milliseconds: 200 + _rnd.nextInt(100)),
          gen,
        );
      }
    }

    for (var i = 0; i < kConcurrency && i < todo.length; i++) {
      workers.add(worker());
    }
    await Future.wait(workers);
    return added;
  }

  /// 睡一会儿，但取消时能提前醒。
  ///
  /// 直接 `Future.delayed` 的话，用户切走之后 worker 还要把这段睡眠走完
  /// 才看见世代号变了 —— 几十个 worker 加起来就是白等。
  Future<void> _sleepCancellable(Duration d, int gen) async {
    const step = Duration(milliseconds: 50);
    var left = d;
    while (left > Duration.zero) {
      if (_generation != gen) return;
      final chunk = left < step ? left : step;
      await Future<void>.delayed(chunk);
      left -= chunk;
    }
  }

  static final _rnd = Random();
}

/// 抓单个号码详情页里的收录时间。
///
/// 三种结果要分开，不能都折成 null：
///
/// - **拿到了** → 返回时间
/// - **页面里确实没有这个字段**（200 但没有 `First recorded`）→ 返回
///   `null`，调用方记成「这个号没有收录时间」，不必重试
/// - **被限流**（429）→ **抛** [FirstSeenRateLimited]，调用方退避重试。
///   折成 null 的话这个号会被当成「没有收录时间」永久跳过 —— 实测
///   118 个号里有 87 个就是这么丢的。
///
/// 其余异常（网络、超时、5xx）也抛，由调用方决定要不要再试。
Future<DateTime?> fetchFirstSeen(
  String e164, {
  HttpClient? client,
  String? Function()? egress,

  /// 详情页地址的基址。默认站点本身；测试用它指向本地服务，
  /// 这样「并发行为」能被真实请求验出来，而不是对着常量断言。
  String baseUrl = 'https://freeussms.com',
}) async {
  final hook = egress;
  final http =
      client ??
      (HttpClient()
        // 和号码目录走同一条出口。回调返回 null/空就**抛**，不返回
        // `DIRECT` —— 返回 DIRECT 请求会成功，但那是拿真实 IP 打站点，
        // 比失败更糟（没人会发现）。没传 `egress` 时才直连（测试用）。
        ..findProxy = (Uri _) {
          if (hook == null) return 'DIRECT';
          final directive = hook();
          if (directive == null || directive.isEmpty) {
            throw StateError('出口没起来，已拒绝直连');
          }
          return directive;
        });
  final own = client == null;
  try {
    final req = await http
        .getUrl(Uri.parse('$baseUrl/numbers/$e164/'))
        .timeout(const Duration(seconds: 8));
    applyBrowserHeaders(req.headers, referer: 'https://freeussms.com/numbers/');
    final res = await req.close().timeout(const Duration(seconds: 10));

    if (res.statusCode == 429) {
      // 站点自己说多久之后再来。实测值是 9 秒（Cloudflare 的短期退避）。
      // 响应体不读会占着连接不放。
      final wait = _retryAfter(res.headers);
      unawaited(res.drain<void>().catchError((Object _) {}));
      throw FirstSeenRateLimited(wait);
    }
    if (res.statusCode != HttpStatus.ok) {
      unawaited(res.drain<void>().catchError((Object _) {}));
      throw HttpException('HTTP ${res.statusCode}', uri: req.uri);
    }
    return parseFirstSeen(await res.transform(utf8.decoder).join());
  } finally {
    if (own) http.close(force: true);
  }
}

/// 站点说「等这么久再来」。没有这个头就用保守的默认值。
Duration _retryAfter(HttpHeaders headers) {
  final raw = headers.value(HttpHeaders.retryAfterHeader);
  final secs = int.tryParse(raw ?? '');
  if (secs != null && secs > 0) return Duration(seconds: secs.clamp(1, 120));
  // 没有头时按实测值退避。上限压在 120 秒：真遇到长时间封禁，卡在这里
  // 不如放弃这一轮，让用户下次刷新再来。
  return const Duration(seconds: 9);
}

/// 被站点限流。带上它说的等待时长。
class const FirstSeenRateLimited(this.after) implements Exception {
  /// 站点 `retry-after` 给的等待时长（已夹到合理区间）。
  final Duration after;

  @override
  String toString() => '被限流，等 ${after.inSeconds}s';
}
