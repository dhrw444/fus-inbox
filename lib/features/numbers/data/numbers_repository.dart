/// 号码目录抓取：原生 HTTP，完全不依赖 WebView。
///
/// 一页 HTML 怎么解析见 `directory_page.dart`；失败后怎么退避重试见
/// `fetch_backoff.dart`（都在这里转出去，引用方不用多写 import）。
///
/// 这个文件只管三件事：**走哪条出口**（[NumbersRepository.egress] + `_findProxy`）、
/// **连接怎么复用**（`HttpClient` 的池参数）、**几页怎么并发**（`fetchAll`
/// 的先探后并）。剩下一律不碰。
///
/// 为什么能不走 WebView：`/numbers/` 是 WordPress 服务端直出的页面，号码卡片是
/// 静态 HTML（`article.number-card`），不需要站点的会话签名。站点把签名锁
/// 只放在 `/sms-api/v1/*`（短信正文）上，目录页自己留了活口——它自己的
/// live.js 里写着 "This gate controls SMS bodies only."
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fus_inbox/core/log.dart';
import 'package:fus_inbox/core/webview/http_headers.dart';
import 'package:fus_inbox/features/numbers/data/directory_page.dart';
import 'package:fus_inbox/features/numbers/data/fetch_backoff.dart';
import 'package:fus_inbox/features/numbers/domain/available_number.dart';

export 'package:fus_inbox/features/numbers/data/directory_page.dart';
export 'package:fus_inbox/features/numbers/data/fetch_backoff.dart';

