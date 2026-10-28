/// SOCKS5 协议层自己的异常和 REP 码翻译。
///
/// 单独一个文件而不是塞进 `socks5_client.dart`：握手
/// （`socks5_handshake.dart`）、地址编码（`socks5_address.dart`）、隧道
/// 门面（`socks5_client.dart`）三处都要抛它、翻译它，放在任何一处都会
/// 逼另两处反向依赖。协议词汇就该单独住。
library;

/// SOCKS5 握手失败。
class const SocksException(this.message, {this.replyCode})
    implements Exception {
  final String message;

  /// 服务器回的 REP 字段（RFC 1928 §6）。null 表示没走到那一步。
  final int? replyCode;

  @override
  String toString() =>
      'SocksException($message${replyCode == null ? '' : ', rep=$replyCode'})';
}

/// REP 码翻译。查日志时比看数字有用。
String describeSocksReply(int code) => switch (code) {
  0x00 => '成功',
  0x01 => 'SOCKS 服务器内部错误',
  0x02 => '规则不允许该连接',
  0x03 => '网络不可达',
  0x04 => '主机不可达',
  0x05 => '连接被拒绝',
  0x06 => 'TTL 过期',
  0x07 => '不支持的命令',
  0x08 => '不支持的地址类型',
  _ => '未知错误 0x${code.toRadixString(16)}',
};
