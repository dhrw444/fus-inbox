/// 在单订阅 socket 上「先按需读定长、之后切成整块转发」。
///
/// `Socket` 是**单订阅流**，`listen` 只能来一次，而代理链路的两段读法
/// 不一样：SOCKS5 握手要**读定长**（问候回复 2 字节、地址长度 1 字节…），
/// 握手之后的流量要**原样转发**。中途 `cancel` 再 `listen` 是不可能的，
/// 所以这里始终只订阅一次 —— 前段把数据攒进缓冲供 [read] / [readUntil]
/// 切，[forward] 之后新数据直接进 [incoming] 给上层。
///
/// 为什么不是「协商一份、桥里再一份」：两份的差别只在「攒到什么时候算
/// 读完」，那是同一个机制的两个入口；拆成两份必然一份有背压、一份没有。
///
/// 背压：[incoming] 的 `onPause` / `onResume` 映射到 socket 订阅，所以
/// 上层暂停时会**真的**对 TCP 施加背压，而不是无限缓冲。
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

/// 读 socket 时的失败（超时、断开、超长）。协议层的错误另有类型。
class const SocketReadException(this.message) implements Exception {
  final String message;

  @override
  String toString() => message;
}

class SocketReader {
  // 控制器必须在构造体里建：它的 onPause/onResume 要引用 _sub，
  // 而字段初始化器里读不到 this。
  // ignore: use_primary_constructors
  SocketReader(Socket socket) {
    _out = StreamController<Uint8List>(
      sync: true,
      onPause: () => _sub.pause(),
      onResume: () => _sub.resume(),
    );
    _sub = socket.listen(
      (chunk) {
        if (_forwarding) {
          _out.add(chunk);
          return;
        }
        _buffer.addAll(chunk);
        _pump();
      },
      onError: _fail,
      onDone: _finish,
      cancelOnError: false,
    );
  }

  /// 转发用。`onPause` / `onResume` 映射到 socket 订阅，让上层能真的
  /// 对 TCP 施加背压。
  late final StreamController<Uint8List> _out;
  late final StreamSubscription<Uint8List> _sub;

  final List<int> _buffer = [];
  Completer<Uint8List>? _waiting;
  int _wanted = 0;
  Object? _error;
  bool _forwarding = false;
  bool _closed = false;

  /// 读头阶段之后的字节流（已含缓冲区里剩下的）。
  Stream<Uint8List> get incoming => _out.stream;

  /// 从缓冲头部取走 [n] 字节。两个读入口共用，避免切片逻辑写两遍。
  Uint8List _take(int n) {
    final out = Uint8List.fromList(_buffer.sublist(0, n));
    _buffer.removeRange(0, n);
    return out;
  }

  void _pump() {
    final w = _waiting;
    if (w == null || _buffer.length < _wanted) return;
    final n = _wanted;
    _waiting = null;
    w.complete(_take(n));
  }

  void _fail(Object e) {
    _error = e;
    final w = _waiting;
    if (w != null && !w.isCompleted) {
      _waiting = null;
      w.completeError(e);
    }
    // 没人监听时塞 error 只会进缓冲，等 close 之后变成「未处理的异步
    // 错误」，把整个 App 的 zone 打红。
    if (!_out.isClosed && _out.hasListener) _out.addError(e);
  }

  void _finish() {
    _closed = true;
    final w = _waiting;
    if (w != null && !w.isCompleted) {
      _waiting = null;
      w.completeError(const SocketReadException('对端在读取途中断开'));
    }
    if (!_out.isClosed) _out.close();
  }

  /// 读满 [n] 字节。超时抛 [SocketReadException]。
  Future<Uint8List> read(
    int n, {
    required Duration timeout,
    String timeoutMessage = '读取超时',
  }) {
    if (_closed) return Future.error(const SocketReadException('连接已断开'));
    final err = _error;
    if (err != null) return Future.error(err);
    if (_buffer.length >= n) return Future.value(_take(n));
    final c = Completer<Uint8List>();
    _waiting = c;
    _wanted = n;
    // 超时要主动失败，否则这条连接一直挂着占 fd。
    return c.future.timeout(
      timeout,
      onTimeout: () {
        _waiting = null;
        throw SocketReadException(timeoutMessage);
      },
    );
  }

  /// 一直读到 [delimiter] 出现为止，返回**不含分隔符**的部分。
  ///
  /// 出现以下任一情况返回 null（调用方按「读头失败」处理，一律关连接）：
  /// 超时、连接已断、已出错、缓冲超过 [maxBytes] 还没见到分隔符
  /// （对面在灌垃圾，不能无上限地往缓冲里堆）。
  Future<Uint8List?> readUntil(
    List<int> delimiter, {
    required Duration timeout,
    int maxBytes = 64 * 1024,
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (true) {
      if (_closed || _error != null) return null;
      final idx = _indexOf(delimiter);
      if (idx >= 0) {
        final out = _take(idx);
        _buffer.removeRange(0, delimiter.length);
        return out;
      }
      if (_buffer.length > maxBytes) {
        _buffer.clear();
        return null;
      }
      final remain = deadline.difference(DateTime.now());
      if (remain <= Duration.zero) return null;
      // 数据由 listen 回调推进，这里只是让出事件循环。5ms 是轮询粒度，
      // 比它更长的剩余时间不必等满。
      await Future<void>.delayed(
        remain < const Duration(milliseconds: 5)
            ? remain
            : const Duration(milliseconds: 5),
      );
    }
  }

  int _indexOf(List<int> needle) {
    final last = _buffer.length - needle.length;
    for (var i = 0; i <= last; i++) {
      var hit = true;
      for (var j = 0; j < needle.length; j++) {
        if (_buffer[i + j] != needle[j]) {
          hit = false;
          break;
        }
      }
      if (hit) return i;
    }
    return -1;
  }

  /// 取走缓冲里还没消费的字节。
  ///
  /// 必须在 [forward] 之前调 —— [forward] 之后新数据直接进 [incoming]，
  /// 缓冲里那截要靠 [forward] 自己补发。
  Uint8List takeBuffer() {
    final out = Uint8List.fromList(_buffer);
    _buffer.clear();
    return out;
  }

  /// 切到转发模式：之后的数据走 [incoming]。
  ///
  /// 缓冲里剩下的字节会先补发一次 —— 目标服务器有可能在 CONNECT 响应的
  /// 同一批数据里就开始发内容，丢掉就是「隧道通了但第一屏是空的」。
  void forward() {
    if (_forwarding) return;
    _forwarding = true;
    if (_buffer.isNotEmpty) {
      final rest = Uint8List.fromList(_buffer);
      _buffer.clear();
      _out.add(rest);
    }
    if (_closed && !_out.isClosed) _out.close();
  }

  Future<void> close() async {
    _forwarding = true;
    _closed = true;
    await _sub.cancel();
    // ⚠️ 不能 `await _out.close()`。
    //
    // `StreamController.close()` 返回的 done future 要等**监听者把事件
    // 消费完**才完成。握手失败时上层从来没 listen 过 `_out`，这个 future
    // 就永远不完成 —— 整个 open() 的 catch 挂死，表现为「代理连不上时
    // App 卡住」。实测踩过一次。
    if (!_out.isClosed) unawaited(_out.close());
  }
}
