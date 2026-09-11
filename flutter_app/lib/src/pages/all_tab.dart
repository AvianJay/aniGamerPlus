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
import '../widgets/local_thumb.dart';
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

    return ListView(
      controller: _scroll,
      padding: const EdgeInsets.only(bottom: 28),
      children: [
        SectionHeader(
          title: query.isEmpty ? '片庫' : '片庫搜尋結果',
          subtitle: matches.isEmpty ? null : '${matches.length} 部作品',
        ),
        if (matches.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              query.isEmpty
                  ? '片庫還沒有任何影片，先到主控台下載幾集吧。'
                  : '找不到符合「$query」的作品。',
              style: const TextStyle(fontSize: 13, color: AgpColors.fgFaint),
            ),
          )
        else
          _grid(
            count: matches.length,
            builder: (context, index) {
              final video = matches[index];
              final episodes = state.episodesOf(video.animeName).length;
              return PosterCard(
                title: video.displayName,
                thumbSn: video.sn,
                thumbStore: state.thumbnails,
                coverFile: state.thumbFile(video.sn),
                subtitle: '$episodes 集',
                onTap: () => _openLibrary(video),
              );
            },
          ),
        SectionHeader(
          title: query.isEmpty ? '所有動畫' : '搜尋結果',
          subtitle: page == null || page.total == 0
              ? null
              : (query.isEmpty ? '共 ${page.total} 部作品' : '找到 ${page.total} 部作品'),
        ),
        if (_loading && page == null)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 34),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (page == null || page.items.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              query.isEmpty
                  ? '目前拿不到動畫瘋的片單。'
                  : '找不到符合「$query」的作品。',
              style: const TextStyle(fontSize: 13, color: AgpColors.fgFaint),
            ),
          )
        else ...[
          Opacity(
            opacity: _loading ? 0.45 : 1,
            child: _grid(
              count: page.items.length,
              builder: (context, index) {
                final item = page.items[index];
                return PosterCard(
                  title: item.title,
                  cover: item.cover.isEmpty ? null : item.cover,
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
          if (page.pages > 1) _pager(page),
        ],
      ],
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
                  child: LocalThumb(
                    store: state.thumbnails,
                    sn: episode.sn,
                    name: episode.displayName,
                    offlineFile: state.thumbFile(episode.sn),
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
    required int count,
    required Widget Function(BuildContext context, int index) builder,
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return GridView.builder(
          padding: const EdgeInsets.symmetric(horizontal: kPosterGridPadding),
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: posterGridDelegate(constraints.maxWidth),
          itemCount: count,
          itemBuilder: builder,
        );
      },
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
