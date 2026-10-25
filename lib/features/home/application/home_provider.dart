import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:fus_inbox/core/services/clipboard_service.dart';
import 'package:fus_inbox/core/utils/article_url_parser.dart';
import 'package:fus_inbox/features/home/domain/home_state.dart';

export 'package:fus_inbox/features/home/domain/home_state.dart';

part 'home_provider.g.dart';

@Riverpod(keepAlive: true)
class Home() extends _$Home {
  @override
  HomeState build() => const HomeState();

  void setUrl(String url) {
    state = state.copyWith(url: url);
  }

  Future<String?> pasteFromClipboard() async {
    final clipboardText = await ref.read(clipboardServiceProvider).paste();
    if (clipboardText == null) return null;

    final url = extractArticleUrl(clipboardText) ?? clipboardText.trim();
    state = state.copyWith(url: url);
    return url;
  }

  Future<String?> detectArticleUrlFromClipboard() async {
    final clipboardText = await ref.read(clipboardServiceProvider).paste();
    if (clipboardText == null) return null;

    final url = extractArticleUrl(clipboardText);
    if (url == null) return null;

    state = state.copyWith(url: url);
    return url;
  }
}
