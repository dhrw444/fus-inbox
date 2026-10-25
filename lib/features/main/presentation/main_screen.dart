/// 主壳：底部两个页签（号码 / 收藏）。
///
/// 用 IndexedStack 保活，切页签不丢滚动位置和已加载的目录。
library;

import 'package:material_ui/material_ui.dart';

import 'package:fus_inbox/features/numbers/presentation/numbers_screen.dart';
import 'package:fus_inbox/features/saved/presentation/saved_screen.dart';

class const MainScreen({super.key}) extends StatefulWidget {
  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState() extends State<MainScreen> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: const [NumbersScreen(), _SavedTab()],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.dialpad_outlined),
            selectedIcon: Icon(Icons.dialpad),
            label: '号码',
          ),
          NavigationDestination(
            icon: Icon(Icons.star_border),
            selectedIcon: Icon(Icons.star),
            label: '收藏',
          ),
        ],
      ),
    );
  }
}

/// 收藏页自己需要一个带标题的壳。
class const _SavedTab() extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('收藏')),
      body: const SavedScreen(),
    );
  }
}