/// 目录数据源。
///
/// 不能是 `const` 主构造：[client] 是 `late final`，需要非 const 初始化。
class NumbersRepository({
  this.client,
  this.egress,
  this.base = 'https://freeussms.com',
}) {
  /// 可注入的 HTTP 客户端；为空时自建一个，由本实例负责关闭。
  final HttpClient? client;

  /// 出口指令，即 [`HttpClient.findProxy`] 的返回值。由上层注入。
  ///
  /// ## 和收件页共用同一个节点
  ///
  /// 这里不自己挑节点、也不自己起桥 —— 出口就是收件页正在用的那一条
  /// （`ProxyEngine` 的当前出口）。一个 App 只有一个出口，所以注入的
  /// 回调直接读引擎的实时状态，而不是在构造时抓一个端口快照
  /// （代理会轮换、桥会重建，端口每次都不一样）。
  ///
  /// ## 为什么这件事必须是显式的
  ///
  /// `dart:io` 的 `HttpClient` 由 Dart VM 直接发 socket，**不经过
  /// WebView 的 `ProxyController`**。实测确认：
  /// 不挂 `findProxy` 时请求照样成功、SOCKS5 侧连接数为 0 —— 那意味着
  /// 「以为在走代理」和「真的在走代理」从外面看不出任何区别。
  ///
  /// 三种取值，对应三种明确状态：
  /// - `'DIRECT'` —— 有意直连（用户没开「号码目录走代理」）
  /// - `'PROXY host:port'` —— 走当前那条出口
  /// - `null` —— 「要代理但引擎还没起来」，[_findProxy] 会抛异常让请求
  ///   **失败**，而不是悄悄退回直连
  final String? Function()? egress;

  /// 站点根。可注入，唯一目的是让「目录抓取」这条链路能在本地服务器上
  /// 离线测 —— 直连 / 走代理 / 拒绝直连三条路都值得真跑一遍，而它们都
  /// 发生在发请求这一层，跟站点返回什么无关。
  final String base;

  late final HttpClient _http = client ?? HttpClient()
    ..findProxy = _findProxy
    // 连接复用是这里唯一真正有效的提速手段。
    //
    // 实测单页耗时构成：DNS 0.27s + TCP 0.28s + **TLS 握手 1.5~1.8s**
    // + 传输。TLS 占了六成以上，而它只在新建连接时发生一次。
    // 只要把 5 页塞进同一条 keep-alive 连接，后 4 页能省掉 4 次握手，
    // 合计少 6~7 秒——比调整任何页间隔都管用。
    //
    // maxConnectionsPerHost 给到 6：并发抓 3 页时每个都要独立连接，
    // 默认值在某些平台上偏小，会导致请求排队等连接。
    ..maxConnectionsPerHost = 6
    ..connectionTimeout = const Duration(seconds: 15)
    // idleTimeout 要盖住整个抓取过程（并发后约 5 秒），
    // 太短会在页与页之间被回收，等于每次重握手。
    ..idleTimeout = const Duration(seconds: 45)
    // 站点返回 gzip，解压由客户端做，省带宽也省时间。
    ..autoUncompress = true;

  String _pageUrl(int page) =>
      page <= 1 ? '$base/numbers/' : '$base/numbers/page/$page/';

  /// [`HttpClient.findProxy`] 的实现。两种模式，由 [egress] 决定。
  ///
  /// **没注入 [egress] → 直连。** 这是测试和纯解析场景的路径。
  ///
  /// **注入了 → 失败即拒绝。** 回调返回 `null` 就抛异常，绝不退化成直连。
  ///
  /// 为什么用异常而不是返回 `'DIRECT'`：实测
  /// （tool/findproxy_failclosed_test.dart）`findProxy` 里抛出的异常会
  /// 直接让这一次 `getUrl` 失败，错误信息能一路传到界面上的
  /// 「目录拉取失败：…」，用户看得见。
  ///
  /// 返回 `'DIRECT'` 的后果完全不同：请求成功、页面正常显示、一条报错
  /// 都没有，唯一的变化是真实 IP 被交出去了一次。那种失败没人能发现。
  ///
  /// 顺带实测过：返回一个连不上的 `PROXY 127.0.0.1:1` 也会失败，但错误
  /// 是 `SocketException: Connection refused`，不如这里说得清楚。
  String _findProxy(Uri uri) {
    final hook = egress;
    if (hook == null) return 'DIRECT';
    final directive = hook();
    if (directive == null || directive.isEmpty) {
      throw StateError('出口没起来，已拒绝直连');
    }
    return directive;
  }

  /// 抓一页。失败抛 [NumberFetchException]。
  ///
  /// 用 `dart:io` 而不是 `package:http`：这里只需要「GET 一个页面、按 UTF-8 解码」，
  /// 内置客户端够用，还能少一个依赖。注意 [HttpClient] 不会自动带 User-Agent，
  /// 站点按 UA 区分移动端模板，必须显式设。
  Future<NumberPage> fetchPage(int page) async {
    final uri = Uri.parse(_pageUrl(page));
    late final HttpClientResponse res;
    try {
      final req = await _http.getUrl(uri).timeout(const Duration(seconds: 20));
      applyBrowserHeaders(req.headers, base: base, referer: _pageUrl(page));
      res = await req.close().timeout(const Duration(seconds: 20));
    } on Exception catch (e) {
      throw NumberFetchException('网络请求失败：$e');
    }
    if (res.statusCode != HttpStatus.ok) {
      // 响应体不读会占着连接不放。
      unawaited(res.drain<void>().catchError((Object _) {}));
      throw NumberFetchException('目录返回 HTTP ${res.statusCode}');
    }
    final body = await res.transform(utf8.decoder).join();
    return parseDirectory(body);
  }

  /// 站点模板固定每页 24 条（实测）。
  static const _pageSize = 24;

  /// 纯保险丝：号码池异常膨胀时别把请求数堆成无穷。
  static const _pageCap = 40;

  /// 抓完整个目录。
  ///
  /// 策略是「先探后并」：
  ///   1. 先单独抓第 1 页 —— 拿到站点自报总数，就能确定到底有几页
  ///   2. 剩下的页**并发**抓，用信号量限制同时最多 3 个在飞
  ///
  /// 为什么并发：单页实测 2~4 秒（站点在 Cloudflare 后面，握手本身慢），
  /// 5 页串行就是 10 秒起。这是加载慢的真正原因，不是页间隔。
  /// 限到 3 个并发是折中：既不像爆破，又能把 10 秒压到 4 秒左右。
  ///
  /// 页数由「站点自报总数」精确推导，[maxPages] 只用来收紧上限。
  ///
  /// [onProgress] 每完成一页回调一次，用于界面显示「已加载 N 个号」。
  /// [onPage] 每次有页完成就把当前完整快照交出去，供上层立刻渲染。
  Future<List<AvailableNumber>> fetchAll({
    int? maxPages,
    void Function(int loaded, int page)? onProgress,
    void Function(List<AvailableNumber> soFar)? onPage,
  }) async {
    var limit = maxPages ?? _pageCap;
    if (limit <= 0 || limit > _pageCap) limit = _pageCap;

    // 第 1 页：必须单独先来，因为要读它自报的总数。
    final first = await _fetchWithRetry(1);
    if (first == null || first.numbers.isEmpty) {
      throw NumberFetchException('首页抓取失败');
    }

    final total = first.total;
    if (total != null && total > 0) {
      final needed = (total / _pageSize).ceil();
      if (needed < limit) limit = needed;
    }

    final seen = <String>{};
    final out = <AvailableNumber>[];
    for (final n in first.numbers) {
      if (seen.add(n.number)) out.add(n);
    }
    onProgress?.call(out.length, 1);
    onPage?.call(List<AvailableNumber>.unmodifiable(out));

    if (limit <= 1 || first.numbers.length < _pageSize) {
      return out;
    }

    // 剩余页并发。
    //
    // 三个必须注意的点（第一版全踩了）：
    //   1. 任务分配要在**同步段**里完成：先 removeAt 再 await。
    //      否则两个 worker 可能在 await 间隙拿到同一页，重复请求。
    //   2. 单页失败不能让 worker 退出——它退出后队列里剩下的页就没人抓了。
    //      正确做法是记一笔继续取下一页。
    //   3. out / seen 的写入要串行化。Dart 虽然单线程，但 await 之间
    //      交错的写入会让 onPage 快照出现「号码忽多忽少」的抖动。
    final queue = <int>[for (var p = 2; p <= limit; p++) p];
    var done = 1;
    var failed = 0;

    /// 把一个任务的结果并入主列表。
    /// 抽成同步函数，保证「改 out + 回调」是一个不可分割的片段。
    void mergeBatch(NumberPage batch) {
      done++;
      for (final n in batch.numbers) {
        if (seen.add(n.number)) out.add(n);
      }
      onProgress?.call(out.length, done);
      onPage?.call(List<AvailableNumber>.unmodifiable(out));
    }

    Future<void> worker() async {
      while (true) {
        // 取值和判空在同一个同步片段里，中间没有 await。
        if (queue.isEmpty) return;
        final page = queue.removeAt(0);

        final batch = await _fetchWithRetry(page);
        if (batch == null) {
          // 这一页彻底失败了，但**不退出**——继续抓剩下的。
          failed++;
          continue;
        }
        if (batch.numbers.isEmpty) {
          // 空页意味着站点已经没有更多了，清空队列让所有 worker 收工。
          queue.clear();
          return;
        }
        mergeBatch(batch);
      }
    }

    const concurrency = 3;
    await Future.wait([
      for (var i = 0; i < concurrency && i < limit - 1; i++) worker(),
    ]);

    if (out.isEmpty) {
      throw NumberFetchException('目录抓取失败（$failed 页出错）');
    }
    // 部分页失败时补一条日志便于排查（全部失败的情况上面已经抛了）。
    if (failed > 0) {
      logLine('目录：$failed 页抓取失败，已拿到 ${out.length} 个号');
    }
    return out;
  }

  /// 抓单页并带退避重试。失败返回 null。
  ///
  /// 退避窗口、重试次数、以及「为什么必须 catch 所有 Object」全在
  /// `fetch_backoff.dart`；这里只补上「第几页」这个上下文。
  Future<NumberPage?> _fetchWithRetry(int page) => withBackoff(
    () => fetchPage(page),
    onGiveUp: (e) => logLine('目录第 $page 页失败：$e'),
  );

  /// 释放 HTTP 客户端。provider 销毁时调用。
  /// `force: true` 顺手掐掉还在飞的请求，页面销毁时不必等。
  void dispose() => _http.close(force: true);
}
