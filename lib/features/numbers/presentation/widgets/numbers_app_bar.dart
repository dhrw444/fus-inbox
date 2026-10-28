/// 号码页顶栏：标题 / 搜索框，右边搜索、排序、刷新。
///
/// 从 `numbers_screen.dart` 的 `build` 搬出来。它只认识
/// [NumberSort] 和几个回调 —— 不知道目录怎么加载、搜索词存在哪，
/// 所以搬出来不需要带任何状态走。
library;

import 'package:fus_inbox/features/numbers/domain/number_sort.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fus_inbox/core/widgets/app_bar_search_field.dart';

class const NumbersAppBar({
  required this.searching,
  required this.controller,
  required this.sort,
  required this.loading,
  required this.onQuery,
  required this.onOpenSearch,
  required this.onCloseSearch,
  required this.onSort,
  required this.onRefresh,
  super.key,
}) extends StatelessWidget implements PreferredSizeWidget {
  /// 搜索框展开了没有。展开时标题位置变输入框，动作栏只剩「关闭」。
  final bool searching;

  /// 搜索输入框的控制器。归页面持有（页面还要在关闭时清它）。
  final TextEditingController controller;

  /// 当前排序。弹出菜单用它标出选中项。
  final NumberSort sort;

  /// 正在拉目录。拉的时候刷新键置灰，避免叠两个请求。
  final bool loading;

  final void Function(String query) onQuery;
  final VoidCallback onOpenSearch;
  final VoidCallback onCloseSearch;
  final void Function(NumberSort sort) onSort;
  final VoidCallback onRefresh;

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    return AppBar(
      title: searching
          ? AppBarSearchField(
              controller: controller,
              hintText: '号码 / 区号 / 州，例如 419、Ohio',
              onChanged: onQuery,
            )
          : const Text('接码号码'),
      actions: [
        if (searching)
          IconButton(
            tooltip: '关闭搜索',
            onPressed: onCloseSearch,
            icon: const Icon(Icons.close),
          )
        else ...[
          IconButton(
            tooltip: '搜索',
            onPressed: onOpenSearch,
            icon: const Icon(Icons.search),
          ),
          PopupMenuButton<NumberSort>(
            tooltip: '排序',
            initialValue: sort,
            onSelected: onSort,
            itemBuilder: (context) => [
              for (final s in NumberSort.values)
                PopupMenuItem<NumberSort>(value: s, child: Text(s.label)),
            ],
            icon: const Icon(Icons.sort),
          ),
          IconButton(
            tooltip: '刷新目录',
            onPressed: loading ? null : onRefresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ],
    );
  }
}
