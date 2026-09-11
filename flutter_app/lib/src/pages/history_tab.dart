/// 觀看紀錄 —— 跟著帳號走的那一份 /watch/time.
///
/// 片庫裡沒有的集數只認得出 sn, 所以會去問 /watch/series.json 把作品名補回來;
/// 一次最多問 8 部, 免得紀錄裡有幾十部沒下載的作品時打出幾十個請求.
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
import 'login_page.dart';
import 'watch_page.dart';

const int kHistoryLookups = 8;
const int kHistoryRows = 200;

class _Remote {
  const _Remote({required this.name, required this.episode, required this.cover});

  final String name;
  final String episode;
  final String cover;

  factory _Remote.fromJson(Map<String, dynamic> json) => _Remote(
        name: (json['name'] ?? '').toString(),
        episode: (json['episode'] ?? '').toString(),
        cover: (json['cover'] ?? '').toString(),
      );

  Map<String, dynamic> toJson() =>
      {'name': name, 'episode': episode, 'cover': cover};
}

/// 問過的作品留著, 換分頁再回來不用重問
final Map<String, _Remote?> _remote = {};

/// 落盤那一份的鍵. 認得出來的名字存起來, 下次開 app 這一頁就不必再打
/// 八次 /watch/series.json —— 那是每次冷啟動之後最先塞住連線的一批請求.
const String _kNameCacheKey = 'history-names';
bool _nameCacheLoaded = false;

void _loadNameCache(AppState state) {
  if (_nameCacheLoaded) return;
  _nameCacheLoaded = true;
  final raw = state.prefs.readCachedJson(_kNameCacheKey);
  if (raw is! Map) return;
  raw.forEach((key, value) {
    if (value is Map) {
      _remote.putIfAbsent(
          key.toString(), () => _Remote.fromJson(value.cast<String, dynamic>()));
    }
  });
}

/// 只存真的認出來的那些. 認不出來的下次還是要再試一次 —— 那多半是當時
/// 連不上, 不是這一集永遠查不到.
Future<void> _saveNameCache(AppState state) {
  final known = <String, dynamic>{};
  for (final entry in _remote.entries) {
    final value = entry.value;
    if (value != null) known[entry.key] = value.toJson();
  }
  return state.prefs.cacheJson(_kNameCacheKey, known);
}

class HistoryTab extends StatefulWidget {
  const HistoryTab({super.key, required this.state});

  final AppState state;

  @override
  State<HistoryTab> createState() => _HistoryTabState();
}

class _HistoryTabState extends State<HistoryTab> {
  bool _resolving = false;

  AppState get state => widget.state;

  List<MapEntry<String, WatchTime>> get _rows {
    final rows = state.watchTimes.entries.toList()
      ..sort((a, b) => b.value.timestamp.compareTo(a.value.timestamp));
    return rows.take(kHistoryRows).toList();
  }

  Future<void> _resolve(List<MapEntry<String, WatchTime>> rows) async {
    if (_resolving) return;
    _resolving = true;
    var found = false;
    try {
      var tries = 0;
      while (tries < kHistoryLookups) {
        String? pending;
        for (final row in rows) {
          if (state.videoOf(row.key) == null && !_remote.containsKey(row.key)) {
            pending = row.key;
            break;
          }
        }
        if (pending == null) break;
        tries++;
        try {
          final detail = await state.loadSeries(pending);
          for (final group in detail.groups) {
            for (final episode in group.episodes) {
              _remote[episode.videoSn] = _Remote(
                name: detail.title,
                episode: episode.episode,
                cover: detail.cover.isNotEmpty ? detail.cover : episode.cover,
              );
            }
          }
          found = true;
        } catch (_) {
          // 認不出來就認不出來, 那一列還是列得出日期
        }
        // 問過了就標記, 不然這一集永遠排在隊伍最前面把次數用光
        _remote.putIfAbsent(pending, () => null);
      }
    } finally {
      _resolving = false;
    }
    if (!found) return;
    unawaited(_saveNameCache(state));
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    _loadNameCache(state);
  }

