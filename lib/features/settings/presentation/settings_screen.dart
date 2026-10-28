/// 设置页。
///
/// 按「外观 / 短信 / 代理 / 存储 / 关于」分组。每一组都是一个独立的
/// widget（在 `widgets/` 下），这一页只负责**按顺序摆**：加一项设置时
/// 打开对应那组的文件，不用在这一页里翻一百行找插入点。
///
/// 视觉语言参考 Yomiru：分组标题外面不加框，每个分组包一张
/// elevation:0 + 16dp 圆角的卡片，卡内条目去掉逐条分隔线，靠留白分层。
/// 之前是裸 ListTile + Divider，和系统设置页长得一样，没有辨识度。
library;

import 'package:fus_inbox/core/constants/app_constants.dart';
import 'package:fus_inbox/core/prefs/prefs_provider.dart';
import 'package:fus_inbox/features/settings/presentation/widgets/about_section.dart';
import 'package:fus_inbox/features/settings/presentation/widgets/appearance_section.dart';
import 'package:fus_inbox/features/settings/presentation/widgets/proxy_settings_section.dart';
import 'package:fus_inbox/features/settings/presentation/widgets/sms_section.dart';
import 'package:fus_inbox/features/settings/presentation/widgets/storage_section.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

/// 设置页壳：五个分组按序摆放 + 底部版本号。
class const SettingsScreen({super.key}) extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 外观/短信两组都读同一份偏好，在这一层读一次传下去 ——
    // 免得每组各自 watch，改一个开关把整页都标脏。
    final prefs = ref.watch(prefsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('设置'), centerTitle: false),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 36),
        children: [
          AppearanceSection(prefs: prefs),
          SmsSection(prefs: prefs),
          const ProxySettingsSection(),
          const StorageSection(),
          const AboutSection(),
          const SizedBox(height: 20),
          Center(
            child: Text(
              'v${AppConstants.appVersion}',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
