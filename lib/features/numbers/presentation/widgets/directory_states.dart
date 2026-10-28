/// 号码目录的三种「没列表可看」状态：拉失败 / 正在拉 / 拉到了但筛没了。
///
/// 从 `numbers_screen.dart` 的 `_body` 里搬出来的三块 Center(...)。
/// 它们纯展示 + 最多一个回调，留在屏幕里只会把 `_body` 撑成 120 行，
/// 读的时候还要把三种状态的缩进对齐着看。
///
/// 顺序**不能**交换（调用方决定）：加载中必须排在「空」之前 ——
/// 目录还在加载时 `all` 就是空的，先判空会让用户看到「这个筛选下
/// 没有号码」，而事实上只是网络还没回来。
library;

import 'package:material_ui/material_ui.dart';

/// 拉失败，而且手上一条缓存都没有。
class const DirectoryError({
  required this.message,
  required this.theme,
  required this.onRetry,
  super.key,
}) extends StatelessWidget {
  /// 失败原因，一句话（来自 NumberDirectoryState.error）。
  final String message;

  /// 由调用方传入而不是在 build 里取：三种状态共用一个 theme 变量，
  /// 也避免每个状态各自调 Theme.of。
  final ThemeData theme;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.cloud_off,
              size: 40,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 14),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton.tonal(onPressed: onRetry, child: const Text('重试')),
          ],
        ),
      ),
    );
  }
}

/// 首次启动、手上没有任何缓存。
class const DirectoryLoading({
  required this.progress,
  required this.theme,
  super.key,
}) extends StatelessWidget {
  /// 目录分了几页、正在拉第几页。空串表示还没开始。
  final String progress;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text(
            progress.isEmpty ? '正在拉取号码目录…' : progress,
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

/// 有目录、但当前筛选/搜索下没有匹配。
class const DirectoryEmpty({
  required this.query,
  required this.theme,
  super.key,
}) extends StatelessWidget {
  /// 已经 trim 过的搜索词。空串 = 只是筛选芯片太窄。
  final String query;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Text(
          query.isEmpty ? '这个筛选下没有号码。' : '没有匹配「$query」的号码。',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}