  @override
  Widget build(BuildContext context) {
    if (state.serverInfo.userControl && !state.loggedIn) {
      return EmptyState(
        icon: Icons.person_outline,
        title: '觀看紀錄跟著帳號走',
        message: '登入之後這裡才會有東西。',
        actionLabel: '前往登入',
        onAction: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => LoginPage(state: state)),
        ),
      );
    }

    final rows = _rows;
    if (rows.isEmpty) {
      return const EmptyState(
        icon: Icons.history_rounded,
        title: '還沒有任何觀看紀錄',
        message: '看過的集數會留在這裡，換裝置也找得回來。',
      );
    }

    if (rows.any((row) =>
        state.videoOf(row.key) == null && !_remote.containsKey(row.key))) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _resolve(rows));
    }

    // 依「年月」分段, 跟網頁版一樣
    final children = <Widget>[];
    var month = '';
    for (final row in rows) {
      final label = _monthLabel(row.value.timestamp);
      if (label != month) {
        month = label;
        children.add(Padding(
          padding: const EdgeInsets.fromLTRB(16, 18, 16, 4),
          child: Text(
            label,
            style: const TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
              color: AgpColors.fgFaint,
            ),
          ),
        ));
      }
      children.add(_row(row.key, row.value));
    }

    return RefreshIndicator(
      onRefresh: state.refreshWatchTimes,
      child: ListView(
        padding: const EdgeInsets.only(bottom: 26),
        children: children,
      ),
    );
  }

  static String _monthLabel(int timestamp) {
    if (timestamp <= 0) return '更早以前';
    final when = DateTime.fromMillisecondsSinceEpoch(timestamp * 1000);
    return '${when.year}年${when.month.toString().padLeft(2, '0')}月';
  }

  static String _dayStamp(int timestamp) {
    if (timestamp <= 0) return '';
    final when = DateTime.fromMillisecondsSinceEpoch(timestamp * 1000);
    return '${when.month.toString().padLeft(2, '0')}/${when.day.toString().padLeft(2, '0')}';
  }

  Widget _row(String sn, WatchTime entry) {
    final video = state.videoOf(sn);
    final remote = _remote[sn];
    final local = video != null;
    final name = video?.displayName ?? remote?.name ?? '未知作品';
    final episode = video?.episode ?? remote?.episode ?? '';

    final ratio = entry.ended
        ? 1.0
        : (entry.duration > 0
            ? (entry.time / entry.duration).clamp(0.0, 0.99)
            : 0.0);
    final stamp = _dayStamp(entry.timestamp);
    final where = entry.ended
        ? '已看完${episode.isNotEmpty ? ' ${episodeLabel(episode)}' : ''}'
        : (episode.isNotEmpty
            ? '觀看至 ${episodeLabel(episode)}'
            : '觀看至 ${formatClock(entry.time)}');

    return EpisodeRow(
      title: name,
      subtitle: '${stamp.isEmpty ? '' : '$stamp '}$where',
      coverFile: state.downloads.localThumb(sn),
      thumbSn: local ? sn : null,
      thumbStore: state.thumbnails,
      cover:
          local ? null : (remote?.cover.isNotEmpty == true ? remote!.cover : null),
      progress: ratio.toDouble(),
      onTap: () {
        if (local) {
          Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => WatchPage(state: state, sn: sn),
          ));
        } else {
          showAnimeSheet(context, state, videoSn: sn, title: name);
        }
      },
      trailing: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: '刪除這筆紀錄',
            icon: const Icon(Icons.close_rounded, size: 18),
            onPressed: () async {
              await state.forgetWatchTime(sn);
              if (mounted) toast(context, '已刪除這筆紀錄');
            },
          ),
          IconButton(
            tooltip: local ? '繼續播放' : '邊看邊下載',
            icon: const Icon(Icons.play_circle_outline, size: 22),
            onPressed: () {
              if (local) {
                Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => WatchPage(state: state, sn: sn),
                ));
              } else {
                showAnimeSheet(context, state, videoSn: sn, title: name);
              }
            },
          ),
        ],
      ),
    );
  }
}
