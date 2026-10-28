/// 号码目录的排序规则。
///
/// ## 为什么单独拆一个文件
///
/// 两个理由：
///
/// 1. **它必须是纯 Dart。** 这段逻辑曾经写在 `numbers_provider.dart` 的
///    `NumberDirectoryState.visibleFor` 里，而那个文件 import 了
///    flutter_riverpod —— 于是排序有没有并列兜底，本地一行都跑不了，
///    只能靠通读。抽出来之后 `tool/number_sort_test.dart` 直接 import
///    真实代码跑。
/// 2. **稳定性是硬要求，不是风格问题。** `List.sort` 在 Dart 里
///    **不保证稳定**（实测：全零比较器 + 换一下入参顺序，输出顺序就变）。
///    目录是分页并发抓回来的，页与页的完成顺序和入参顺序每次都可能不同，
///    所以任何一个「并列就返回 0」的比较器都会让列表顺序在刷新之间漂移 ——
///    用户看到的是「列表自己会跳」，而且同一个号码会忽上忽下。
///
/// ## 铁律
///
/// **每个比较器的最后一步都必须兜到 `number` 上。** `number` 是唯一
/// 保证唯一的字段，兜住它这个比较器就成了全序，`List.sort` 稳不稳都
/// 不影响结果。
library;

import 'package:fus_inbox/features/numbers/domain/available_number.dart';

/// 排序方式。
enum NumberSort(this.label) {
  recent('最近活跃'),
  firstSeen('收录时间'),
  messages('短信最多'),
  number('号码顺序');

  final String label;
}

/// 按 [sort] 给 [items] 排序，返回**同一个**列表（原地排）。
///
/// [firstSeen] 只有 [NumberSort.firstSeen] 用得上，所以做成可选参数：
/// 收录时间存在 FirstSeenStore 里（另一个 provider），不在目录 state 上。
List<AvailableNumber> sortNumbers(
  List<AvailableNumber> items,
  NumberSort sort, {
  Map<String, DateTime> firstSeen = const {},
}) {
  switch (sort) {
    case NumberSort.recent:
      items.sort((a, b) {
        // 活跃的在前。站点把「最近有短信」的号单独标出来，接码时
        // 这个比时间戳更直接。
        final af = a.isFresh ? 0 : 1;
        final bf = b.isFresh ? 0 : 1;
        if (af != bf) return af - bf;
        // 空时间戳沉到最后，不能当成 1970：那样它们会永远卡在顶部。
        final at = a.lastTextAt ?? '';
        final bt = b.lastTextAt ?? '';
        final byTime = bt.compareTo(at);
        return byTime != 0 ? byTime : a.number.compareTo(b.number);
      });

    case NumberSort.firstSeen:
      // 新收录的在前。
      //
      // 从没收录过的（表里没记录）一律沉到最后，**不能当成 1970 年**：
      // 那样它们会永远卡在列表底部，而且 `?? 零点` 这类写法在
      // 升/降序切换时很容易反过来把空值顶到最前。
      items.sort((a, b) {
        final at = firstSeen[a.number];
        final bt = firstSeen[b.number];
        if (at == null && bt == null) return a.number.compareTo(b.number);
        if (at == null) return 1;
        if (bt == null) return -1;
        final byTime = bt.compareTo(at);
        return byTime != 0 ? byTime : a.number.compareTo(b.number);
      });

    case NumberSort.messages:
      // 并列兜到号码上，理由同 `recent` —— 而且这里并列多得多：
      // 大部分号码的 messageCount 都是 0 或很小的数，只比这一个字段
      // 等于让一大半列表项的相对顺序随机。
      items.sort((a, b) {
        final byCount = b.messageCount.compareTo(a.messageCount);
        return byCount != 0 ? byCount : a.number.compareTo(b.number);
      });

    case NumberSort.number:
      // 号码本身唯一，天然是全序，不用兜。
      items.sort((a, b) => a.number.compareTo(b.number));
  }
  return items;
}
