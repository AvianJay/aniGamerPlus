/// 首頁 —— 對應網頁版 paneHome 的那一疊區塊:
/// 繼續觀看 / 本季新番 / 更新時間表 / 近期熱播 / 最新上架 / 片庫更新 / 片庫熱門.
library;

import 'package:flutter/material.dart';

import '../api/models.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../util/format.dart';
import '../widgets/cards.dart';
import '../widgets/common.dart';
import 'anime_sheet.dart';
import 'login_page.dart';
import 'watch_page.dart';

/// 片庫更新最多列幾天 (home.js 的 TIMETABLE_DAYS)
const int kTimetableDays = 7;

class HomeTab extends StatelessWidget {
  const HomeTab({super.key, required this.state, required this.onSeeAll});

  final AppState state;
  final VoidCallback onSeeAll;

  @override
  Widget build(BuildContext context) {
    if (state.booting && state.library.isEmpty && state.catalog.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (state.needsLogin && state.library.isEmpty) {
      return EmptyState(
        icon: Icons.lock_outline,
        title: '需要登入',
        message: '這台伺服器要求登入後才能瀏覽片庫。',
        actionLabel: '前往登入',
        onAction: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => LoginPage(state: state)),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: state.refreshAll,
      child: ListView(
        padding: const EdgeInsets.only(bottom: 26),
        children: [
          _notice(context),
          ..._continueSection(context),
          ..._seasonSection(context),
          ..._scheduleSection(context),
          ..._catalogRail(context, '近期熱播', state.catalog.hot, ranked: true),
          ..._catalogRail(context, '最新上架', state.catalog.newAdded),
          ..._libraryUpdates(context),
          ..._libraryHot(context),
        ],
      ),
    );
  }

  // ------------------------------------------------------------------ 提示條

  Widget _notice(BuildContext context) {
    final animes = state.animeHeads.length;
    final episodes = state.library.length;
    final newest = state.library.isNotEmpty ? state.library.first.addedAt : null;

    var text = '片庫收錄 $animes 部作品、$episodes 集';
    if (newest != null) {
      text += '，最後更新於 ${dayLabel(newest)} ${clockOf(newest)}';
    }
    text += '。';

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 2),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: Theme.of(context).cardTheme.color,
          borderRadius: BorderRadius.circular(kRadius),
          border: Border.all(color: AgpColors.line),
        ),
        child: Row(
          children: [
            const Icon(Icons.video_library_outlined, size: 18, color: AgpColors.accent),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                state.offline ? '離線模式 · 只顯示已下載到手機的集數。' : text,
                style: const TextStyle(fontSize: 13, height: 1.4, color: AgpColors.fgDim),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- 繼續觀看

  List<Widget> _continueSection(BuildContext context) {
    final items = state.continueWatching.take(20).toList();
    if (items.isEmpty) {
      return [
        const SectionHeader(title: '繼續觀看'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            state.loggedIn || !state.serverInfo.userControl
                ? '還沒有看到一半的影片。'
                : '登入後即可跨裝置同步觀看進度。',
            style: const TextStyle(fontSize: 13, color: AgpColors.fgFaint),
          ),
        ),
      ];
    }

    return [
      const SectionHeader(title: '繼續觀看'),
      Rail(
        height: 168,
        itemWidth: 208,
        itemCount: items.length,
        itemBuilder: (context, index) {
          final video = items[index];
          final watched = state.watchTimeOf(video.sn);
          final remaining = watched != null && watched.duration > 0
              ? '剩餘 ${(watched.duration - watched.time) ~/ 60 + 1} 分'
              : '已看到 ${formatClock(watched?.time ?? 0)}';
          final next = _nextEpisode(video);

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: EpisodeCard(
                  video: video,
                  state: state,
                  onTap: () => _watch(context, video.sn),
                  onLongPress: () => _libraryMenu(context, video),
                ),
              ),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      remaining,
                      style: const TextStyle(fontSize: 11, color: AgpColors.accent),
                    ),
                  ),
                  if (next != null)
                    InkWell(
                      onTap: () => _watch(context, next.sn),
                      child: const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                        child: Text(
                          '下一集 ▸',
                          style: TextStyle(fontSize: 11, color: AgpColors.fgDim),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          );
        },
      ),
    ];
  }

  VideoItem? _nextEpisode(VideoItem video) {
    final current = double.tryParse(video.episode);
    if (current == null) return null;
    VideoItem? best;
    double? bestNumber;
    for (final candidate in state.episodesOf(video.animeName)) {
      final number = double.tryParse(candidate.episode);
      if (number == null || number <= current) continue;
      if (bestNumber == null || number < bestNumber) {
        bestNumber = number;
        best = candidate;
      }
    }
    return best;
  }

  // ---------------------------------------------------------------- 本季新番

  List<Widget> _seasonSection(BuildContext context) {
    final items = state.catalog.season;
    if (items.isEmpty) return const [];
    return [
      const SectionHeader(title: '本季新番'),
      Rail(
        height: 176,
        itemWidth: 232,
        itemCount: items.length,
        itemBuilder: (context, index) {
          final item = items[index];
          return PosterCard(
            aspectRatio: 16 / 9,
            title: item.title,
            cover: item.cover.isEmpty ? null : item.cover,
            subtitle: item.info,
            badge: item.volume.isEmpty ? null : item.volume,
            onTap: () => _openAnime(context, item),
          );
        },
      ),
    ];
  }

  // -------------------------------------------------------------- 更新時間表

  List<Widget> _scheduleSection(BuildContext context) {
    final days = state.catalog.schedule;
    if (days.isEmpty) return const [];
    return [
      const SectionHeader(title: '更新時間表'),
      _Schedule(days: days, onTap: (row) => _openSchedule(context, row)),
    ];
  }

  // -------------------------------------------------- 近期熱播 / 最新上架

  List<Widget> _catalogRail(
    BuildContext context,
    String title,
    List<CatalogItem> items, {
    bool ranked = false,
  }) {
    if (items.isEmpty) return const [];
    return [
      SectionHeader(title: title, actionLabel: '所有動畫', onAction: onSeeAll),
      Rail(
        height: 232,
        itemWidth: 128,
        itemCount: items.length,
        itemBuilder: (context, index) {
          final item = items[index];
          return PosterCard(
            title: item.title,
            cover: item.cover.isEmpty ? null : item.cover,
            subtitle: [
              if (item.info.isNotEmpty) item.info else item.volume,
              if (item.popular.isNotEmpty) item.popular,
            ].where((t) => t.isNotEmpty).join(' · '),
            rank: ranked ? index + 1 : null,
            onTap: () => _openAnime(context, item),
          );
        },
      ),
    ];
  }

  // ---------------------------------------------------------------- 片庫更新

  List<Widget> _libraryUpdates(BuildContext context) {
    if (state.library.isEmpty) {
      return [
        const SectionHeader(title: '片庫更新'),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            '片庫還沒有任何影片，先到主控台加入追番清單吧。',
            style: TextStyle(fontSize: 13, color: AgpColors.fgFaint),
          ),
        ),
      ];
    }

    final groups = <String, List<VideoItem>>{};
    final order = <String>[];
    for (final video in state.library) {
      final at = video.addedAt;
      if (at == null) continue;
      final key = dayKey(at);
      if (!groups.containsKey(key)) {
        groups[key] = [];
        order.add(key);
      }
      groups[key]!.add(video);
    }

    final widgets = <Widget>[const SectionHeader(title: '片庫更新')];
    for (final key in order.take(kTimetableDays)) {
      final videos = groups[key]!;
      final when = videos.first.addedAt!;
      widgets.add(Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Row(
          children: [
            Text(
              dayLabel(when),
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
            ),
            const SizedBox(width: 8),
            Text(
              '${videos.length} 集更新',
              style: const TextStyle(fontSize: 11.5, color: AgpColors.fgFaint),
            ),
          ],
        ),
      ));
      widgets.add(Rail(
        height: 148,
        itemWidth: 196,
        itemCount: videos.length > 20 ? 20 : videos.length,
        itemBuilder: (context, index) => EpisodeCard(
          video: videos[index],
          state: state,
          onTap: () => _watch(context, videos[index].sn),
          onLongPress: () => _libraryMenu(context, videos[index]),
        ),
      ));
    }
    return widgets;
  }

  // ---------------------------------------------------------------- 片庫熱門

  List<Widget> _libraryHot(BuildContext context) {
    final heads = state.animeHeads;
    if (heads.isEmpty) return const [];

    final counted = heads
        .map((head) => MapEntry(head, state.episodesOf(head.animeName).length))
        .toList()
      ..sort((a, b) {
        final byCount = b.value.compareTo(a.value);
        if (byCount != 0) return byCount;
        return b.key.timestamp.compareTo(a.key.timestamp);
      });
    final top = counted.take(12).toList();

    return [
      const SectionHeader(title: '片庫熱門'),
      Rail(
        height: 232,
        itemWidth: 128,
        itemCount: top.length,
        itemBuilder: (context, index) {
          final video = top[index].key;
          return PosterCard(
            title: video.displayName,
            cover: state.offline ? null : state.client.thumbnailUrl(video.sn).toString(),
            subtitle: '${top[index].value} 集',
            rank: index + 1,
            onTap: () => showAnimeSheet(
              context,
              state,
              videoSn: video.sn,
              title: video.displayName,
            ),
          );
        },
      ),
    ];
  }

  // -------------------------------------------------------------------- 動作

  void _watch(BuildContext context, String sn) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => WatchPage(state: state, sn: sn),
    ));
  }

  void _openAnime(BuildContext context, CatalogItem item) {
    showAnimeSheet(
      context,
      state,
      animeSn: item.animeSn,
      videoSn: item.videoSn,
      title: item.title,
      cover: item.cover,
    );
  }

  void _openSchedule(BuildContext context, ScheduleRow row) {
    if (row.animeSn.isEmpty && row.videoSn.isEmpty) return;
    showAnimeSheet(
      context,
      state,
      animeSn: row.animeSn,
      videoSn: row.videoSn,
      title: row.title,
      cover: row.cover,
    );
  }

  Future<void> _libraryMenu(BuildContext context, VideoItem video) =>
      showLibraryMenu(context, state, video);
}

