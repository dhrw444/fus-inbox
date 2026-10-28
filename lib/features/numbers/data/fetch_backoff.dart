/// 号码目录的退避重试。
///
/// ## 为什么单独拆一个文件
///
/// 从 `numbers_repository.dart` 拆出来：那边管「用什么出口、怎么并发」，
/// 这里只管「一次失败之后等多久再来」。两者的取舍完全不同 —— 并发数调的是
/// 速度与「像不像爆破」，退避调的是「风控是不是临时抖动」。挤在一个方法里
/// 时，改退避曲线要动一段夹在 `Future.wait` 和连接池注释之间的代码。
///
/// ## 为什么是短退避，不是指数炸弹
///
/// 真正的风控拒绝会持续返回 403/429，等 30 秒也救不回来；偶发的网络抖动
/// 则是重试越早越好。所以窗口就两条：600ms / 1.5s，总共三次机会。
///
/// ## 为什么不只 catch 自定义异常
///
/// 连接重置、超时、TLS 握手失败都是 `SocketException` / `HandshakeException`，
/// 它们不是 [NumberFetchException] 的子类。只 catch 自定义异常的话，这些
/// 会穿透整个 `fetchAll`，一次抖动就把已经抓到的几页全丢了。
library;

/// 一次抓取最多试几次（含首次）。
const directoryMaxAttempts = 3;

/// 每次重试前的等待（毫秒）。第 N 次重试取第 N-1 项，不够就复用最后一项。
const directoryRetryDelaysMs = <int>[600, 1500];

/// 带退避地跑 [op]，全部失败返回 null。
///
/// [onGiveUp] 在彻底放弃时收到最后一次的错误 —— 日志归调用方打，这样
/// 这个文件不用知道「第几页、哪个站点」。
///
/// **返回 null 而不是抛异常**：调用方（`fetchAll`）的语义是「这一页没救了，
/// 继续抓别的页」，而不是整条链路失败。
Future<T?> withBackoff<T>(
  Future<T> Function() op, {
  int maxAttempts = directoryMaxAttempts,
  List<int> delaysMs = directoryRetryDelaysMs,
  void Function(Object error)? onGiveUp,
}) async {
  Object? last;
  for (var attempt = 0; attempt < maxAttempts; attempt++) {
    try {
      return await op();
    } on Object catch (e) {
      last = e;
      if (attempt < maxAttempts - 1) {
        final i = attempt < delaysMs.length ? attempt : delaysMs.length - 1;
        await Future<void>.delayed(Duration(milliseconds: delaysMs[i]));
      }
    }
  }
  if (last != null) onGiveUp?.call(last);
  return null;
}
