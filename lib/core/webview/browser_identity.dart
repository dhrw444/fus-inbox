/// 浏览器身份（UA）的随机化。
///
/// 站点在 Cloudflare 后面，会判断「是不是同一个浏览器」：UA 固定、
/// 每次请求特征完全一致、cookie 清不干净，都会让挑战变严。
///
/// 这里提供一批真实存在的 Android Chrome UA，用户主动点
/// 「换浏览器身份」时才换一个，配合清 cookie/缓存，让下一次访问
/// 在站点看来就是新设备。
///
/// 注意：UA 必须对应真实存在的 Chrome 版本。编一个不存在的版本
/// （比如 Chrome/999）比固定 UA 更可疑。
library;

import 'dart:math';

/// 常见 Android 机型。真实的站点指纹会读机型串，
/// 所以要和 UA 里的版本号一起组成看起来正常的组合。
const _deviceModels = <String>[
  'Pixel 7',
  'Pixel 8',
  'SM-S918B',
  'SM-A546E',
  'CPH2451',
  '2201117TY',
  'V2227A',
  'RMX3630',
  'M2101K7AG',
  'LE2121',
];

const _androidVersions = <String>['13', '14', '15'];
const _chromeVersions = <String>[
  '119.0.6045.194',
  '120.0.6099.144',
  '121.0.6167.178',
  '122.0.6261.90',
  '123.0.6312.99',
  '124.0.6367.113',
];

/// 生成一个随机的、真实形态的移动 Chrome UA。
String randomUserAgent([Random? rnd]) {
  final r = rnd ?? Random();
  final model = _deviceModels[r.nextInt(_deviceModels.length)];
  final android = _androidVersions[r.nextInt(_androidVersions.length)];
  final chrome = _chromeVersions[r.nextInt(_chromeVersions.length)];
  return 'Mozilla/5.0 (Linux; Android $android; $model) '
      'AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/$chrome Mobile Safari/537.36';
}

/// 默认 UA。
///
/// 只有在用户主动点「换浏览器身份」时才换。同一台设备在短时间内
/// 反复变 UA 同样可疑，所以平时用这个稳定的。
const _defaultUserAgent =
    'Mozilla/5.0 (Linux; Android 13; K) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';

/// 当前使用的 UA。
///
/// 收件箱的 WebView 和号码目录的原生 HTTP 必须用同一个 UA——
/// 同一台设备对同一站点呈现两种身份，反而是更强的特征。
String _currentUa = _defaultUserAgent;

String get currentUserAgent => _currentUa;

/// 换一个新身份，返回新的 UA。
String rotateUserAgent([Random? rnd]) {
  var next = randomUserAgent(rnd);
  // 极小概率撞上旧值，重摇一次。
  if (next == _currentUa) next = randomUserAgent(rnd);
  _currentUa = next;
  return next;
}