/// 片庫卡片長按 —— 播放 / 下載到手機 / 作品資訊 / 忘掉進度
Future<void> showLibraryMenu(
  BuildContext context,
  AppState state,
  VideoItem video,
) {
  return showModalBottomSheet<void>(
    context: context,
    builder: (sheetContext) => SafeArea(
      child: ListenableBuilder(
        listenable: state.downloads,
        builder: (context, _) {
          final entry = state.downloads.entryFor(video.sn);
          final downloaded = entry?.playable ?? false;
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                title: Text(
                  '${video.displayName} · ${episodeLabel(video.episode)}',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                subtitle: video.resolution > 0 ? Text('${video.resolution}P') : null,
              ),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.play_arrow_rounded),
                title: const Text('播放'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => WatchPage(state: state, sn: video.sn),
                  ));
                },
              ),
              ListTile(
                leading: Icon(downloaded
                    ? Icons.download_done_rounded
                    : Icons.smartphone_rounded),
                title: Text(downloaded ? '已下載到手機' : '下載到手機'),
                subtitle: entry != null && !downloaded
                    ? Text('${(entry.progress * 100).round()}% · ${entry.status.name}')
                    : null,
                enabled: !downloaded,
                onTap: () async {
                  Navigator.of(sheetContext).pop();
                  await state.downloads
                      .enqueue(video, withDanmaku: state.prefs.downloadDanmaku);
                  if (context.mounted) toast(context, '已加入手機下載佇列。');
                },
              ),
              ListTile(
                leading: const Icon(Icons.info_outline),
                title: const Text('作品資訊'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  showAnimeSheet(
                    context,
                    state,
                    videoSn: video.sn,
                    title: video.displayName,
                  );
                },
              ),
              if (state.watchTimeOf(video.sn) != null)
                ListTile(
                  leading: const Icon(Icons.history_toggle_off_rounded),
                  title: const Text('清除這一集的觀看紀錄'),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    state.forgetWatchTime(video.sn);
                  },
                ),
            ],
          );
        },
      ),
    ),
  );
}

