/// 作品資訊 —— 網頁版 catalog.js 那張詳細頁, 換成由下往上推的 sheet.
///
/// 行為照抄: 簡介超過 140 字先收起來、每組集數先畫 120 集、下載畫質五選一、
/// 「邊看邊下載」是先排一個 single 任務再跳進播放器.
library;

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../state/app_state.dart';
import '../state/prefs.dart';
import '../theme.dart';
import '../util/format.dart';
import '../widgets/common.dart';
import 'downloads_page.dart';
import 'watch_page.dart';

const int kEpisodesShown = 120;
const int kSynopsisClamp = 140;
const List<String> kResolutions = ['1080', '720', '540', '480', '360'];

/// 記住這一輪查過的作品, 同一張卡片按第二次不用再等一次網路
final Map<String, SeriesInfo> _detailCache = {};

Future<void> showAnimeSheet(
  BuildContext context,
  AppState state, {
  String animeSn = '',
  String videoSn = '',
  String title = '',
  String cover = '',
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => FractionallySizedBox(
      heightFactor: 0.94,
      child: _AnimeSheet(
        state: state,
        animeSn: animeSn,
        videoSn: videoSn,
        fallbackTitle: title,
        fallbackCover: cover,
      ),
    ),
  );
}

class _AnimeSheet extends StatefulWidget {
  const _AnimeSheet({
    required this.state,
    required this.animeSn,
    required this.videoSn,
    required this.fallbackTitle,
    required this.fallbackCover,
  });

  final AppState state;
  final String animeSn;
  final String videoSn;
  final String fallbackTitle;
  final String fallbackCover;

  @override
  State<_AnimeSheet> createState() => _AnimeSheetState();
}

class _AnimeSheetState extends State<_AnimeSheet> {
  SeriesInfo? _detail;
  String _error = '';
  bool _loading = true;
  bool _synopsisOpen = false;
  final Set<int> _expanded = {};
  late String _resolution = widget.state.prefs.downloadResolution;

  AppState get state => widget.state;

