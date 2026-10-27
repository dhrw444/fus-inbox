/// 一条代理配置。
///
/// ## 为什么需要
///
/// 站点的配额记在**出口 IP** 上，不在号码、也不在浏览器身份上。
/// 实测：同一个 IP 上把 localStorage / IndexedDB / cookie 全清空
/// （等于一个全新身份）之后，第 4 个号依然是 `New inboxes are on pause`。
/// 反过来，同一个身份换一个 IP 就又能读。
///
/// 所以「一直能用」只有一条路：**换 IP**。代理就是换 IP 的手段。
///
/// ## 支持的写法
///
/// ```
/// socks5://user:pass@1.2.3.4:1080
/// socks5h://1.2.3.4:1080          （h = 让代理做 DNS 解析）
/// http://user:pass@1.2.3.4:8080
/// https://1.2.3.4:443
/// 1.2.3.4:1080                    （省略协议，按 socks5 处理）
/// ```
///
/// 端口可省，按协议默认：socks5 → 1080，http → 8080，https → 443。
library;

/// 代理协议。
enum ProxyScheme {
  /// SOCKS5，DNS 在本地解析。
  socks5,

  /// SOCKS5，DNS 交给代理解析（`socks5h`）。
  ///
  /// 比 [socks5] 好一点：本地不泄漏要访问的域名，
  /// 而且不受本地 DNS 污染影响。
  socks5h,

  http,

  https,

  /// 直连。不放进代理池 —— 池子里只有用户真配的代理。
  /// 这个只用于「一个代理都没配」时的占位，让上层逻辑不用分叉。
  direct,
}

/// 一条代理。
class const ProxyConfig({
  required this.id,
  required this.scheme,
  required this.host,
  required this.port,
  this.username = '',
  this.password = '',
  this.label = '',
}) {
  /// 稳定标识，用来绑定浏览器身份。
  ///
  /// 用 `scheme://host:port` 派生，改密码不会换绑定的身份 ——
  /// 同一个出口 IP 换了密码，站点眼里还是同一个访客。
  final String id;

  final ProxyScheme scheme;
  final String host;
  final int port;
  final String username;
  final String password;

  /// 用户自己起的备注，如「HK-1」「美国机房」。
  final String label;

  /// 界面上显示的名字。备注优先，否则 host:port。
  String get displayName => label.isNotEmpty ? label : '$host:$port';

  /// 有账号密码时为 true。
  bool get hasAuth => username.isNotEmpty || password.isNotEmpty;

  /// 给用户看的完整形态（密码打码）。
  ///
  /// 密码绝不能进日志、进界面、进提交信息。这里只露长度，
  /// 够用户确认「填了」或「没填」。
  String get masked {
    final auth = username.isEmpty
        ? ''
        : '$username${password.isEmpty ? '' : ':${'•' * password.length}@'}';
    return '${scheme.name}://$auth$host:$port';
  }

  /// 是否是 SOCKS5 家族（需要在 App 内做本地 HTTP 桥）。
  ///
  /// Android WebView 的 `ProxyController` **只支持 HTTP/HTTPS 代理**，
  /// 传 socks 进去会被系统忽略。所以 socks5 必须先在本机起一个
  /// HTTP 代理，把 CONNECT 转成 SOCKS5 握手再发出去。
  bool get needsBridge =>
      scheme == ProxyScheme.socks5 || scheme == ProxyScheme.socks5h;

  /// 是否是直连占位。
  bool get isDirectProxy => scheme == ProxyScheme.direct;

  Map<String, Object?> toJson() => {
    'id': id,
    'scheme': scheme.name,
    'host': host,
    'port': port,
    'username': username,
    'password': password,
    'label': label,
  };

  /// 从存储里还原。字段缺失就用安全默认值 ——
  /// 一条配置坏了不该让整个代理池读不出来。
  static ProxyConfig? fromJson(Map<String, Object?> json) {
    final host = (json['host'] as String?)?.trim() ?? '';
    if (host.isEmpty) return null;
    final scheme = ProxyScheme.values.firstWhere(
      (s) => s.name == json['scheme'],
      orElse: () => ProxyScheme.socks5,
    );
    final port = (json['port'] as num?)?.toInt() ?? _defaultPort(scheme);
    if (port <= 0 || port > 65535) return null;
    return ProxyConfig(
      id: (json['id'] as String?)?.trim().isNotEmpty == true
          ? json['id'] as String
          : buildProxyId(scheme, host, port),
      scheme: scheme,
      host: host,
      port: port,
      username: (json['username'] as String?) ?? '',
      password: (json['password'] as String?) ?? '',
      label: (json['label'] as String?) ?? '',
    );
  }
}