class _Schedule extends StatefulWidget {
  const _Schedule({required this.days, required this.onTap});

  final List<ScheduleDay> days;
  final void Function(ScheduleRow row) onTap;

  @override
  State<_Schedule> createState() => _ScheduleState();
}

class _ScheduleState extends State<_Schedule> {
  late int _weekday = bahamutWeekday(DateTime.now());

  @override
  Widget build(BuildContext context) {
    final days = widget.days;
    ScheduleDay today = days.first;
    for (final day in days) {
      if (day.weekday == _weekday) {
        today = day;
        break;
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 42,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: days.length,
            separatorBuilder: (_, __) => const SizedBox(width: 8),
            itemBuilder: (context, index) {
              final day = days[index];
              final on = day.weekday == today.weekday;
              return GestureDetector(
                onTap: () => setState(() => _weekday = day.weekday),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: on ? AgpColors.accent : Colors.white10,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    '${day.label} ${day.episodes.length}',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: on ? Colors.white : AgpColors.fgDim,
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 10),
        if (today.episodes.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              '這天沒有排定更新。',
              style: TextStyle(fontSize: 13, color: AgpColors.fgFaint),
            ),
          )
        else
          for (final row in today.episodes)
            InkWell(
              onTap: () => widget.onTap(row),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
                child: Row(
                  children: [
                    SizedBox(
                      width: 44,
                      child: Text(
                        row.time,
                        style: const TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                          color: AgpColors.accent,
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 56,
                      child: CoverImage(
                        name: row.title,
                        url: row.cover.isEmpty ? null : row.cover,
                        aspectRatio: 3 / 4,
                      ),
                    ),
                    const SizedBox(width: 11),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            row.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 13.5, fontWeight: FontWeight.w700),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            row.volume,
                            style: const TextStyle(
                                fontSize: 11.5, color: AgpColors.fgFaint),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
      ],
    );
  }
}
