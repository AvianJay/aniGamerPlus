/// 五個底部分頁 —— 跟網頁版首頁改版後的那五個一樣:
/// 首頁 / 所有動畫 / 收藏 / 紀錄 / 我的.
library;

import 'package:flutter/material.dart';

import '../state/app_state.dart';
import '../theme.dart';
import '../util/device.dart';
import '../widgets/common.dart';
import '../widgets/active_builder.dart';
import 'all_tab.dart';
import 'downloads_page.dart';
import 'favourites_tab.dart';
import 'history_tab.dart';
import 'home_tab.dart';
import 'me_tab.dart';
import 'search_page.dart';

class RootPage extends StatefulWidget {
  const RootPage({super.key, required this.state});

  final AppState state;

  @override
  State<RootPage> createState() => _RootPageState();
}

class _RootPageState extends State<RootPage> {
  int _index = 0;
  final Set<int> _visited = {0};
  AppState get state => widget.state;

  /// 電視: 包著左邊分頁列, 開起來時把焦點放上去
  final FocusNode _rail = FocusNode(
      debugLabel: 'root-rail', canRequestFocus: false, skipTraversal: true);

  @override
  void initState() {
    super.initState();
    if (Device.tv) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _focusRail());
    }
  }

  @override
  void dispose() {
    _rail.dispose();
    super.dispose();
  }

  /// 一開 App 什麼都沒選到的話, 第一下方向鍵落在哪裡要看運氣. 先停在分頁上
  void _focusRail() {
    if (!mounted) return;
    final current = FocusManager.instance.primaryFocus;
    if (current != null && current is! FocusScopeNode) return;
    final tabs = _rail.traversalDescendants.toList();
    if (tabs.isEmpty) return;
    tabs[_index.clamp(0, tabs.length - 1)].requestFocus();
  }

  void _openSearch() => Navigator.of(context)
      .push(MaterialPageRoute<void>(builder: (_) => SearchPage(state: state)));

  static const _titles = ['首頁', '所有動畫', '收藏', '紀錄', '我的'];

  @override
  Widget build(BuildContext context) {
    return ActiveListenableBuilder(
      listenable: state,
      builder: (context) {
        return PopScope(
          canPop: _index == 0,
          onPopInvokedWithResult: (didPop, _) {
            if (didPop) return;
            if (_index != 0) {
              setState(() => _index = 0);
            }
          },
          child: Scaffold(
            appBar: _buildAppBar(),
            body: SafeArea(
              top: false,
              child: Device.tv
                  // 電視: 分頁移到左邊. 橫的螢幕上下本來就不夠高, 而且遙控器
                  // 往左一按就回到分頁, 比一路往下按到底自然
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _buildRail(),
                        const VerticalDivider(width: 1),
                        Expanded(child: _buildTabs()),
                      ],
                    )
                  : _buildTabs(),
            ),
            bottomNavigationBar: Device.tv
                ? null
                : NavigationBar(
                    selectedIndex: _index,
                    onDestinationSelected: _select,
                    destinations: [
                      for (final tab in _tabs)
                        NavigationDestination(
                          icon: Icon(tab.icon),
                          selectedIcon: Icon(tab.selectedIcon),
                          label: tab.label,
                        ),
                    ],
                  ),
          ),
        );
      },
    );
  }

  static const _tabs = [
    (icon: Icons.home_outlined, selectedIcon: Icons.home_rounded, label: '首頁'),
    (
      icon: Icons.grid_view_outlined,
      selectedIcon: Icons.grid_view_rounded,
      label: '所有動畫'
    ),
    (
      icon: Icons.favorite_outline,
      selectedIcon: Icons.favorite_rounded,
      label: '收藏'
    ),
    (
      icon: Icons.history_outlined,
      selectedIcon: Icons.history_rounded,
      label: '紀錄'
    ),
    (
      icon: Icons.person_outline,
      selectedIcon: Icons.person_rounded,
      label: '我的'
    ),
  ];

  void _select(int index) {
    if (index == _index && index == 0) {
      return;
    }
    setState(() {
      _index = index;
      _visited.add(index);
    });
  }

  Widget _buildTabs() {
    return IndexedStack(
      index: _index,
      children: [
        for (var i = 0; i < _tabs.length; i++)
          TickerMode(
            enabled: i == _index,
            child: RepaintBoundary(
              child: _visited.contains(i) ? _tab(i) : const SizedBox.shrink(),
            ),
          ),
      ],
    );
  }

  Widget _tab(int index) {
    return switch (index) {
      0 => HomeTab(state: state, onSeeAll: () => _select(1)),
      1 => AllTab(state: state, query: ''),
      2 => FavouritesTab(state: state),
      3 => HistoryTab(state: state),
      _ => MeTab(state: state),
    };
  }

  Widget _buildRail() {
    return Focus(
        focusNode: _rail,
        child: NavigationRail(
          selectedIndex: _index,
          onDestinationSelected: _select,
          labelType: NavigationRailLabelType.all,
          backgroundColor: Theme.of(context).navigationBarTheme.backgroundColor,
          indicatorColor: AgpColors.accentSoft,
          selectedIconTheme: const IconThemeData(color: AgpColors.accent),
          selectedLabelTextStyle: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: AgpColors.accent),
          unselectedLabelTextStyle: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: Theme.of(context).colorScheme.onSurfaceVariant),
          destinations: [
            for (final tab in _tabs)
              NavigationRailDestination(
                icon: Icon(tab.icon),
                selectedIcon: Icon(tab.selectedIcon),
                label: Text(tab.label),
              ),
          ],
        ));
  }

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      title: Row(
        children: [
          Text(_titles[_index]),
          if (state.offline) ...[
            const SizedBox(width: 8),
            const Pill(
              label: '離線',
              dense: true,
              icon: Icons.cloud_off_rounded,
              color: AgpColors.accent,
            ),
          ],
        ],
      ),
      actions: [
        IconButton(
          tooltip: '搜尋',
          icon: const Icon(Icons.search),
          onPressed: _openSearch,
        ),
        _DownloadsButton(state: state),
        const SizedBox(width: 4),
      ],
    );
  }
}

class _DownloadsButton extends StatelessWidget {
  const _DownloadsButton({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state.downloads,
      builder: (context, _) {
        final busy = state.downloads.active.length;
        return Stack(
          alignment: Alignment.center,
          children: [
            IconButton(
              tooltip: '下載',
              icon: const Icon(Icons.download_rounded),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => DownloadsPage(state: state)),
              ),
            ),
            if (busy > 0)
              Positioned(
                right: 6,
                top: 8,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                  constraints: const BoxConstraints(minWidth: 15),
                  decoration: BoxDecoration(
                    color: AgpColors.accent,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    '$busy',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 9.5,
                      fontWeight: FontWeight.w800,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
