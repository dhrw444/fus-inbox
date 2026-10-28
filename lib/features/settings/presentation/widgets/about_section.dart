/// 设置页「关于」分组：数据来源、开源仓库、许可。
///
/// 三行里只有「开源仓库」可点（走系统浏览器），把它和 [openExternalUrl]
/// 的失败提示一起放在这里 —— 这一组就这三行，不值得再拆。
library;

import 'package:fus_inbox/core/constants/app_constants.dart';
import 'package:fus_inbox/core/webview/native_capabilities.dart';
import 'package:fus_inbox/features/settings/presentation/widgets/settings_group.dart';
import 'package:material_ui/material_ui.dart';

/// 关于分组。纯展示 + 一个外链。
class const AboutSection({super.key}) extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SettingsGroupLabel(text: '关于'),
        SettingsGroupCard(
          children: [
            const ListTile(
              leading: Icon(Icons.cloud_outlined),
              title: Text('数据来源'),
              subtitle: Text('freeussms.com'),
            ),
            const Divider(height: 1, indent: 16, endIndent: 16),
            ListTile(
              leading: const Icon(Icons.code),
              title: const Text('开源仓库'),
              subtitle: const Text('github.com/dhrw444/fus-inbox'),
              trailing: const Icon(Icons.open_in_new, size: 18),
              onTap: () => _openSource(context),
            ),
            const Divider(height: 1, indent: 16, endIndent: 16),
            const ListTile(
              leading: Icon(Icons.description_outlined),
              title: Text('许可'),
              subtitle: Text('MIT'),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _openSource(BuildContext context) async {
    final ok = await openExternalUrl(AppConstants.appSourceUrl);
    if (!context.mounted || ok) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(const SnackBar(content: Text('没有能打开链接的应用')));
  }
}
