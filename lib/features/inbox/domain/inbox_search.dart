/// 收件箱的搜索匹配。
///
/// 纯函数、不碰 UI —— 收件箱里「搜什么、怎么算命中」和「列表怎么画」
/// 是两件事。抽出来之后能直接喂一串消息跑，`tool/inbox_search_test.dart`
/// 就是这么测的。
///
/// ## 为什么匹配这四个字段
///
/// 用户搜的东西只有四种可能：
///
/// - **验证码**（`code`）—— 最常用的。站点把验证码单独抽出来放在这个字段，
///   所以它比正文命中更"准"。
/// - **发送方**（`sender`）—— 「刚才那条是哪个平台发的」。
/// - **正文**（`text`）—— 兜底，关键词落在正文里。
/// - **号码**（`phone`）—— 多号同时开着时区分是哪个号收的。
///
/// 时间（`receivedAt`）故意**不**参与匹配：它是 ISO 串，用户不会拿它当关键词，
/// 但里面全是数字 —— 参与匹配会让「搜 2026」把整页消息全命中。
library;

import 'package:fus_inbox/features/inbox/domain/inbox_message.dart';

/// 查询词归一化：去首尾空白、转小写、把内部连续空白压成一个。
///
/// 不收窄成「只留数字字母」：中文发送方（`淘宝`）也要能搜。只做大小写和空白。
String normalizeInboxQuery(String raw) =>
    raw.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

final _wsRun = RegExp(r'\s+');

/// 这条消息命中 [query] 吗。
///
/// 空查询命中一切（调用方据此跳过过滤）。[query] 应当是已经
/// [normalizeInboxQuery] 过的 —— 每条消息都比一次，别在这里重复归一化。
///
/// ## 查询里带空白时，正文这边的空白也要先压平
///
/// 短信正文里连续空格/换行很常见（站点模板的缩进、换行符），而查询词已经
/// 被压成了一个空格。不压这一边，搜「hello world」就匹配不上
/// 「Hello   World」—— 用户只会觉得「我明明看着有这句话」。
///
/// 只在查询**确实含空白**时才做这一步：那种查询很少，而每按一个键都要
/// 对两百多条消息跑四遍正则是不划算的。查询是单个词时，`contains` 本来
/// 就不受正文里的多余空白影响。
bool inboxMessageMatches(InboxMessage m, String query) {
  if (query.isEmpty) return true;
  final fold = query.contains(' ')
      ? (String s) => s.toLowerCase().replaceAll(_wsRun, ' ')
      : (String s) => s.toLowerCase();
  return fold(m.code).contains(query) ||
      fold(m.sender).contains(query) ||
      fold(m.text).contains(query) ||
      fold(m.phone).contains(query);
}

/// 查询词是不是「纯数字」。
///
/// 用户敲一串数字时，意图几乎一定是**找验证码**（验证码就是数字）。
/// 这条判据只用来决定排序，不影响命中集合。
bool isNumericQuery(String query) =>
    query.isNotEmpty && RegExp(r'^\d+$').hasMatch(query);

/// 按查询词过滤。
///
/// ## 两个筛子
///
/// - [query]：关键词，见 [inboxMessageMatches]。
/// - [codeOnly]：只要带验证码的那几条。这是「看看都收到过什么验证码」
///   最直接的用法 —— 不用先想关键词。
///
/// ## 排序
///
/// 默认保持原序（列表本来就是新的在前）。**唯一例外**：查询词是纯数字时，
/// 「验证码字段命中」的排在前面 —— 那种查询的意图就是找码，而正文里
/// 恰好含有同一串数字的消息（订单号、金额）会混进来，把它们排在后面
/// 省得翻。
///
/// 排序是**稳定**的：同一组内保持原有先后，不会让同一屏的次序乱跳。
List<InboxMessage> filterInboxMessages(
  List<InboxMessage> all, {
  required String query,
  bool codeOnly = false,
}) {
  final q = normalizeInboxQuery(query);
  final filtered = [
    for (final m in all)
      if ((!codeOnly || m.hasCode) && inboxMessageMatches(m, q)) m,
  ];
  if (!isNumericQuery(q) || codeOnly) return filtered;

  // 稳定分区：验证码命中的在前，其余在后（两组内部各自保持原序）。
  final byCode = <InboxMessage>[];
  final rest = <InboxMessage>[];
  for (final m in filtered) {
    if (m.code.toLowerCase().contains(q)) {
      byCode.add(m);
    } else {
      rest.add(m);
    }
  }
  return [...byCode, ...rest];
}