  String get _cacheKey =>
      widget.animeSn.isNotEmpty ? 'a:${widget.animeSn}' : 'v:${widget.videoSn}';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final cached = _detailCache[_cacheKey];
    if (cached != null) {
      setState(() {
        _detail = cached;
        _loading = false;
      });
      return;
    }
    try {
      final detail = widget.animeSn.isNotEmpty
          ? await state.client.catalogAnime(widget.animeSn)
          : await state.client.series(widget.videoSn);
      _detailCache[_cacheKey] = detail;
      if (!mounted) return;
      setState(() {
        _detail = detail;
        _loading = false;
      });
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.needsLogin ? '請先登入再瀏覽作品資訊。' : '拿不到這部作品的資訊。';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '拿不到這部作品的資訊。';
      });
    }
  }

  // ------------------------------------------------------------------ 下載

  Future<bool> _queue(String videoSn, String mode) async {
    if (!state.canManage) {
      toast(context, '需要管理員權限才能下載。');
      return false;
    }
    try {
      await state.startServerDownload(
        videoSn,
        resolution: _resolution,
        mode: mode,
      );
    } on ApiException catch (error) {
      toast(context, error.needsLogin ? '需要管理員權限才能下載。' : '加入下載失敗。');
      return false;
    } catch (_) {
      toast(context, '加入下載失敗。');
      return false;
    }
    state.queued.add(videoSn);
    if (!mounted) return true;
    setState(() {});
    toast(context, mode == 'all' ? '已加入下載佇列，整部作品開始排隊。' : '已加入下載佇列。');
    return true;
  }

  Future<void> _stream(String videoSn) async {
    if (!state.queued.contains(videoSn)) {
      if (!await _queue(videoSn, 'single')) return;
    }
    if (!mounted) return;
    _openWatch(videoSn, streaming: true);
  }

  void _openWatch(String videoSn, {bool streaming = false}) {
    Navigator.of(context).pop();
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => WatchPage(state: state, sn: videoSn, streaming: streaming),
    ));
  }

  Future<void> _saveToPhone(SeriesEpisode episode, SeriesInfo detail) async {
    final video = state.videoOf(episode.videoSn) ??
        VideoItem(
          sn: episode.videoSn,
          animeName: detail.title,
          episode: episode.episode,
          title: detail.title,
          resolution: episode.resolution,
          danmu: true,
        );
    await state.downloads.enqueue(video, withDanmaku: state.prefs.downloadDanmaku);
    if (!mounted) return;
    toast(context, '已加入手機下載佇列。');
  }

  Future<void> _openOnBahamut(String videoSn) async {
    final url = Uri.parse('https://ani.gamer.com.tw/animeVideo.php?sn=$videoSn');
    try {
      await launchUrl(url, mode: LaunchMode.externalApplication);
    } catch (_) {
      if (!mounted) return;
      toast(context, '開不了動畫瘋, 手動搜尋 sn=$videoSn 吧');
    }
  }

  // ------------------------------------------------------------------ 畫面

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error.isNotEmpty || _detail == null) {
      return EmptyState(
        icon: Icons.error_outline,
        title: _error.isEmpty ? '拿不到這部作品的資訊。' : _error,
        actionLabel: '重試',
        onAction: () {
          setState(() {
            _loading = true;
            _error = '';
          });
          _detailCache.remove(_cacheKey);
          _load();
        },
      );
    }

    final detail = _detail!;
    return ListenableBuilder(
      listenable: state.downloads,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.fromLTRB(18, 4, 18, 30),
        children: [
          _hero(detail),
          const SizedBox(height: 16),
          _actions(detail),
          if (detail.content.isNotEmpty) ...[
            const SizedBox(height: 18),
            _synopsis(detail.content),
          ],
          for (var index = 0; index < detail.groups.length; index++)
            _group(detail, detail.groups[index], index),
          const SizedBox(height: 10),
        ],
      ),
    );
  }

  Widget _hero(SeriesInfo detail) {
    final title = detail.title.isNotEmpty ? detail.title : widget.fallbackTitle;
    final cover = detail.cover.isNotEmpty ? detail.cover : widget.fallbackCover;
    final chips = <String>[
      if (detail.score > 0) '★ ${detail.score}',
      if (detail.popular.isNotEmpty) '${detail.popular} 人氣',
      if (detail.seasonStart.isNotEmpty) detail.seasonStart,
      if (detail.totalEpisode.isNotEmpty) '共 ${detail.totalEpisode} 集',
      if (detail.publisher.isNotEmpty) detail.publisher,
      if (detail.director.isNotEmpty) detail.director,
    ];

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 104,
          child: CoverImage(
            name: title,
            url: cover.isNotEmpty ? cover : null,
            aspectRatio: 3 / 4,
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800, height: 1.25),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final chip in chips)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: AgpColors.accentSoft,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(chip, style: const TextStyle(fontSize: 11.5)),
                    ),
                ],
              ),
              if (detail.tags.isNotEmpty) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final tag in detail.tags.take(8))
                      Text(
                        '#$tag',
                        style: const TextStyle(fontSize: 11.5, color: AgpColors.fgFaint),
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 10),
              _FavouriteButton(state: state, detail: detail),
            ],
          ),
        ),
      ],
    );
  }

  SeriesEpisode? _firstLocal(SeriesInfo detail) {
    for (final episode in detail.allEpisodes) {
      if (episode.local) return episode;
    }
    return null;
  }

  Widget _actions(SeriesInfo detail) {
    final local = _firstLocal(detail);
    final currentSn = detail.videoSn.isNotEmpty ? detail.videoSn : widget.videoSn;
    final current = detail.episodeOf(currentSn);
    final buttons = <Widget>[];

    if (local != null) {
      buttons.add(FilledButton.icon(
        onPressed: () => _openWatch(local.videoSn),
        icon: const Icon(Icons.play_arrow_rounded, size: 20),
        label: const Text('立即觀看'),
      ));
    }
    if (state.canManage) {
      if (!(current != null && current.local) && currentSn.isNotEmpty) {
        buttons.add(FilledButton.tonalIcon(
          onPressed: () => _stream(currentSn),
          icon: const Icon(Icons.play_circle_outline, size: 20),
          label: const Text('邊看邊下載'),
        ));
      }
      buttons.add(OutlinedButton.icon(
        onPressed: currentSn.isEmpty ? null : () => _queue(currentSn, 'all'),
        icon: const Icon(Icons.playlist_add_rounded, size: 19),
        label: const Text('加入下載'),
      ));
    }
    if (local != null) {
      buttons.add(OutlinedButton.icon(
        onPressed: () => _saveToPhone(local, detail),
        icon: const Icon(Icons.smartphone_rounded, size: 18),
        label: const Text('下載到手機'),
      ));
    }
    if (currentSn.isNotEmpty) {
      buttons.add(OutlinedButton.icon(
        onPressed: () => _openOnBahamut(currentSn),
        icon: const Icon(Icons.open_in_new_rounded, size: 17),
        label: const Text('在動畫瘋開啟'),
      ));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(spacing: 8, runSpacing: 8, children: buttons),
        if (state.canManage) ...[
          const SizedBox(height: 12),
          Row(
            children: [
              const Text('下載畫質', style: TextStyle(fontSize: 13, color: AgpColors.fgDim)),
              const SizedBox(width: 10),
              DropdownButton<String>(
                value: kResolutions.contains(_resolution) ? _resolution : '1080',
                underline: const SizedBox.shrink(),
                borderRadius: BorderRadius.circular(kRadiusSmall),
                items: [
                  for (final value in kResolutions)
                    DropdownMenuItem(value: value, child: Text('${value}P')),
                ],
                onChanged: (value) {
                  if (value == null) return;
                  setState(() => _resolution = value);
                  state.prefs.setDownloadResolution(value);
                },
              ),
            ],
          ),
        ],
        if (_firstLocal(detail) == null) ...[
          const SizedBox(height: 10),
          Text(
            state.canManage
                ? '這部作品還沒有下載到片庫，「邊看邊下載」會立刻開始播放，檔案在背景繼續下載。'
                : '這部作品還沒有下載到片庫，請聯絡站台管理員加入下載。',
            style: const TextStyle(fontSize: 12.5, height: 1.5, color: AgpColors.fgFaint),
          ),
        ],
      ],
    );
  }

  Widget _synopsis(String content) {
    final clamped = content.length > kSynopsisClamp && !_synopsisOpen;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          clamped ? '${content.substring(0, kSynopsisClamp)}…' : content,
          style: const TextStyle(fontSize: 13.5, height: 1.65, color: AgpColors.fgDim),
        ),
        if (content.length > kSynopsisClamp)
          TextButton(
            onPressed: () => setState(() => _synopsisOpen = !_synopsisOpen),
            style: TextButton.styleFrom(padding: EdgeInsets.zero),
            child: Text(_synopsisOpen ? '收合' : '展開'),
          ),
      ],
    );
  }

  Widget _group(SeriesInfo detail, SeriesGroup group, int index) {
    final open = _expanded.contains(index);
    final shown = open
        ? group.episodes
        : group.episodes.take(kEpisodesShown).toList();
    final more = group.episodes.length - shown.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 22, bottom: 10),
          child: Row(
            children: [
              Text(
                group.name,
                style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w800),
              ),
              const SizedBox(width: 8),
              Text(
                '${group.episodes.length} 集',
                style: const TextStyle(fontSize: 12, color: AgpColors.fgFaint),
              ),
            ],
          ),
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [for (final episode in shown) _episodeChip(detail, episode)],
        ),
        if (more > 0)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: OutlinedButton(
              onPressed: () => setState(() => _expanded.add(index)),
              child: Text('顯示其餘 $more 集'),
            ),
          ),
      ],
    );
  }

  Widget _episodeChip(SeriesInfo detail, SeriesEpisode episode) {
    final label = episode.episode.isNotEmpty ? episode.episode : '?';
    final onPhone = state.downloads.isDownloaded(episode.videoSn);
    final queued = state.queued.contains(episode.videoSn);

    Color background;
    Color foreground = AgpColors.fg;
    IconData? icon;

    if (episode.local) {
      background = AgpColors.accentSoft;
      icon = onPhone ? Icons.smartphone_rounded : Icons.check_rounded;
    } else if (queued) {
      background = const Color(0x241B5E8F);
      icon = Icons.play_arrow_rounded;
    } else {
      background = Colors.white10;
      foreground = AgpColors.fgDim;
    }

    return InkWell(
      borderRadius: BorderRadius.circular(kRadiusSmall),
      onTap: () {
        if (episode.local) {
          _openWatch(episode.videoSn);
        } else if (queued) {
          _openWatch(episode.videoSn, streaming: true);
        } else {
          _queue(episode.videoSn, 'single');
        }
      },
      onLongPress: () => _episodeMenu(detail, episode),
      child: Container(
        constraints: const BoxConstraints(minWidth: 52),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(kRadiusSmall),
          border: Border.all(
            color: episode.local ? AgpColors.accent.withValues(alpha: 0.5) : AgpColors.line,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 13, color: foreground),
              const SizedBox(width: 4),
            ],
            Text(
              label,
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: foreground),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _episodeMenu(SeriesInfo detail, SeriesEpisode episode) async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(
                '${detail.title} · ${episodeLabel(episode.episode)}',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            const Divider(),
            if (episode.local)
              ListTile(
                leading: const Icon(Icons.play_arrow_rounded),
                title: const Text('播放'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _openWatch(episode.videoSn);
                },
              ),
            if (episode.local)
              ListTile(
                leading: const Icon(Icons.smartphone_rounded),
                title: Text(state.downloads.isDownloaded(episode.videoSn)
                    ? '已下載到手機'
                    : '下載到手機'),
                enabled: !state.downloads.isDownloaded(episode.videoSn),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _saveToPhone(episode, detail);
                },
              ),
            if (!episode.local && state.canManage)
              ListTile(
                leading: const Icon(Icons.playlist_add_rounded),
                title: const Text('加入伺服器下載佇列'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _queue(episode.videoSn, 'single');
                },
              ),
            if (!episode.local && state.canManage)
              ListTile(
                leading: const Icon(Icons.play_circle_outline),
                title: const Text('邊看邊下載'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _stream(episode.videoSn);
                },
              ),
            ListTile(
              leading: const Icon(Icons.open_in_new_rounded),
              title: const Text('在動畫瘋開啟'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _openOnBahamut(episode.videoSn);
              },
            ),
            ListTile(
              leading: const Icon(Icons.download_rounded),
              title: const Text('手機下載管理'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => DownloadsPage(state: state),
                ));
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _FavouriteButton extends StatefulWidget {
  const _FavouriteButton({required this.state, required this.detail});

  final AppState state;
  final SeriesInfo detail;

  @override
  State<_FavouriteButton> createState() => _FavouriteButtonState();
}

class _FavouriteButtonState extends State<_FavouriteButton> {
  @override
  Widget build(BuildContext context) {
    final on = widget.state.isFavourite(widget.detail.title);
    return OutlinedButton.icon(
      onPressed: () async {
        final added = await widget.state.toggleFavourite(Favourite(
          name: widget.detail.title,
          sn: widget.detail.videoSn,
          cover: widget.detail.cover,
        ));
        if (!mounted) return;
        setState(() {});
        toast(context, added ? '已加入收藏' : '已從收藏移除');
      },
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        foregroundColor: on ? AgpColors.accent : null,
        side: BorderSide(color: on ? AgpColors.accent : AgpColors.lineStrong),
      ),
      icon: Icon(on ? Icons.favorite_rounded : Icons.favorite_outline, size: 17),
      label: Text(on ? '已收藏' : '收藏'),
    );
  }
}
