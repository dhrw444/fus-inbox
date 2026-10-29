/// 一帧通道消息怎么并进列表：归一化、按 id 去重、按时间降序、裁剪。
///
/// ## 为什么从 `inbox_provider.dart` 里拆出来
///
/// 那边是「状态怎么变」（emit、reset、note、fail），这里是「一帧原始数据
/// 怎么变成一份列表」—— 一个纯函数，输入输出都是值，不碰任何字段。
///
/// 拆开的实际好处：这套合并规则里有两处曾经出过真错（`insert(0)` 把整批
/// 翻转成旧→新、`_seen` 只增不减稳定泄漏），而它们都藏在 90 行的
/// `ingest()` 中段，改一行得先在心里跑一遍整个 store。现在它只吃参数。
///
/// ## 两条必须守住的规矩
///
/// 1. **顺序按时间降序收尾，不靠插入位置**。站点给的是「新→旧」，逐条
///    `insert(0)` 会把整批翻过来，最新的沉到最底。
/// 2. **比较器必须给出一致的偏序**。时间戳缺失的（protected 消息就没有）
///    排在后面；两个都缺失时返回 0 —— 但返回 0 在 `List.sort` 里不稳定，
///    所以原序由调用方保证（这里靠 `order` 列表固定顺序）。
library;

import 'package:fus_inbox/core/time/site_time.dart';
import 'package:fus_inbox/features/inbox/domain/inbox_message.dart';

/// 列表保留的最大条数。
///
/// 必须容得下翻页拉回来的历史：列表是新→旧排列，裁剪时砍掉的是尾部
/// （最老的）。若这里等于一页的量，翻页拿到的消息会立刻被裁掉，
/// 功能看着有、实际永远是空。
const kInboxMaxMessages = 240;

/// 把一帧 `items` 并进 [current]，返回新的列表和新的「已见过」集合。
///
/// [seen] 是首屏之后判断「哪些算新」的依据；[firstBatchDone] 为 false 时
/// 这一帧就是首屏，里面一条都不标「新」。
///
/// 返回值里的 `seen` 可能已经是同一个对象（没超上限时原地扩容），调用方
/// 不要假设它一定是新实例，但可以假设它内容正确。
({List<InboxMessage> messages, Set<String> seen}) mergeInboxFrame({
  required List<InboxMessage> current,
  required List<Object?> items,
  required Set<String> seen,
  required bool firstBatchDone,
}) {
  // 逐条归一化 + 按 id 去重（同 id 后到的覆盖先到的，正文可能分批抵达）。
  final byId = <String, InboxMessage>{};
  final order = <String>[];
  for (final m in current) {
    byId[m.id] = m;
    order.add(m.id);
  }

  for (final raw in items) {
    if (raw is! Map) continue;
    final msg = InboxMessage.fromJson(Map<String, dynamic>.from(raw));
    if (msg.id.isEmpty || (msg.text.isEmpty && !msg.hasCode)) continue;
    final old = byId[msg.id];
    if (old == null) {
      // 站点给的是「新→旧」，原序追加；最后的 sort 负责排序，
      // 这里再 insert(0) 只会把整批翻转。
      order.add(msg.id);
    }
    // 同 id 的新帧可能只带了一部分字段（正文分批抵达），缺的沿用旧值。
    byId[msg.id] = InboxMessage(
      id: msg.id,
      text: msg.text.isNotEmpty ? msg.text : (old?.text ?? ''),
      code: msg.hasCode ? msg.code : (old?.code ?? ''),
      sender: msg.sender.isNotEmpty ? msg.sender : (old?.sender ?? ''),
      receivedAt: msg.receivedAt.isNotEmpty
          ? msg.receivedAt
          : (old?.receivedAt ?? ''),
      phone: msg.phone.isNotEmpty ? msg.phone : (old?.phone ?? ''),
      isProtected: msg.isProtected,
      // **`isNew` 要带过来。**
      //
      // 重建 `InboxMessage` 时漏了它 —— 每收到一帧，已经标为「新」的
      // 消息都被重置成默认的 false，「新」横幅出现一帧就被下一帧抹掉。
      isNew: old?.isNew ?? false,
    );
  }

  // 统一按时间降序收尾，而不是靠插入位置——insert(0) 会把整批翻成
  // 「旧→新」，最新的沉到最底。同 id 的新帧带更完整正文时也留在原位，
  // 不会跳到头部。
  final merged = <InboxMessage>[];
  for (final id in order) {
    final m = byId[id];
    if (m == null) continue;
    // 首屏已存在的算旧；之后新出现的标「新」。
    final isNew = firstBatchDone && !seen.contains(m.id);
    merged.add(m.copyWith(isNew: isNew));
  }
  merged.sort((a, b) {
    final at = parseSiteTime(a.receivedAt);
    final bt = parseSiteTime(b.receivedAt);
    // 时间戳可能缺失（protected 消息就没有时间）。缺失的排在后面，
    // 两个都缺失时保持原序——比较器必须给出一致的偏序，
    // 否则 List.sort 的结果不稳定，顺序会随点数漂移。
    if (at == null && bt == null) return 0;
    if (at == null) return 1;
    if (bt == null) return -1;
    return bt.compareTo(at);
  });
  // 站点自己也有条数上限（live.js 的 messageSize），这里同样裁一下，
  // 否则收件页开着跑一整天，列表和无界增长的 seen 一起吃掉内存。
  if (merged.length > kInboxMaxMessages) {
    merged.removeRange(kInboxMaxMessages, merged.length);
  }
  // seen 必须跟着裁剪，否则它会永远膨胀——之前注释说「一起裁」，
  // 但实际只裁了 merged，seen 只增不减，开一整天就是稳定泄漏。
  var nextSeen = seen;
  if (nextSeen.length > kInboxMaxMessages * 2) {
    final keep = {for (final m in merged) m.id};
    nextSeen = {...nextSeen.where(keep.contains)};
  }
  for (final m in merged) {
    nextSeen.add(m.id);
  }

  return (messages: merged, seen: nextSeen);
}

/// 状态栏那一行字：有多少条、几条带码、来自哪。
///
/// 拆成纯函数是因为它有三种分支（空列表 + 出错 / 空列表 + 等待 /
/// 有内容），以前夹在 `_emit(InboxState(...))` 的实参里，读的时候
/// 得先跳过整个状态构造。
String inboxStatusLine({
  required List<InboxMessage> merged,
  required String source,
  required int hits,
  required String? err,
}) {
  if (merged.isEmpty) {
    return err != null
        ? '抓取出错：$err'
        : '收件页已打开，等新短信…${hits > 0 ? '（已截获 $hits 次响应）' : ''}';
  }
  final codes = merged.where((m) => m.hasCode).length;
  return '${merged.length} 条短信'
      '${codes > 0 ? ' · $codes 条带验证码' : ''}'
      '${source.isNotEmpty ? ' · 来自$source' : ''}';
}
