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
  const AllTab(
      {super.key,
      required this.state,
      required this.query,
      this.searchMode = false,
      this.onResultOpened});

  final AppState state;
  final String query;
  final bool searchMode;
  final VoidCallback? onResultOpened;

  @override
  State<AllTab> createState() => _AllTabState();
}

class _AllTabState extends State<AllTab> {
  CatalogPage? _page;
  bool _loading = true;
  bool _libraryOnly = false;
  String _error = '';
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
      _token++;
      _page = null;
      _error = '';
      _loading = true;
      if (_scroll.hasClients) _scroll.jumpTo(0);
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
    if (state.offline || !state.hasServer) {
      setState(() {
        _loading = false;
        _page = CatalogPage();
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = '';
    });
    CatalogPage result;
    try {
      result =
          await state.client.catalogAll(query: widget.query.trim(), page: page);
    } catch (_) {
      if (mounted && token == _token) _error = '暫時無法取得動畫瘋片單，請重試。';
      result = CatalogPage();
    }
    if (!mounted || token != _token) return;
    state.thumbnails.seedCatalog(result.items);
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
    final searching = widget.searchMode || query.isNotEmpty;
    final libraryOnly = _libraryOnly || state.offline;
    final matches = _libraryMatches;
    final page = _page;
    final remote = page?.items ?? const <CatalogItem>[];
    final localNames = matches.map((v) => v.displayName.toLowerCase()).toSet();
    final cards = <({VideoItem? video, CatalogItem? item})>[
      if (searching || libraryOnly)
        for (final video in matches) (video: video, item: null),
      if (searching || !libraryOnly)
        for (final item in remote)
          if (!searching || !localNames.contains(item.title.toLowerCase()))
            (video: null, item: item),
    ];
    final showingRemote = searching || !libraryOnly;
    return LayoutBuilder(builder: (context, constraints) {
      final delegate = posterGridDelegate(constraints.maxWidth,
          textScale: MediaQuery.textScalerOf(context).scale(14) / 14);
      return RefreshIndicator(
        onRefresh: () async {
          await state.thumbnails.refresh();
          await _load(1);
        },
        child: CustomScrollView(
          key: const ValueKey('anime-results'),
          controller: _scroll,
          physics: const AlwaysScrollableScrollPhysics(),
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          slivers: [
            SliverToBoxAdapter(
                child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: searching
                  ? Row(children: [
                      Expanded(
                          child: Text('搜尋「$query」',
                              maxLines: 2,
                              style: const TextStyle(
                                  fontWeight: FontWeight.w700, fontSize: 16))),
                      const SizedBox(width: 12),
                      Text('${cards.length} 部作品',
                          style: TextStyle(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant)),
                    ])
                  : Wrap(
                      spacing: 10,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                          ChoiceChip(
                              label: const Text('動畫瘋片單'),
                              selected: !libraryOnly,
                              onSelected: state.offline
                                  ? null
                                  : (_) =>
                                      setState(() => _libraryOnly = false)),
                          ChoiceChip(
                              label: Text('我的片庫 ${matches.length}'),
                              selected: libraryOnly,
                              onSelected: (_) =>
                                  setState(() => _libraryOnly = true)),
                          if (!libraryOnly && page != null)
                            Text('共 ${page.total} 部作品',
                                style: TextStyle(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant)),
                        ]),
            )),
            if (_loading && showingRemote)
              const SliverToBoxAdapter(
                  child: LinearProgressIndicator(minHeight: 2)),
            if (_error.isNotEmpty && showingRemote)
              SliverToBoxAdapter(
                  child: ListTile(
                leading: const Icon(Icons.cloud_off_rounded),
                title: Text(_error),
                trailing: TextButton(
                    onPressed: () => _load(1), child: const Text('重試')),
              )),
            if (cards.isEmpty && !(_loading && showingRemote))
              SliverFillRemaining(
                  hasScrollBody: false,
                  child: EmptyState(
                    icon: searching
                        ? Icons.search_off_rounded
                        : Icons.video_library_outlined,
                    title: searching
                        ? '沒有找到相符的動畫'
                        : libraryOnly
                            ? '片庫還沒有動畫'
                            : '暫時沒有片單',
                    message: searching
                        ? '試試較短的作品名稱，或確認伺服器連線。'
                        : libraryOnly
                            ? '下載到伺服器的作品會顯示在這裡。'
                            : '下拉重新整理後再試一次。',
                  ))
            else
              _grid(
                  delegate: delegate,
                  count: cards.length,
                  builder: (context, index) {
                    final row = cards[index];
                    final video = row.video;
                    final item = row.item;
                    return PosterCard(
                      key: ValueKey(video == null
                          ? 'catalog-${item!.animeSn}-${item.videoSn}'
                          : 'library-${video.sn}'),
                      title: video?.displayName ?? item!.title,
                      cover: video == null && item!.cover.isNotEmpty
                          ? item.cover
                          : null,
                      cache: state.thumbnails,
                      sn: video?.sn ??
                          (item!.videoSn.isNotEmpty
                              ? item.videoSn
                              : item.animeSn),
                      badge: video != null ? '片庫' : null,
                      subtitle: video != null
                          ? '${state.episodesOf(video.displayName).length} 集'
                          : [
                              if (item!.info.isNotEmpty)
                                item.info
                              else
                                item.volume,
                              if (item.popular.isNotEmpty) item.popular
                            ].where((s) => s.isNotEmpty).join(' · '),
                      onTap: () {
                        widget.onResultOpened?.call();
                        if (video != null) {
                          _openLibrary(video);
                          return;
                        }
                        showAnimeSheet(context, state,
                            animeSn: item!.animeSn,
                            videoSn: item.videoSn,
                            title: item.title,
                            cover: item.cover);
                      },
                    );
                  }),
            if (showingRemote && page != null && page.pages > 1)
              SliverToBoxAdapter(child: _pager(page)),
            const SliverToBoxAdapter(child: SizedBox(height: 28)),
          ],
        ),
      );
    });
  }

  void _openLibrary(VideoItem video) {
    final episodes = state.episodesOf(video.displayName);
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
                style:
                    const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(
                children: [
                  Text(
                    '片庫裡有 ${episodes.length} 集',
                    style: const TextStyle(
                        fontSize: 12.5, color: AgpColors.fgFaint),
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
      child: Wrap(
        alignment: WrapAlignment.center,
        crossAxisAlignment: WrapCrossAlignment.center,
        runSpacing: 8,
        children: [
          OutlinedButton(
            onPressed:
                page.page <= 1 || _loading ? null : () => _load(page.page - 1),
            child: const Text('上一頁'),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Text(
              '第 ${page.page} / ${page.pages} 頁',
              style: TextStyle(
                  fontSize: 13,
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
          ),
          OutlinedButton(
            onPressed: page.page >= page.pages || _loading
                ? null
                : () => _load(page.page + 1),
            child: const Text('下一頁'),
          ),
        ],
      ),
    );
  }
}
