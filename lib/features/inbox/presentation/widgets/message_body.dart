/// 一条短信的正文区：原文 / 译文 / 翻译中的转圈，以及「保留原文」那一段。
///
/// ## 为什么从 `message_tile.dart` 里拆出来
///
/// 那边是「卡片外壳 + 顶栏 + 验证码按钮」，这里是「正文怎么摆」。两者
/// 之间只有一个接口：[TranslationEntry] 和三个展示参数 —— 而正文这块
/// 有四种状态（加载中 / 有译文 / 有译文且要留原文 / 没译文），以前这四种
/// 分支夹在卡片的 Column 中间，读卡片版式得先跳过一大段翻译判断。
///
/// 拆成 [MessageBody] 之后它是**纯展示**：不认识 provider、不认识 widget
/// 生命周期，喂进去什么就画什么。翻译请求（什么时候踢、要不要补一次）
/// 仍归卡片 —— 那是生命周期的事，不是排版的事。
library;

import 'package:fus_inbox/core/translate/translation_provider.dart';
import 'package:material_ui/material_ui.dart';

/// 正文字体样式，按设置里的缩放倍数调整。
///
/// 只缩放 fontSize，不动 height：行高是相对字号的比例，
/// 跟着字号走的话大字号会变成一大片空白。这里固定行高雅一点。
TextStyle? bodyStyle(ThemeData theme, double scale) {
  final base = theme.textTheme.bodyMedium;
  if (base == null) return null;
  final size = (base.fontSize ?? 14) * scale;
  return base.copyWith(fontSize: size, height: 1.45);
}

/// 译文和原文是否实质相同。
///
/// 站点偶尔返回「翻译后跟原来一样」的结果（专有名词、已是中文等），
/// 这种情况下再显示一遍原文只会让卡片变高、没有信息增量。
bool sameText(String a, String b) =>
    a.trim().toLowerCase() == b.trim().toLowerCase();

/// 正文区。
///
/// [entry] 为空 = 没开翻译或还没拿到条目，直接画原文。
class const MessageBody({
  required this.text,
  required this.entry,
  required this.theme,
  required this.fontScale,
  required this.showOriginal,
  super.key,
}) extends StatelessWidget {
  final String text;
  final TranslationEntry? entry;
  final ThemeData theme;
  final double fontScale;

  /// 有译文时是否在下面保留原文。
  final bool showOriginal;

  @override
  Widget build(BuildContext context) {
    final scheme = theme.colorScheme;
    final e = entry;

    if (e != null && e.loading) {
      return Row(
        children: [
          SizedBox(
            width: 11,
            height: 11,
            child: CircularProgressIndicator(
              strokeWidth: 1.6,
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 7),
          Text(
            '翻译中…',
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      );
    }

    if (e != null && e.text.isNotEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            e.text,
            style: bodyStyle(theme, fontScale),
            maxLines: 10,
            overflow: TextOverflow.ellipsis,
          ),
          // 打开「保留原文」时才显示下面这段，否则卡片只是更高。
          if (showOriginal && !sameText(e.text, text))
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                text,
                style: bodyStyle(
                  theme,
                  fontScale * 0.88,
                )?.copyWith(color: scheme.onSurfaceVariant),
                maxLines: 6,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
      );
    }

    return Text(
      text,
      style: bodyStyle(theme, fontScale),
      maxLines: 8,
      overflow: TextOverflow.ellipsis,
    );
  }
}
