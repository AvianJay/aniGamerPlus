/// Dashboard/Server.py 端出來的那幾份 JSON 的 Dart 對應.
///
/// 欄位名一律照抄伺服器, 不改寫成 camelCase 以外的東西 —— 兩邊對不上的時候
/// 才能一眼看出是哪一邊漏了.
library;

String _s(dynamic value) => value == null ? '' : value.toString();

int _i(dynamic value) {
  if (value is int) return value;
  if (value is double) return value.round();
  return int.tryParse(_s(value)) ?? 0;
}

bool _b(dynamic value) {
  if (value is bool) return value;
  final text = _s(value).toLowerCase();
  return text == 'true' || text == '1';
}

/// /video_list.json 的一筆 (也就是本機片庫裡的一集)
class VideoItem {
  final String sn;
  final String title;
  final String animeName;
  final String episode;
  final int resolution;
  final String path;
  final String source;
  final int timestamp;
  final bool danmu;

  /// 邊看邊下載: 這一集還在下載中, 播放要走 HLS
  final bool streaming;

  /// 剛按下下載, 進度紀錄都還沒建立
  final bool pending;

  VideoItem({
    required this.sn,
    this.title = '',
    this.animeName = '',
    this.episode = '',
    this.resolution = 0,
    this.path = '',
    this.source = '',
    this.timestamp = 0,
    this.danmu = false,
    this.streaming = false,
    this.pending = false,
  });

  factory VideoItem.fromJson(Map<String, dynamic> json) => VideoItem(
        sn: _s(json['sn']),
        title: _s(json['title']),
        animeName: _s(json['anime_name']),
        episode: _s(json['episode']),
        resolution: _i(json['resolution']),
        path: _s(json['path']),
        source: _s(json['source']),
        timestamp: _i(json['timestamp']),
        danmu: _b(json['danmu']),
        streaming: _b(json['streaming']),
        pending: _b(json['pending']),
      );

  Map<String, dynamic> toJson() => {
        'sn': sn,
        'title': title,
        'anime_name': animeName,
        'episode': episode,
        'resolution': resolution,
        'path': path,
        'source': source,
        'timestamp': timestamp,
        'danmu': danmu,
        'streaming': streaming,
        'pending': pending,
      };

  VideoItem copyWith({
    int? resolution,
    bool? danmu,
    bool? streaming,
    bool? pending,
  }) =>
      VideoItem(
        sn: sn,
        title: title,
        animeName: animeName,
        episode: episode,
        resolution: resolution ?? this.resolution,
        path: path,
        source: source,
        timestamp: timestamp,
        danmu: danmu ?? this.danmu,
        streaming: streaming ?? this.streaming,
        pending: pending ?? this.pending,
      );

  /// 顯示用的作品名: 片庫沒填 anime_name 的話退回標題
  String get displayName => animeName.isNotEmpty ? animeName : title;

  DateTime? get addedAt => timestamp > 0
      ? DateTime.fromMillisecondsSinceEpoch(timestamp * 1000)
      : null;
}

/// /catalog/*.json 的卡片
class CatalogItem {
  final String animeSn;
  final String acgSn;
  final String videoSn;
  final String title;
  final String cover;
  final String info;
  final String volume;
  final String popular;

  CatalogItem({
    this.animeSn = '',
    this.acgSn = '',
    this.videoSn = '',
    this.title = '',
    this.cover = '',
    this.info = '',
    this.volume = '',
    this.popular = '',
  });

  factory CatalogItem.fromJson(Map<String, dynamic> json) => CatalogItem(
        animeSn: _s(json['animeSn']),
        acgSn: _s(json['acgSn']),
        videoSn: _s(json['videoSn']),
        title: _s(json['title']),
        cover: _s(json['cover']),
        info: _s(json['info']),
        volume: _s(json['volume']),
        popular: _s(json['popular']),
      );
}

/// 更新時間表的一行
class ScheduleRow {
  final String videoSn;
  final String animeSn;
  final String cover;
  final String title;
  final String time;
  final String volume;

  ScheduleRow({
    this.videoSn = '',
    this.animeSn = '',
    this.cover = '',
    this.title = '',
    this.time = '',
    this.volume = '',
  });

  factory ScheduleRow.fromJson(Map<String, dynamic> json) => ScheduleRow(
        videoSn: _s(json['videoSn']),
        animeSn: _s(json['animeSn']),
        cover: _s(json['cover']),
        title: _s(json['title']),
        time: _s(json['time']),
        volume: _s(json['volume']),
      );
}

class ScheduleDay {
  final int weekday;
  final String label;
  final List<ScheduleRow> episodes;

  ScheduleDay({required this.weekday, required this.label, required this.episodes});

