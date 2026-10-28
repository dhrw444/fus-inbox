/// 把目标地址编码成 SOCKS5 的 `ATYP + ADDR`（不含端口）。
///
/// 单独一个文件：解析放本地还是放代理（`socks5h`）是**策略**，编码是
/// **协议**。握手里只该看到「给我地址字节」，不该关心这串字节是查 DNS
/// 查出来的还是原样塞过去的。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fus_inbox/core/proxy/socks5_exception.dart';

/// 编码目标地址。
///
/// [host] 已经是 IP 就直接编码，省一次解析；是域名时看 [resolveRemotely]：
/// true → 按 0x03（域名）原样发给代理，本地不泄漏域名；
/// false → 本地先查一次 DNS，再按 IPv4/IPv6 编码。
Future<Uint8List> encodeSocksAddress(
  String host, {
  required bool resolveRemotely,
}) async {
  // 已经是 IP 就直接用，省一次解析。
  final parsed = InternetAddress.tryParse(host);
  if (parsed != null) {
    return Uint8List.fromList([
      parsed.type == InternetAddressType.IPv6 ? 0x04 : 0x01,
      ...parsed.rawAddress,
    ]);
  }

  if (resolveRemotely) {
    final bytes = utf8.encode(host);
    if (bytes.length > 255) {
      throw const SocksException('域名超过 255 字节');
    }
    return Uint8List.fromList([0x03, bytes.length, ...bytes]);
  }

  final resolved = await InternetAddress.lookup(host);
  if (resolved.isEmpty) {
    throw SocksException('本地解析不到 $host');
  }
  final addr = resolved.first;
  return Uint8List.fromList([
    addr.type == InternetAddressType.IPv6 ? 0x04 : 0x01,
    ...addr.rawAddress,
  ]);
}
