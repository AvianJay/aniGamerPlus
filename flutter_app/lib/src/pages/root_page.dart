/// 五個底部分頁 —— 跟網頁版首頁改版後的那五個一樣:
/// 首頁 / 所有動畫 / 收藏 / 紀錄 / 我的.
library;

import 'package:flutter/material.dart';

import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/common.dart';
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
  AppState get state => widget.state;

  void _openSearch() => Navigator.of(context)
      .push(MaterialPageRoute<void>(builder: (_) => SearchPage(state: state)));

  static const _titles = ['首頁', '所有動畫', '收藏', '紀錄', '我的'];

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
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
              child: IndexedStack(
                index: _index,
                children: [
                  HomeTab(
                      state: state, onSeeAll: () => setState(() => _index = 1)),
                  AllTab(state: state, query: ''),
                  FavouritesTab(state: state),
                  HistoryTab(state: state),
                  MeTab(state: state),
                ],
              ),
            ),
            bottomNavigationBar: NavigationBar(
              selectedIndex: _index,
              onDestinationSelected: (index) {
                if (index == _index && index == 0) {
                  return;
                }
                setState(() {
                  _index = index;
                });
              },
              destinations: const [
                NavigationDestination(
                  icon: Icon(Icons.home_outlined),
                  selectedIcon: Icon(Icons.home_rounded),
                  label: '首頁',
                ),
                NavigationDestination(
                  icon: Icon(Icons.grid_view_outlined),
                  selectedIcon: Icon(Icons.grid_view_rounded),
                  label: '所有動畫',
                ),
                NavigationDestination(
                  icon: Icon(Icons.favorite_outline),
                  selectedIcon: Icon(Icons.favorite_rounded),
                  label: '收藏',
                ),
                NavigationDestination(
                  icon: Icon(Icons.history_outlined),
                  selectedIcon: Icon(Icons.history_rounded),
                  label: '紀錄',
                ),
                NavigationDestination(
                  icon: Icon(Icons.person_outline),
                  selectedIcon: Icon(Icons.person_rounded),
                  label: '我的',
                ),
              ],
            ),
          ),
        );
      },
    );
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
              color: Color(0x33FFFFFF),
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
