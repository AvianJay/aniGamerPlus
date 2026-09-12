/// 所有動畫 —— 網頁版 paneAll: 上面是片庫比對的結果, 下面是動畫瘋的整份片單.
///
/// 搜尋一樣是 260ms debounce, 而且一定要擋住晚到的回應 —— 慢的第 1 頁蓋掉快的
/// 第 2 頁, 使用者會以為自己按錯了.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../api/models.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../util/format.dart';
import '../widgets/cards.dart';
import '../widgets/common.dart';
import 'anime_sheet.dart';
import 'home_tab.dart';
import 'watch_page.dart';

const Duration kSearchDebounce = Duration(milliseconds: 260);

class AllTab extends StatefulWidget {
  const AllTab({super.key, required this.state, required this.query});

  final AppState state;
  final String query;

  @override
  State<AllTab> createState() => _AllTabState();
}

class _AllTabState extends State<AllTab> {
  CatalogPage? _page;
  bool _loading = true;
  int _token = 0;
  Timer? _debounce;
  final ScrollController _scroll = ScrollController();

  AppState get state => widget.state;

  @override
  void initState() {
    super.initState();
    _load(1);
  }

  @override
  void didUpdateWidget(covariant AllTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.query != widget.query) {
      _debounce?.cancel();
      _debounce = Timer(kSearchDebounce, () => _load(1));
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load(int page) async {
    final token = ++_token;
    setState(() => _loading = true);
    CatalogPage result;
    try {
      result = await state.client
          .catalogAll(query: widget.query.trim(), page: page);
    } catch (_) {
      result = CatalogPage();
    }
    if (!mounted || token != _token) return;
    setState(() {
      _page = result;
      _loading = false;
    });
    if (page != 1 && _scroll.hasClients) {
      _scroll.animateTo(
        0,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    }
  }

  List<VideoItem> get _libraryMatches {
    final query = widget.query.trim().toLowerCase();
    final heads = state.animeHeads;
    if (query.isEmpty) return heads;
    return heads
        .where((video) => video.displayName.toLowerCase().contains(query))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final query = widget.query.trim();
    final matches = _libraryMatches;
    final page = _page;

    // 兩個格線都改成 sliver: 以前是 ListView 裡塞兩個 shrinkWrap 的
    // GridView.builder, 那等於一進來就把兩百多格全部 build 出來, 也就是
    // 兩百多筆縮圖請求同時出去. 現在只有看得到的那幾格會 build.
    return LayoutBuilder(
      builder: (context, constraints) {
        final delegate = posterGridDelegate(constraints.maxWidth);
        return CustomScrollView(
          controller: _scroll,
          slivers: [
            SliverToBoxAdapter(
              child: SectionHeader(
                title: query.isEmpty ? '片庫' : '片庫搜尋結果',
                subtitle: matches.isEmpty ? null : '${matches.length} 部作品',
              ),
            ),
            if (matches.isEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                    query.isEmpty
                        ? '片庫還沒有任何影片，先到主控台下載幾集吧。'
                        : '找不到符合「$query」的作品。',
                    style: const TextStyle(fontSize: 13, color: AgpColors.fgFaint),
                  ),
                ),
              )
            else
              _grid(
                delegate: delegate,
                count: matches.length,
                builder: (context, index) {
                  final video = matches[index];
                  final episodes = state.episodesOf(video.animeName).length;
                  return PosterCard(
                    title: video.displayName,
                    cache: state.thumbnails,
                    sn: video.sn,
                    headers: state.client.authHeaders,
                    subtitle: '$episodes 集',
                    onTap: () => _openLibrary(video),
                  );
                },
              ),
            SliverToBoxAdapter(
              child: SectionHeader(
                title: query.isEmpty ? '所有動畫' : '搜尋結果',
                subtitle: page == null || page.total == 0
                    ? null
                    : (query.isEmpty
                        ? '共 ${page.total} 部作品'
                        : '找到 ${page.total} 部作品'),
              ),
            ),
            if (_loading && page == null)
              const SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.symmetric(vertical: 34),
                  child: Center(child: CircularProgressIndicator()),
                ),
              )
            else if (page == null || page.items.isEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                    query.isEmpty
                        ? '目前拿不到動畫瘋的片單。'
                        : '找不到符合「$query」的作品。',
                    style: const TextStyle(fontSize: 13, color: AgpColors.fgFaint),
                  ),
                ),
              )
            else ...[
              SliverOpacity(
                opacity: _loading ? 0.45 : 1,
                sliver: _grid(
                  delegate: delegate,
                  count: page.items.length,
                  builder: (context, index) {
                    final item = page.items[index];
                    return PosterCard(
                      title: item.title,
                      // 片單卡片的 cover 本來就是動畫瘋 CDN 的網址, 不必繞
                      // 伺服器, 但一樣交給快取去落盤
                      cover: item.cover.isEmpty ? null : item.cover,
                      cache: state.thumbnails,
                      subtitle: [
                        if (item.info.isNotEmpty) item.info else item.volume,
                        if (item.popular.isNotEmpty) item.popular,
                      ].where((t) => t.isNotEmpty).join(' · '),
                      onTap: () => showAnimeSheet(
                        context,
                        state,
                        animeSn: item.animeSn,
                        videoSn: item.videoSn,
                        title: item.title,
                        cover: item.cover,
                      ),
                    );
                  },
                ),
              ),
              if (page.pages > 1) SliverToBoxAdapter(child: _pager(page)),
            ],
            const SliverToBoxAdapter(child: SizedBox(height: 28)),
          ],
        );
      },
    );
  }

  void _openLibrary(VideoItem video) {
    final episodes = state.episodesOf(video.animeName);
    if (episodes.length <= 1) {
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => WatchPage(state: state, sn: video.sn),
      ));
      return;
    }
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheetContext) => FractionallySizedBox(
        heightFactor: 0.8,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                video.displayName,
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(
                children: [
                  Text(
                    '片庫裡有 ${episodes.length} 集',
                    style: const TextStyle(fontSize: 12.5, color: AgpColors.fgFaint),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: () {
                      Navigator.of(sheetContext).pop();
                      showAnimeSheet(
                        context,
                        state,
                        videoSn: video.sn,
                        title: video.displayName,
                      );
                    },
                    child: const Text('作品資訊'),
                  ),
                ],
              ),
            ),
            for (final episode in episodes)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: SizedBox(
                  width: 92,
                  child: CoverImage(
                    name: episode.displayName,
                    file: state.downloads.localThumb(episode.sn),
                    cache: state.downloads.localThumb(episode.sn) == null
                        ? state.thumbnails
                        : null,
                    sn: episode.sn,
                    headers: state.client.authHeaders,
                  ),
                ),
                title: Text(episodeLabel(episode.episode)),
                subtitle: Text(
                  [
                    if (episode.resolution > 0) '${episode.resolution}P',
                    if (state.downloads.isDownloaded(episode.sn)) '已離線',
                  ].join(' · '),
                  style: const TextStyle(fontSize: 12),
                ),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => WatchPage(state: state, sn: episode.sn),
                  ));
                },
                onLongPress: () {
                  Navigator.of(sheetContext).pop();
                  showLibraryMenu(context, state, episode);
                },
              ),
          ],
        ),
      ),
    );
  }

  Widget _grid({
    required SliverGridDelegate delegate,
    required int count,
    required Widget Function(BuildContext context, int index) builder,
  }) {
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: kPosterGridPadding),
      sliver: SliverGrid(
        gridDelegate: delegate,
        delegate: SliverChildBuilderDelegate(builder, childCount: count),
      ),
    );
  }

  Widget _pager(CatalogPage page) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          OutlinedButton(
            onPressed: page.page <= 1 || _loading ? null : () => _load(page.page - 1),
            child: const Text('上一頁'),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Text(
              '第 ${page.page} / ${page.pages} 頁',
              style: const TextStyle(fontSize: 13, color: AgpColors.fgDim),
            ),
          ),
          OutlinedButton(
            onPressed:
                page.page >= page.pages || _loading ? null : () => _load(page.page + 1),
            child: const Text('下一頁'),
          ),
        ],
      ),
    );
  }
}