  factory ScheduleDay.fromJson(Map<String, dynamic> json) => ScheduleDay(
        weekday: _i(json['weekday']),
        label: _s(json['label']),
        episodes: ((json['episodes'] as List?) ?? [])
            .whereType<Map>()
            .map((e) => ScheduleRow.fromJson(e.cast<String, dynamic>()))
            .toList(),
      );
}

/// /catalog/index.json
class CatalogIndex {
  final List<CatalogItem> season;
  final List<ScheduleDay> schedule;
  final List<CatalogItem> hot;
  final List<CatalogItem> newAdded;

  CatalogIndex({
    this.season = const [],
    this.schedule = const [],
    this.hot = const [],
    this.newAdded = const [],
  });

  static List<CatalogItem> _cards(dynamic node) => ((node as List?) ?? [])
      .whereType<Map>()
      .map((e) => CatalogItem.fromJson(e.cast<String, dynamic>()))
      .toList();

  factory CatalogIndex.fromJson(Map<String, dynamic> json) => CatalogIndex(
        season: _cards(json['season']),
        hot: _cards(json['hot']),
        newAdded: _cards(json['newAdded']),
        schedule: ((json['schedule'] as List?) ?? [])
            .whereType<Map>()
            .map((e) => ScheduleDay.fromJson(e.cast<String, dynamic>()))
            .toList(),
      );

  bool get isEmpty =>
      season.isEmpty && hot.isEmpty && newAdded.isEmpty && schedule.isEmpty;
}

/// /catalog/all.json
class CatalogPage {
  final List<CatalogItem> items;
  final int page;
  final int pages;
  final int total;

  CatalogPage({
    this.items = const [],
    this.page = 1,
    this.pages = 1,
    this.total = 0,
  });

  factory CatalogPage.fromJson(Map<String, dynamic> json) => CatalogPage(
        items: CatalogIndex._cards(json['items']),
        page: _i(json['page']),
        pages: _i(json['pages']),
        total: _i(json['total']),
      );
}

/// 集數表裡的一集
class SeriesEpisode {
  final String videoSn;
  final String episode;
  final String cover;
  final bool local;
  final int resolution;

  SeriesEpisode({
    required this.videoSn,
    this.episode = '',
    this.cover = '',
    this.local = false,
    this.resolution = 0,
  });

  factory SeriesEpisode.fromJson(Map<String, dynamic> json) => SeriesEpisode(
        videoSn: _s(json['videoSn']),
        episode: _s(json['episode']),
        cover: _s(json['cover']),
        local: _b(json['local']),
        resolution: _i(json['resolution']),
      );
}

class SeriesGroup {
  final String name;
  final List<SeriesEpisode> episodes;

  SeriesGroup({required this.name, required this.episodes});

  factory SeriesGroup.fromJson(Map<String, dynamic> json) => SeriesGroup(
        name: _s(json['name']),
        episodes: ((json['episodes'] as List?) ?? [])
            .whereType<Map>()
            .map((e) => SeriesEpisode.fromJson(e.cast<String, dynamic>()))
            .toList(),
      );
}

/// /watch/series.json 與 /catalog/anime.json (兩邊同一個形狀)
class SeriesInfo {
  final String animeSn;
  final String videoSn;
  final String title;
  final String cover;
  final String content;
  final List<String> tags;
  final String director;
  final String publisher;
  final num score;
  final String seasonStart;
  final String popular;
  final String totalEpisode;
  final List<SeriesGroup> groups;

  SeriesInfo({
    this.animeSn = '',
    this.videoSn = '',
    this.title = '',
    this.cover = '',
    this.content = '',
    this.tags = const [],
    this.director = '',
    this.publisher = '',
    this.score = 0,
    this.seasonStart = '',
    this.popular = '',
    this.totalEpisode = '',
    this.groups = const [],
  });

  factory SeriesInfo.fromJson(Map<String, dynamic> json) => SeriesInfo(
        animeSn: _s(json['animeSn']),
        videoSn: _s(json['videoSn']),
        title: _s(json['title']),
        cover: _s(json['cover']),
        content: _s(json['content']),
        tags: ((json['tags'] as List?) ?? []).map(_s).where((t) => t.isNotEmpty).toList(),
        director: _s(json['director']),
        publisher: _s(json['publisher']),
        score: json['score'] is num ? json['score'] as num : num.tryParse(_s(json['score'])) ?? 0,
        seasonStart: _s(json['seasonStart']),
        popular: _s(json['popular']),
        totalEpisode: _s(json['totalEpisode']),
        groups: ((json['groups'] as List?) ?? [])
            .whereType<Map>()
            .map((e) => SeriesGroup.fromJson(e.cast<String, dynamic>()))
            .toList(),
      );

  List<SeriesEpisode> get allEpisodes =>
      [for (final group in groups) ...group.episodes];

