/// 代理清单的折叠/分页列表。
///
/// 从 `proxy_section.dart` 搬出来 —— 那一块自带**展开/收起**状态
/// （`_expanded` / `_visible`），和上面那些纯开关不是一回事：留在
/// Section 里会让「加一条代理」和「翻页看代理」在同一份 State 里搅着。
///
/// 为什么要折叠：内置代理有近 600 条，一次性全建出来每次进设置页都卡。
/// 短列表（≤ [_pageSize]）不折 —— 一次全铺开，不给用户增加点击。
library;

import 'package:fus_inbox/core/proxy/proxy_config.dart';
import 'package:fus_inbox/core/proxy/proxy_state.dart';
import 'package:fus_inbox/features/settings/presentation/proxy/proxy_cards.dart';
import 'package:material_ui/material_ui.dart';

/// 代理清单本体：短列表直接铺开，长列表默认收起、按页放出。
class const ProxyList({
  required this.all,
  required this.state,
  required this.onUse,
  required this.onRemove,
  super.key,
}) extends StatefulWidget {
  final List<ProxyConfig> all;
  final ProxyState state;
  final void Function(String id) onUse;
  final void Function(String id) onRemove;

  @override
  State<ProxyList> createState() => _ProxyListState();
}

class _ProxyListState() extends State<ProxyList> {
  /// 展开后一页放多少条。点一次「再显示」就加这么多。
  static const int _pageSize = 100;

  /// 用户点过「展开显示」没有。
  ///
  /// 只有列表长过一页时才需要它 —— 短列表照旧直接铺开，不让用户
  /// 为了看三条代理多点一下。
  bool _expanded = false;

  /// 展开状态下当前放出多少条。
  int _visible = _pageSize;

  /// 代理列表。长列表默认收起，展开后一次放出 [_pageSize] 条。
  ///
  /// 之前这里是 `...all.map(...)` —— 589 个 ListTile 一次性全建出来，
  /// 每次进设置页都卡。现在按需放：没展开就只显示前 [_pageSize] 条，
  /// 点「再显示」再加一百。
  List<Widget> _rows() {
    final all = widget.all;

    // 短列表没必要折叠 —— 一次全铺开，不给用户增加点击。
    if (all.length <= _pageSize) {
      return all.map(_row).toList(growable: false);
    }

    if (!_expanded) {
      // 收起时把「当前正在用的那条」留在外面 —— 否则用户一眼看过去
      // 一条代理都没有，会以为配置丢了。其余的收进按钮后面。
      final active = widget.state.current;
      return [
        if (active != null) _row(active),
        _expandButton(
          onPressed: () => setState(() {
            _expanded = true;
            _visible = _pageSize;
          }),
          label: active == null
              ? '展开显示（共 ${all.length} 条）'
              : '展开显示全部 ${all.length} 条',
          icon: Icons.expand_more,
        ),
      ];
    }

    final shown = _visible < all.length ? _visible : all.length;
    final rows = <Widget>[for (final p in all.take(shown)) _row(p)];

    if (shown < all.length) {
      final rest = all.length - shown;
      final step = rest < _pageSize ? rest : _pageSize;
      rows.add(
        _expandButton(
          onPressed: () => setState(() => _visible += _pageSize),
          label: rest <= _pageSize ? '显示剩下 $rest 条' : '再显示 $step 条（还有 $rest 条）',
          icon: Icons.expand_more,
        ),
      );
    }

    rows.add(
      _expandButton(
        onPressed: () => setState(() {
          _expanded = false;
          _visible = _pageSize;
        }),
        label: '收起',
        icon: Icons.expand_less,
        outlined: false,
      ),
    );

    return rows;
  }

  Widget _expandButton({
    required VoidCallback onPressed,
    required String label,
    required IconData icon,
    bool outlined = true,
  }) {
    // 「收起」是 TextButton（更轻），展开键是 OutlinedButton ——
    // 保留这个区别：收起不是主路径，不该和「再显示」一样显眼。
    final label0 = Text(label);
    final icon0 = Icon(icon, size: 18);
    final button = outlined
        ? OutlinedButton.icon(onPressed: onPressed, icon: icon0, label: label0)
        : TextButton.icon(onPressed: onPressed, icon: icon0, label: label0);
    return Padding(
      padding: EdgeInsets.only(top: outlined ? 4 : 2),
      child: SizedBox(width: double.infinity, child: button),
    );
  }

  Widget _row(ProxyConfig p) {
    final state = widget.state;
    final ledger = state.ledger;
    return ProxyRow(
      key: ValueKey(p.id),
      proxy: p,
      active: p.id == state.currentId,
      used: ledger.usedFor(p.id),
      maxPer: ledger.maxPerIdentity,
      probe: state.results[p.id],
      onUse: () => widget.onUse(p.id),
      onRemove: () => widget.onRemove(p.id),
    );
  }

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: _rows(),
  );
}
