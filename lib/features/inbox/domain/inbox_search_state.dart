/// 收件页的搜索状态。
///
/// ## 为什么收成一个对象
///
/// 原来是三个散在 `_InboxScreenState` 上的字段（`_searching` / `_query` /
/// `_codeOnly`），它们**必须一起变**：
///
/// - 关闭搜索 = 三个一起清（否则下次点开还留着上次的关键词）
/// - 打开搜索 = 至少要 `searching = true`
///
/// 拆成三个字段时，任何一处漏清一个就会留下半套状态 —— 而那种 bug 在界面上
/// 只表现为「怎么一打开就只剩几条」，很难联想到是状态没清。收成一个不可变
/// 对象之后，「清空」只有一个入口（[closed]），漏不了。
///
/// ## 为什么放在页面层而不是 [InboxStore]
///
/// store 是「站点推过来什么」的镜像；搜索是「我怎么看这些数据」，两件事。
/// 放进 store 会被下一帧数据覆盖掉。
library;

/// 一次搜索的完整状态。不可变，改任何一个都要整个换掉。
class const InboxSearch({
  /// 搜索框是否展开。
  required this.open,

  /// 搜索关键词（原样，未归一化）。空串 = 没在搜。
  required this.query,

  /// 只看带验证码的那几条。
  required this.codeOnly,
}) {
  final bool open;
  final String query;
  final bool codeOnly;

  /// 没在搜索：搜索框收起、关键词空、不过滤。
  static const closed = InboxSearch(open: false, query: '', codeOnly: false);

  /// 换关键词。**顺手保证 `open` 为真**：能改关键词就说明搜索框开着，
  /// 不存在「关键词有值但框收起」这种半套状态。
  InboxSearch withQuery(String value) =>
      InboxSearch(open: true, query: value, codeOnly: codeOnly);

  /// 切「只看验证码」。
  InboxSearch toggleCodeOnly() =>
      InboxSearch(open: open, query: query, codeOnly: !codeOnly);

  /// 打开搜索框（保留已有的关键词和开关 —— 用户可能只是把键盘收起来了）。
  InboxSearch opened() =>
      InboxSearch(open: true, query: query, codeOnly: codeOnly);
}
