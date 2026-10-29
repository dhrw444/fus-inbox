/// 一条代理配置：写法解析、序列化、稳定 id 派生。
///
/// ## 为什么需要这一层
///
/// 站点的配额记在**出口 IP** 上，不在号码、也不在浏览器身份上。实测：
/// 同一个 IP 上把 localStorage / IndexedDB / cookie 全清空（等于一个全新
/// 身份）之后，第 4 个号依然是 `New inboxes are on pause`。反过来，同一个
/// 身份换一个 IP 就又能读。
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
///
/// 末尾的 `()` 是**主构造器的空标记**：本仓统一用它（见 `class const X(...)`
/// 那批），加上它就等于声明「没有构造参数」。
enum ProxyScheme() {
  /// SOCKS5，DNS 在本地解析。
  socks5,

  /// SOCKS5，DNS 交给代理解析（`socks5h`）。
  ///
  /// 比 [socks5] 好一点：本地不泄漏要访问的域名，也不受本地 DNS 污染影响。
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
  /// 用 `scheme://host:port` 派生（见 [buildProxyId]），改密码不会换绑定的
  /// 身份 —— 同一个出口 IP 换了密码，站点眼里还是同一个访客。
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
  /// 密码绝不能进日志、进界面、进提交信息。这里只露长度，够用户确认
  /// 「填了」或「没填」。没有用户名时连 `@` 都不写 —— `socks5://:pw@h:1`
  /// 那种形态不是合法写法。
  String get masked {
    final auth = username.isEmpty
        ? ''
        : '$username${password.isEmpty ? '' : ':${'•' * password.length}@'}';
    return '${scheme.name}://$auth$host:$port';
  }

  /// 是否是 SOCKS5 家族（需要在 App 内做本地 HTTP 桥）。
  ///
  /// 判据是「这条代理要不要经过本地桥」，不是「WebView 支不支持 socks」。
  ///
  /// 桥存在的理由：官方 `ProxyConfig` 的规则串语法是
  /// `[scheme://]host[:port]`，scheme 可为 HTTP / HTTPS / **SOCKS** ——
  /// 也就是说 WebView 未必走不了 socks。真正过不去的是**认证**：规则串里
  /// 没有 userinfo 位，而内置的代理全部带账号密码。
  /// （旧注释写的是「ProxyController 只支持 HTTP/HTTPS」，那是错的，
  /// 详见 `local_http_bridge.dart` 文件头。）
  ///
  /// 所以 socks5 要先在本机起一个 HTTP 代理，把 CONNECT 转成 SOCKS5 握手
  /// 再发出去。
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

  /// 从存储里还原。字段缺失就用安全默认值 —— 一条配置坏了不该让整个
  /// 代理池读不出来。host 空、端口越界这两类返回 null（连都连不上，
  /// 留着只会让 UI 显示一条永远失败的代理）。
  static ProxyConfig? fromJson(Map<String, Object?> json) {
    final host = (json['host'] as String?)?.trim() ?? '';
    if (host.isEmpty) return null;
    final schemeName = json['scheme'];
    final scheme = ProxyScheme.values.firstWhere(
      (s) => s.name == schemeName,
      orElse: () => ProxyScheme.socks5,
    );
    final port = (json['port'] as num?)?.toInt() ?? defaultPort(scheme);
    if (!_portInRange(port)) return null;
    final rawId = (json['id'] as String?)?.trim() ?? '';
    return ProxyConfig(
      id: rawId.isNotEmpty ? rawId : buildProxyId(scheme, host, port),
      scheme: scheme,
      host: host,
      port: port,
      username: (json['username'] as String?) ?? '',
      password: (json['password'] as String?) ?? '',
      label: (json['label'] as String?) ?? '',
    );
  }
}

/// 各协议默认端口。`direct` 没有端口，给 0 让上层一眼看出「这不是地址」。
int defaultPort(ProxyScheme scheme) => switch (scheme) {
  ProxyScheme.socks5 || ProxyScheme.socks5h => 1080,
  ProxyScheme.http => 8080,
  ProxyScheme.https => 443,
  ProxyScheme.direct => 0,
};

bool _portInRange(int port) => port > 0 && port <= 65535;

/// 派生稳定 id。
///
/// 刻意**不含**账号密码：同一个出口换了凭据还是同一个 IP，应该继续用同一
/// 个浏览器身份，否则等于白白重置一次。
String buildProxyId(ProxyScheme scheme, String host, int port) =>
    '${scheme.name}://$host:$port';

/// 解析用户输入的一行代理。
///
/// 宽容优先：手输代理的人经常漏协议、漏端口、带多余空格。
/// 认不出来就返回 null，由界面提示，不做「猜一个试试」—— 猜错会连到一个
/// 不相干的代理上，比直接报错更难查。
ProxyConfig? parseProxyLine(String raw, {String label = ''}) {
  var text = raw.trim();
  if (text.isEmpty) return null;

  // 允许直接粘整段带空格的，取第一段。
  if (text.contains(RegExp(r'\s'))) {
    text = text.split(RegExp(r'\s+')).first;
  }

  var scheme = ProxyScheme.socks5;
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

  final String host;
  var port = defaultPort(scheme);

  // IPv6 形如 [::1]:1080
  final v6 = RegExp(r'^\[([^\]]+)\](?::(\d+))?$').firstMatch(rest);
  if (v6 != null) {
    host = v6.group(1)!;
    port = int.tryParse(v6.group(2) ?? '') ?? port;
  } else {
    final colon = rest.lastIndexOf(':');
    // 冒号在最前面说明 host 是空的（`socks5://:1080`），直接拒。
    if (colon == 0) return null;
    // 只有一个冒号才算 host:port；多个冒号是没加方括号的 IPv6，整段当 host。
    if (colon > 0 && !rest.substring(0, colon).contains(':')) {
      host = rest.substring(0, colon);
      port = int.tryParse(rest.substring(colon + 1)) ?? port;
    } else {
      host = rest;
    }
  }

  final cleanHost = host.trim();
  if (cleanHost.isEmpty) return null;
  if (!_portInRange(port)) return null;

  return ProxyConfig(
    id: buildProxyId(scheme, cleanHost, port),
    scheme: scheme,
    host: cleanHost,
    port: port,
    username: username,
    password: password,
    label: label,
  );
}

/// 百分号解码。代理凭据里常见 `p%40ss` 这种写法。
///
/// 解不开就原样返回：一段坏编码不该让整行代理变成 null，用户拿到的凭据
/// 顶多是「按字面发了」，还能自己看出来。
String _decode(String s) {
  if (!s.contains('%')) return s;
  try {
    return Uri.decodeComponent(s);
  } on ArgumentError {
    return s;
  } on FormatException {
    return s;
  }
}
