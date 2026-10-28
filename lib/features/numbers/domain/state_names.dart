/// 美国州名中英对照。
///
/// 站点目录里的州名是英文（`data-state` 与卡片标题都直接用站点原文），
/// 界面全中文，这里做一次映射。查不到的原样返回，不会因为站点新增州而崩。
///
/// 顺便带上中文简称：`Georgia` 单独看像人名，`佐治亚` 才像个地名。
library;

/// 全量州名表。按字母序排，好对账。
const _states = <String, String>{
  'Alabama': '阿拉巴马',
  'Alaska': '阿拉斯加',
  'Arizona': '亚利桑那',
  'Arkansas': '阿肯色',
  'California': '加利福尼亚',
  'Colorado': '科罗拉多',
  'Connecticut': '康涅狄格',
  'Delaware': '特拉华',
  'Florida': '佛罗里达',
  'Georgia': '佐治亚',
  'Hawaii': '夏威夷',
  'Idaho': '爱达荷',
  'Illinois': '伊利诺伊',
  'Indiana': '印第安纳',
  'Iowa': '艾奥瓦',
  'Kansas': '堪萨斯',
  'Kentucky': '肯塔基',
  'Louisiana': '路易斯安那',
  'Maine': '缅因',
  'Maryland': '马里兰',
  'Massachusetts': '马萨诸塞',
  'Michigan': '密歇根',
  'Minnesota': '明尼苏达',
  'Mississippi': '密西西比',
  'Missouri': '密苏里',
  'Montana': '蒙大拿',
  'Nebraska': '内布拉斯加',
  'Nevada': '内华达',
  'New Hampshire': '新罕布什尔',
  'New Jersey': '新泽西',
  'New Mexico': '新墨西哥',
  'New York': '纽约',
  'North Carolina': '北卡罗来纳',
  'North Dakota': '北达科他',
  'Ohio': '俄亥俄',
  'Oklahoma': '俄克拉何马',
  'Oregon': '俄勒冈',
  'Pennsylvania': '宾夕法尼亚',
  'Rhode Island': '罗得岛',
  'South Carolina': '南卡罗来纳',
  'South Dakota': '南达科他',
  'Tennessee': '田纳西',
  'Texas': '得克萨斯',
  'Utah': '犹他',
  'Vermont': '佛蒙特',
  'Virginia': '弗吉尼亚',
  'Washington': '华盛顿',
  'West Virginia': '西弗吉尼亚',
  'Wisconsin': '威斯康星',
  'Wyoming': '怀俄明',
};

/// 州名转中文。未知州名原样返回。
///
/// 站点偶尔给出小写或带空白的值，先归一化再查表；精确未中时再兜一次
/// 大小写（O(N) 只在 miss 时发生，O(1) 是主路径）。
String stateZh(String state) {
  final k = state.trim();
  if (k.isEmpty) return '';
  final hit = _states[k];
  if (hit != null) return hit;
  for (final e in _states.entries) {
    if (e.key.toLowerCase() == k.toLowerCase()) return e.value;
  }
  return k;
}
