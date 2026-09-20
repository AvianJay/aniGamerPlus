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
import '../state/downloads.dart';
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

  Future<void> _addToSnList(String videoSn) async {
    if (!state.canManage) {
      toast(context, '需要管理員權限才能更新 sn_list。');
      return;
    }
    try {
      await state.addSeriesToSnList(videoSn);
    } on ApiException catch (error) {
      toast(context,
          error.needsLogin ? '需要管理員權限才能更新 sn_list。' : '加入 sn_list 失敗。');
      return;
    } catch (_) {
      toast(context, '加入 sn_list 失敗。');
      return;
    }
    if (!mounted) return;
    toast(context, '已加入 sn_list，會依最大併發數排程下載。');
  }

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
      builder: (_) =>
          WatchPage(state: state, sn: videoSn, streaming: streaming),
    ));
  }

  Future<void> _saveToPhone(SeriesEpisode episode, SeriesInfo detail) async {
    await state.downloads.enqueue(
      _videoFor(episode, detail),
      withDanmaku: state.prefs.downloadDanmaku,
    );
    if (!mounted) return;
    toast(context, '已加入手機下載佇列。');
  }

  /// 伺服器上還沒有這一集 —— /get_video.mp4 找不到檔案就是 404, 手機這邊
  /// 沒有別的來源. 所以先請伺服器抓, 這集在手機的清單裡先掛著「等伺服器」,
  /// DownloadStore.pollWaiting() 看到檔案出現才真的開始下載.
  Future<void> _saveToPhoneViaServer(
    SeriesEpisode episode,
    SeriesInfo detail,
  ) async {
    if (!await _queue(episode.videoSn, 'single')) return;
    await state.downloads.enqueueWaiting(
      _videoFor(episode, detail),
      withDanmaku: state.prefs.downloadDanmaku,
    );
    if (!mounted) return;
    toast(context, '伺服器下載完成後會自動存到手機。');
  }

  VideoItem _videoFor(SeriesEpisode episode, SeriesInfo detail) =>
      state.videoOf(episode.videoSn) ??
      VideoItem(
        sn: episode.videoSn,
        animeName: detail.title,
        episode: episode.episode,
        title: detail.title,
        resolution: episode.resolution > 0
            ? episode.resolution
            : int.tryParse(_resolution) ?? 0,
        danmu: true,
      );

  Future<void> _openPicker(SeriesInfo detail) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => FractionallySizedBox(
        heightFactor: 0.9,
        child: _EpisodePickerSheet(
          state: state,
          detail: detail,
          resolution: _resolution,
        ),
      ),
    );
    if (!mounted) return;
    // 選集時可能順手排了伺服器任務, 集數格子的顏色要跟上
    setState(() {});
  }

  Future<void> _openOnBahamut(String videoSn) async {
    final url =
        Uri.parse('https://ani.gamer.com.tw/animeVideo.php?sn=$videoSn');
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
            cache: state.thumbnails,
            sn: detail.animeSn.isNotEmpty ? detail.animeSn : null,
            poster: true,
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
                style: const TextStyle(
                    fontSize: 19, fontWeight: FontWeight.w800, height: 1.25),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final chip in chips)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 3),
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
                        style: TextStyle(
                            fontSize: 11.5,
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant),
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
    final currentSn =
        detail.videoSn.isNotEmpty ? detail.videoSn : widget.videoSn;
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
        onPressed: currentSn.isEmpty ? null : () => _addToSnList(currentSn),
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
    if (detail.allEpisodes.isNotEmpty) {
      buttons.add(OutlinedButton.icon(
        onPressed: () => _openPicker(detail),
        icon: const Icon(Icons.checklist_rounded, size: 18),
        label: const Text('選集下載到手機'),
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
              Text('下載畫質',
                  style: TextStyle(
                      fontSize: 13,
                      color: Theme.of(context).colorScheme.onSurfaceVariant)),
              const SizedBox(width: 10),
              DropdownButton<String>(
                value:
                    kResolutions.contains(_resolution) ? _resolution : '1080',
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
            style: TextStyle(
                fontSize: 12.5,
                height: 1.5,
                color: Theme.of(context).colorScheme.onSurfaceVariant),
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
          style: TextStyle(
              fontSize: 13.5,
              height: 1.65,
              color: Theme.of(context).colorScheme.onSurfaceVariant),
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
    final shown =
        open ? group.episodes : group.episodes.take(kEpisodesShown).toList();
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
                style: const TextStyle(
                    fontSize: 15.5, fontWeight: FontWeight.w800),
              ),
              const SizedBox(width: 8),
              Text(
                '${group.episodes.length} 集',
                style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final episode in shown) _episodeChip(detail, episode)
          ],
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
    Color foreground = Theme.of(context).colorScheme.onSurface;
    IconData? icon;

    if (episode.local) {
      background = AgpColors.accentSoft;
      icon = onPhone ? Icons.smartphone_rounded : Icons.check_rounded;
    } else if (queued) {
      background = const Color(0x241B5E8F);
      icon = Icons.play_arrow_rounded;
    } else {
      background = Theme.of(context).colorScheme.surfaceContainerHighest;
      foreground = Theme.of(context).colorScheme.onSurfaceVariant;
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
            color: episode.local
                ? AgpColors.accent.withValues(alpha: 0.5)
                : Theme.of(context).dividerColor,
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
              style: TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w600, color: foreground),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _episodeMenu(SeriesInfo detail, SeriesEpisode episode) async {
    final onPhone = state.downloads.isDownloaded(episode.videoSn);
    final waiting =
        state.downloads.entryFor(episode.videoSn)?.waitingForServer ?? false;
    // 伺服器上沒有的集數也給得出這個選項, 只是要先請伺服器抓 —— 但那需要
    // 管理員權限, 沒有的話就把它擺出來標成不能按, 而不是整個藏起來
    final phoneBlocked = !episode.local && !state.canManage;

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
            ListTile(
              leading: const Icon(Icons.smartphone_rounded),
              title: Text(onPhone
                  ? '已下載到手機'
                  : waiting
                      ? '等待伺服器下載完成'
                      : '下載單集到手機'),
              subtitle: phoneBlocked
                  ? const Text('伺服器上還沒有這一集，需要管理員權限')
                  : (!episode.local && !onPhone && !waiting)
                      ? const Text('伺服器上還沒有這一集，抓完會自動存到手機')
                      : null,
              enabled: !onPhone && !waiting && !phoneBlocked,
              onTap: () {
                Navigator.of(sheetContext).pop();
                if (episode.local) {
                  _saveToPhone(episode, detail);
                } else {
                  _saveToPhoneViaServer(episode, detail);
                }
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

/// 選集下載到手機.
///
/// 一次挑好幾集是這支 app 才有的需求 (網頁版沒有離線), 所以介面自己長一套:
/// 每一組集數一排方格, 按下去就是勾選, 底下顯示挑了幾集. 伺服器上還沒有的
/// 集數也挑得起來 —— 確認之後會先幫它們各排一個伺服器任務.
class _EpisodePickerSheet extends StatefulWidget {
  const _EpisodePickerSheet({
    required this.state,
    required this.detail,
    required this.resolution,
  });

  final AppState state;
  final SeriesInfo detail;
  final String resolution;

  @override
  State<_EpisodePickerSheet> createState() => _EpisodePickerSheetState();
}

class _EpisodePickerSheetState extends State<_EpisodePickerSheet> {
  final Set<String> _picked = {};
  late String _resolution = widget.resolution;
  late bool _danmaku = widget.state.prefs.downloadDanmaku;
  bool _working = false;
  String _progress = '';

  AppState get state => widget.state;
  SeriesInfo get detail => widget.detail;

  /// 已經在手機上 (或正在抓) 的集數不列入可挑範圍
  bool _taken(SeriesEpisode episode) {
    final entry = state.downloads.entryFor(episode.videoSn);
    return entry != null && entry.status != DownloadStatus.failed;
  }

  Iterable<SeriesEpisode> get _selectable =>
      detail.allEpisodes.where((e) => !_taken(e));

  void _selectAll({bool onlyLocal = false}) {
    setState(() {
      _picked
        ..clear()
        ..addAll(_selectable
            .where((e) => !onlyLocal || e.local)
            .map((e) => e.videoSn));
    });
  }

  Future<void> _confirm() async {
    final picks =
        detail.allEpisodes.where((e) => _picked.contains(e.videoSn)).toList();
    if (picks.isEmpty) return;

    final needServer = picks.where((e) => !e.local).toList();
    if (needServer.isNotEmpty && !state.canManage) {
      toast(context, '其中有伺服器上還沒有的集數，需要管理員權限。');
      return;
    }

    setState(() => _working = true);
    var queued = 0;
    var failed = 0;

    for (final episode in picks) {
      if (!mounted) return;
      setState(() => _progress = '${queued + failed + 1}/${picks.length}');
      final video = state.videoOf(episode.videoSn) ??
          VideoItem(
            sn: episode.videoSn,
            animeName: detail.title,
            episode: episode.episode,
            title: detail.title,
            resolution: episode.resolution > 0
                ? episode.resolution
                : int.tryParse(_resolution) ?? 0,
            danmu: true,
          );

      if (episode.local) {
        await state.downloads.enqueue(video, withDanmaku: _danmaku);
        queued += 1;
        continue;
      }

      // 一集一個 POST, 而且中間留一點空隙: /manualTask 每一筆都要現去巴哈
      // 解析一次, 一口氣灌幾十筆只是讓伺服器排隊排更久
      try {
        await state.startServerDownload(
          episode.videoSn,
          resolution: _resolution,
          mode: 'single',
        );
        state.queued.add(episode.videoSn);
        await state.downloads.enqueueWaiting(video, withDanmaku: _danmaku);
        queued += 1;
      } catch (_) {
        failed += 1;
      }
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }

    if (!mounted) return;
    Navigator.of(context).pop();
    toast(
      context,
      failed == 0
          ? '已加入 $queued 集到手機下載佇列。'
          : '已加入 $queued 集，$failed 集排不進伺服器佇列。',
    );
  }

  @override
  Widget build(BuildContext context) {
    final selectable = _selectable.length;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 12, 18, 0),
          child: Row(
            children: [
              const Expanded(
                child: Text(
                  '選集下載到手機',
                  style: TextStyle(fontSize: 16.5, fontWeight: FontWeight.w800),
                ),
              ),
              IconButton(
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close_rounded),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18),
          child: Wrap(
            spacing: 8,
            children: [
              TextButton(
                onPressed: selectable == 0 ? null : () => _selectAll(),
                child: const Text('全選'),
              ),
              TextButton(
                onPressed: _picked.isEmpty
                    ? null
                    : () => setState(() => _picked.clear()),
                child: const Text('全不選'),
              ),
              TextButton(
                onPressed:
                    selectable == 0 ? null : () => _selectAll(onlyLocal: true),
                child: const Text('只選伺服器上有的'),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListenableBuilder(
            listenable: state.downloads,
            builder: (context, _) => ListView(
              padding: const EdgeInsets.fromLTRB(18, 4, 18, 18),
              children: [
                for (final group in detail.groups) ...[
                  Padding(
                    padding: const EdgeInsets.only(top: 14, bottom: 10),
                    child: Text(
                      '${group.name}  ·  ${group.episodes.length} 集',
                      style: const TextStyle(
                          fontSize: 14.5, fontWeight: FontWeight.w700),
                    ),
                  ),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final episode in group.episodes) _pickChip(episode),
                    ],
                  ),
                ],
                if (detail.groups.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 20),
                    child: Text('這部作品沒有集數資訊。',
                        style: TextStyle(
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant)),
                  ),
              ],
            ),
          ),
        ),
        _footer(),
      ],
    );
  }

  Widget _pickChip(SeriesEpisode episode) {
    final taken = _taken(episode);
    final on = _picked.contains(episode.videoSn);
    final label = episode.episode.isNotEmpty ? episode.episode : '?';

    Color background;
    Color foreground;
    if (taken) {
      background = Theme.of(context).colorScheme.surfaceContainerHighest;
      foreground = Theme.of(context).colorScheme.onSurfaceVariant;
    } else if (on) {
      background = AgpColors.accentSoft;
      foreground = Theme.of(context).colorScheme.onSurface;
    } else {
      background = Theme.of(context).colorScheme.surfaceContainerHighest;
      foreground = episode.local
          ? Theme.of(context).colorScheme.onSurface
          : Theme.of(context).colorScheme.onSurfaceVariant;
    }

    return InkWell(
      borderRadius: BorderRadius.circular(kRadiusSmall),
      onTap: taken || _working
          ? null
          : () => setState(() {
                if (!_picked.add(episode.videoSn)) {
                  _picked.remove(episode.videoSn);
                }
              }),
      child: Container(
        constraints: const BoxConstraints(minWidth: 56),
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(kRadiusSmall),
          border: Border.all(
            color: on
                ? AgpColors.accent.withValues(alpha: 0.6)
                : Theme.of(context).dividerColor,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              taken
                  ? Icons.smartphone_rounded
                  : on
                      ? Icons.check_box_rounded
                      : Icons.check_box_outline_blank_rounded,
              size: 14,
              color: foreground,
            ),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w600, color: foreground),
            ),
            // 伺服器上還沒有的集數要標出來: 挑了它就是連伺服器任務一起排
            if (!taken && !episode.local) ...[
              const SizedBox(width: 4),
              Icon(Icons.cloud_download_outlined, size: 12, color: foreground),
            ],
          ],
        ),
      ),
    );
  }

  Widget _footer() {
    final serverCount = detail.allEpisodes
        .where((e) => _picked.contains(e.videoSn) && !e.local)
        .length;

    return Container(
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 16),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: Theme.of(context).dividerColor)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('下載畫質',
                    style: TextStyle(
                        fontSize: 13,
                        color: Theme.of(context).colorScheme.onSurfaceVariant)),
                const SizedBox(width: 8),
                DropdownButton<String>(
                  value:
                      kResolutions.contains(_resolution) ? _resolution : '1080',
                  underline: const SizedBox.shrink(),
                  borderRadius: BorderRadius.circular(kRadiusSmall),
                  items: [
                    for (final value in kResolutions)
                      DropdownMenuItem(value: value, child: Text('${value}P')),
                  ],
                  onChanged: _working
                      ? null
                      : (value) {
                          if (value == null) return;
                          setState(() => _resolution = value);
                          state.prefs.setDownloadResolution(value);
                        },
                ),
                const Spacer(),
                Text('一起抓彈幕',
                    style: TextStyle(
                        fontSize: 13,
                        color: Theme.of(context).colorScheme.onSurfaceVariant)),
                Switch(
                  value: _danmaku,
                  onChanged: _working
                      ? null
                      : (value) => setState(() => _danmaku = value),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (serverCount > 0)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  '其中 $serverCount 集伺服器上還沒有，會先請伺服器下載，抓完自動存到手機。',
                  style: TextStyle(
                      fontSize: 12,
                      height: 1.5,
                      color: Theme.of(context).colorScheme.onSurfaceVariant),
                ),
              ),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _picked.isEmpty || _working ? null : _confirm,
                child: Text(_working
                    ? '加入中… $_progress'
                    : _picked.isEmpty
                        ? '選一些集數'
                        : '下載 ${_picked.length} 集到手機'),
              ),
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
        side: BorderSide(
            color: on ? AgpColors.accent : Theme.of(context).dividerColor),
      ),
      icon:
          Icon(on ? Icons.favorite_rounded : Icons.favorite_outline, size: 17),
      label: Text(on ? '已收藏' : '收藏'),
    );
  }
}