  SeriesEpisode? episodeOf(String sn) {
    for (final episode in allEpisodes) {
      if (episode.videoSn == sn) return episode;
    }
    return null;
  }
}

/// /hls/status.json
class HlsStatus {
  /// none / parsing / streaming / finalising / file
  final String mode;
  final int ready;
  final int total;
  final double readyDuration;
  final double totalDuration;
  final double targetDuration;
  final String playlistId;
  final double rate;
  final String status;
  final int resolution;
  final bool danmu;

  HlsStatus({
    this.mode = 'none',
    this.ready = 0,
    this.total = 0,
    this.readyDuration = 0,
    this.totalDuration = 0,
    this.targetDuration = 10,
    this.playlistId = '',
    this.rate = 0,
    this.status = '',
    this.resolution = 0,
    this.danmu = false,
  });

  static double _d(dynamic value) {
    if (value is num) return value.toDouble();
    return double.tryParse(_s(value)) ?? 0;
  }

  factory HlsStatus.fromJson(Map<String, dynamic> json) => HlsStatus(
        mode: _s(json['mode']).isEmpty ? 'none' : _s(json['mode']),
        ready: _i(json['ready']),
        total: _i(json['total']),
        readyDuration: _d(json['readyDuration']),
        totalDuration: _d(json['totalDuration']),
        targetDuration: _d(json['targetDuration']) == 0 ? 10 : _d(json['targetDuration']),
        playlistId: _s(json['playlistId']),
        rate: _d(json['rate']),
        status: _s(json['status']),
        resolution: _i(json['resolution']),
        danmu: _b(json['danmu']),
      );
}

/// /watch/time 的一筆觀看進度
class WatchTime {
  final int time;
  final bool ended;
  final int duration;
  final int timestamp;

  WatchTime({this.time = 0, this.ended = false, this.duration = 0, this.timestamp = 0});

  factory WatchTime.fromJson(Map<String, dynamic> json) => WatchTime(
        time: _i(json['time']),
        ended: _b(json['ended']),
        duration: _i(json['duration']),
        timestamp: _i(json['timestamp']),
      );

  /// home.js 的 progressOf(): 沒有 duration 就不畫進度條, 這是刻意的 ——
  /// 用名目長度去猜只會畫出一條假的.
  double? get progress {
    if (duration <= 0) return null;
    if (ended) return 1;
    final value = time / duration;
    if (value.isNaN || value <= 0) return 0;
    return value > 1 ? 1 : value;
  }

  DateTime? get watchedAt =>
      timestamp > 0 ? DateTime.fromMillisecondsSinceEpoch(timestamp * 1000) : null;
}

/// /get_server_info
class ServerInfo {
  final bool userControl;
  final bool allowRegister;
  final bool onlineWatch;
  final bool onlineWatchRequiresLogin;

  ServerInfo({
    this.userControl = false,
    this.allowRegister = false,
    this.onlineWatch = true,
    this.onlineWatchRequiresLogin = false,
  });

  factory ServerInfo.fromJson(Map<String, dynamic> json) => ServerInfo(
        userControl: _b(json['user_control']),
        allowRegister: _b(json['user_control_allow_register']),
        onlineWatch: _b(json['online_watch']),
        onlineWatchRequiresLogin: _b(json['online_watch_requires_login']),
      );
}

class CurrentUser {
  final String username;
  final String role;

  CurrentUser({this.username = '', this.role = 'user'});

  bool get isAdmin => role == 'admin';

  factory CurrentUser.fromJson(Map<String, dynamic> json) => CurrentUser(
        username: _s(json['username']),
        role: _s(json['role']).isEmpty ? 'user' : _s(json['role']),
      );
}

/// /usermanage?format=json 的一筆 (用戶管理那張表)
class ManagedUser {
  final String username;
  final String role;
  final int videoTimes;

  ManagedUser({required this.username, this.role = 'user', this.videoTimes = 0});

  bool get isAdmin => role == 'admin';

  factory ManagedUser.fromJson(Map<String, dynamic> json) => ManagedUser(
        username: _s(json['username']),
        role: _s(json['role']).isEmpty ? 'user' : _s(json['role']),
        // 舊版伺服器回的是整份 videotimes 字典, 新版直接給筆數
        videoTimes: json['videotimes'] is Map
            ? (json['videotimes'] as Map).length
            : _i(json['videotimes']),
      );
}

/// WebSocket /data/tasks_progress 推的一筆
class TaskProgress {
  final String sn;
  final String filename;
  final String status;
  final double rate;

  TaskProgress({
    required this.sn,
    this.filename = '',
    this.status = '',
    this.rate = 0,
  });

  factory TaskProgress.fromJson(String sn, Map<String, dynamic> json) => TaskProgress(
        sn: sn,
        filename: _s(json['filename']),
        status: _s(json['status']),
        rate: HlsStatus._d(json['rate']),
      );
}