/// 各协议默认端口。
int _defaultPort(ProxyScheme scheme) => switch (scheme) {
  ProxyScheme.socks5 || ProxyScheme.socks5h => 1080,
  ProxyScheme.http => 8080,
  ProxyScheme.https => 443,
  ProxyScheme.direct => 0,
};

/// 派生稳定 id。
///
/// 刻意**不含**账号密码：同一个出口换了凭据还是同一个 IP，
/// 应该继续用同一个浏览器身份，否则等于白白重置一次。
String buildProxyId(ProxyScheme scheme, String host, int port) =>
    '${scheme.name}://$host:$port';

/// 解析用户输入的一行代理。
///
/// 宽容优先：手输代理的人经常漏协议、漏端口、带多余空格。
/// 认不出来就返回 null，由界面提示，不做「猜一个试试」——
/// 猜错会连到一个不相干的代理上，比直接报错更难查。
ProxyConfig? parseProxyLine(String raw, {String label = ''}) {
  var text = raw.trim();
  if (text.isEmpty) return null;

  // 允许直接粘整段带空格的，取第一段。
  if (text.contains(RegExp(r'\s'))) {
    text = text.split(RegExp(r'\s+')).first;
  }

  ProxyScheme scheme = ProxyScheme.socks5;
  var rest = text;

  final schemeMatch = RegExp(
    r'^(socks5h|socks5|https|http)://',
    caseSensitive: false,
  ).firstMatch(text);
  if (schemeMatch != null) {
    scheme = switch (schemeMatch.group(1)!.toLowerCase()) {
      'socks5h' => ProxyScheme.socks5h,
      'socks5' => ProxyScheme.socks5,
      'https' => ProxyScheme.https,
      _ => ProxyScheme.http,
    };
    rest = text.substring(schemeMatch.end);
  }

  // 去掉尾部路径/查询（有人会把代理后台的复制链接整段粘进来）。
  rest = rest.split(RegExp(r'[/?#]')).first;
  if (rest.isEmpty) return null;

  var username = '';
  var password = '';
  final at = rest.lastIndexOf('@');
  if (at >= 0) {
    final auth = rest.substring(0, at);
    rest = rest.substring(at + 1);
    final colon = auth.indexOf(':');
    if (colon >= 0) {
      username = _decode(auth.substring(0, colon));
      password = _decode(auth.substring(colon + 1));
    } else {
      username = _decode(auth);
    }
  }

  if (rest.isEmpty) return null;

  String host;
  var port = _defaultPort(scheme);

  // IPv6 形如 [::1]:1080
  final v6 = RegExp(r'^\[([^\]]+)\](?::(\d+))?$').firstMatch(rest);
  if (v6 != null) {
    host = v6.group(1)!;
    final p = int.tryParse(v6.group(2) ?? '');
    if (p != null) port = p;
  } else {
    final colon = rest.lastIndexOf(':');
    // 冒号在最前面说明 host 是空的（`socks5://:1080`），直接拒。
    if (colon == 0) return null;
    // 只有一个冒号才算 host:port；多个冒号是没加方括号的 IPv6，整段当 host。
    if (colon > 0 && !rest.substring(0, colon).contains(':')) {
      host = rest.substring(0, colon);
      final p = int.tryParse(rest.substring(colon + 1));
      if (p != null) port = p;
    } else {
      host = rest;
    }
  }

  host = host.trim();
  if (host.isEmpty) return null;
  if (port <= 0 || port > 65535) return null;

  return ProxyConfig(
    id: buildProxyId(scheme, host, port),
    scheme: scheme,
    host: host,
    port: port,
    username: username,
    password: password,
    label: label,
  );
}

/// 百分号解码。代理凭据里常见 `p%40ss` 这种写法。
String _decode(String s) {
  if (!s.contains('%')) return s;
  try {
    return Uri.decodeComponent(s);
  } catch (_) {
    return s;
  }
}
