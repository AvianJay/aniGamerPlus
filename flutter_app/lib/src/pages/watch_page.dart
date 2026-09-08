/// 播放頁 —— 對應 templates/watch.html + static/js/watch.js.
///
/// 網頁版那支自製播放器 (控制列、巢狀設定選單、彈幕層、HUD) 在這裡整個重寫成
/// Flutter 的樣子, 但行為刻意跟著網頁走: 同一組播放速度、同一組彈幕透明度、
/// 同一句「還沒下載到這裡」、同一個 8 秒的下一集倒數。
///
/// 四種片源, 優先序由上往下:
///   0. 使用者當場挑的畫質 (/stream/playlist.m3u8) —— 只有挑的跟手上那份對不上
///      才會走到這裡, 見 _needsProxy
///   1. 這支手機上的離線檔 (DownloadStore) —— 沒網路照樣能看
///   2. 邊看邊下載的 HLS EVENT 播放清單 (/hls/playlist.m3u8)
///   3. 伺服器片庫的完整 mp4 (/get_video.mp4)
///
/// 網頁版有子母畫面 (I 鍵), 手機這邊沒有對應的實作 —— iOS/Android 的 PiP 得
/// 各自寫原生層, 這個版本先略過, 其餘功能都在。
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../danmaku/ass.dart';
import '../danmaku/danmaku_overlay.dart';
import '../state/app_state.dart';
import '../state/downloads.dart';
import '../state/prefs.dart';
import '../theme.dart';
import '../util/format.dart';
import '../widgets/common.dart';

// --------------------------------------------------------------- 常數
// 全部照抄 static/js/watch.js, 改了就跟網頁版對不起來了

const List<double> kPlaybackRates = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2];
const List<int> kDanmakuOpacities = [100, 75, 50, 25];
const List<int> kBrightnessLevels = [100, 80, 60, 40, 20];

const int kSkipSeconds = 10;

/// 一次橫掃整個畫面代表幾秒
const double kGestureSeekSpan = 120;
const double kMinBrightness = 0.2;

/// 非全螢幕時, 播放器最多吃掉這麼多高度. 剩下的留給作品資訊跟選集 ——
/// 手機直著拿本來就吃不到這個上限, 只有平板跟橫著拿的時候會生效.
const double kPlayerMaxHeightRatio = 0.55;

/// 手指按不出 mousemove, 所以控制列留得比桌面久
const Duration kControlsIdle = Duration(milliseconds: 8000);
const int kNextEpisodeCountdown = 8;

/// 邊看邊下載: 先攢這麼多秒再自動開播
const double kStreamHeadStart = 45;
const Duration kStreamPoll = Duration(seconds: 5);
const Duration kStreamPendingGrace = Duration(seconds: 120);

class PlayerChoice<T> {
  const PlayerChoice(this.value, this.label);
  final T value;
  final String label;
}

const List<PlayerChoice<double>> kDanmakuAreas = [
  PlayerChoice(1.0, '全畫面'),
  PlayerChoice(0.75, '上方 3/4'),
  PlayerChoice(0.5, '上半部'),
  PlayerChoice(0.25, '頂端 1/4'),
];

const List<PlayerChoice<String>> kAspectModes = [
  PlayerChoice('contain', '原始比例'),
  PlayerChoice('cover', '裁切填滿'),
  PlayerChoice('fill', '完整填滿'),
];

const List<PlayerChoice<double>> kDanmakuScales = [
  PlayerChoice(0.8, '小'),
  PlayerChoice(1.0, '標準'),
  PlayerChoice(1.25, '大'),
  PlayerChoice(1.5, '特大'),
];

const List<PlayerChoice<double>> kDanmakuSpeeds = [
  PlayerChoice(0.75, '慢'),
  PlayerChoice(1.0, '標準'),
  PlayerChoice(1.5, '快'),
];

/// 網頁版那份鍵盤快速鍵在手機上沒有意義, 換成同樣位置的手勢說明
const List<List<String>> kGestureHelp = [
  ['輕點畫面', '顯示 / 收起控制列'],
  ['左右滑動', '快轉 / 倒退 (整個畫面 = 120 秒)'],
  ['左半邊上下滑', '畫面亮度'],
  ['右半邊上下滑', '音量'],
  ['連點兩下左 / 右', '倒退 / 快進 10 秒'],
  ['長按畫面', '2 倍速播放'],
];

class WatchPage extends StatefulWidget {
  const WatchPage({
    super.key,
    required this.state,
    required this.sn,
    this.streaming = false,
  });

  final AppState state;
  final String sn;

  /// 從「邊看邊下載」進來的, 要走 HLS
  final bool streaming;

  @override
  State<WatchPage> createState() => _WatchPageState();
}

class _WatchPageState extends State<WatchPage>
    with SingleTickerProviderStateMixin {
  // ------------------------------------------------------------- 依賴
  AppState get state => widget.state;
  AgpClient get client => state.client;
  DownloadStore get store => state.downloads;
  Prefs get prefs => state.prefs;

  // ------------------------------------------------------------- 這一集
  late String _sn;
  late bool _streaming;
  VideoItem? _video;
  SeriesInfo? _series;
  File? _localFile;
  double _resumeAt = 0;

  // ------------------------------------------------------------- 播放器
  VideoPlayerController? _controller;
  bool _initialising = true;
  String _error = '';
  double _duration = 0;
  bool _playing = false;
  bool _buffering = false;
  bool _ended = false;

  /// 位置的插值時鐘. video_player 大約半秒才回報一次, 直接餵給彈幕會一格一格跳,
  /// 所以記下最後一次回報的位置與當下時間, 每一幀自己往前推。
  final ValueNotifier<double> _clock = ValueNotifier<double>(0);
  Ticker? _ticker;
  double _anchor = 0;
  int _anchorAt = 0;

  // ------------------------------------------------------------- 彈幕
  List<DanmakuComment> _danmaku = const [];
  bool _danmakuLoading = false;

  // ------------------------------------------------------------- 設定
  double _rate = 1;
  double _volume = 1;
  double _brightness = 1;
  bool _danmakuOn = true;
  int _danmakuOpacity = 100;
  double _danmakuArea = 1;
  double _danmakuScale = 1;
  double _danmakuSpeed = 1;
  String _aspect = 'contain';
  bool _autoNext = true;

  // ------------------------------------------------------------- 畫質
  /// 想看幾 P. 跟手上那份 (離線檔 / 下載中 / 伺服器片庫) 一樣時什麼都不會發生;
  /// 對不上才會走 /stream/*, 讓伺服器現去動畫瘋要那個畫質
  int _quality = 1080;
  /// 是不是在這個播放頁裡當場挑過. 分得出「設定裡留著的偏好」跟「他現在就要換」
  bool _qualityPicked = false;
  /// 這一集還有哪些畫質可以挑. 開設定選單時才去問, 由高到低
  final ValueNotifier<List<int>> _qualities = ValueNotifier<List<int>>(const []);
  bool _qualitiesLoading = false;

  // ------------------------------------------------------------- 介面狀態
  bool _controlsVisible = true;
  Timer? _idleTimer;
  bool _fullscreen = false;
  String _flash = '';
  Timer? _flashTimer;
  String _hud = '';
  bool _scrubbing = false;
  double _scrubValue = 0;
  bool _boosting = false;
  double _boostFrom = 1;

  // ------------------------------------------------------------- 手勢
  double _dragFrom = 0;
  double _dragAccum = 0;
  String _dragSide = '';

  // ------------------------------------------------------------- 邊看邊下載
  Timer? _streamTimer;
  String _streamMode = '';
  double _streamReady = 0;
  double _streamTotal = 0;
  String _streamPlaylistId = '';
  int _streamResolution = 0;
  int _streamNoneSince = 0;
  bool _streamAttached = false;
  bool _streamAutoplayed = false;
  String _downloading = '';
  int _lastStallFlash = 0;

  // ------------------------------------------------------------- 進度同步
  int _lastSync = 0;

  // ------------------------------------------------------------- 下一集
  SeriesEpisode? _nextOffer;
  int _nextCountdown = 0;
  Timer? _nextTimer;

  // =============================================================== 生命週期

  @override
  void initState() {
    super.initState();
    _sn = widget.sn;
    _rate = prefs.rate;
    _volume = prefs.volume;
    _brightness = prefs.brightness;
    _danmakuOn = prefs.danmakuOn;
    _danmakuOpacity = prefs.danmakuOpacity;
    _danmakuArea = prefs.danmakuArea;
    _danmakuScale = prefs.danmakuScale;
    _danmakuSpeed = prefs.danmakuSpeed;
    _aspect = prefs.aspect;
    _autoNext = prefs.autoNext;
    _quality = prefs.playbackResolution;
    _streaming = widget.streaming;
    _ticker = createTicker(_onFrame)..start();
    unawaited(_boot());
  }

  @override
  void dispose() {
    _idleTimer?.cancel();
    _flashTimer?.cancel();
    _nextTimer?.cancel();
    _streamTimer?.cancel();
    _ticker?.dispose();
    final controller = _controller;
    _controller = null;
    controller?.removeListener(_onPlayerUpdate);
    unawaited(controller?.dispose());
    _clock.dispose();
    _qualities.dispose();
    unawaited(WakelockPlus.disable());
    if (_fullscreen) {
      unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
      unawaited(SystemChrome.setPreferredOrientations(DeviceOrientation.values));
    }
    super.dispose();
  }

  // =============================================================== 開場

  Future<void> _boot() async {
    setState(() {
      _initialising = true;
      _error = '';
      _ended = false;
      _nextOffer = null;
      // 換一集就重來: 上一集挑的畫質不該讓這一集直接放棄手機裡那份離線檔
      _qualityPicked = false;
      _streamResolution = 0;
    });
    _qualities.value = const [];

    _video = state.videoOf(_sn);
    final entry = store.entryFor(_sn);
    if (_video == null && entry != null) {
      _video = VideoItem(
        sn: entry.sn,
        title: entry.title,
        animeName: entry.animeName,
        episode: entry.episode,
        resolution: entry.resolution,
        danmu: entry.hasDanmaku,
      );
    }
    _localFile = store.localVideo(_sn);
    if (_localFile == null) {
      final video = _video;
      if (video != null && (video.streaming || video.pending)) _streaming = true;
    } else {
      // 本機已經有完整檔了, 沒必要再去追下載進度
      _streaming = false;
    }

    _resumeAt = await _readResume();

    unawaited(_loadSeries());
    unawaited(_loadDanmaku());

    if (_localFile == null && _streaming) {
      setState(() {
        _initialising = false;
        _downloading = '正在準備下載…';
      });
      _startPoll();
      return;
    }
    await _openSource();
  }

  Future<double> _readResume() async {
    var saved = state.watchTimeOf(_sn);
    if (!state.offline) {
      try {
        final fresh = await client.watchTime(_sn);
        if (fresh.timestamp > 0 || fresh.time > 0) {
          saved = fresh;
          state.noteWatchTime(_sn, fresh);
        }
      } catch (_) {
        // 讀不到就用本機那份, 不值得為了進度擋住播放
      }
    }
    if (saved == null || saved.ended) return 0;
    return saved.time.toDouble();
  }

  /// 建立 / 換掉 VideoPlayerController
  Future<void> _openSource({double? seekTo, bool autoplay = true}) async {
    final previous = _controller;
    if (previous != null) {
      previous.removeListener(_onPlayerUpdate);
      _controller = null;
      unawaited(previous.dispose());
    }
    if (mounted) setState(() => _initialising = true);

    final local = _localFile;
    late VideoPlayerController controller;
    if (_needsProxy) {
      // 挑的畫質手上沒有, 只能請伺服器現去動畫瘋代抓. 放在最前面是因為這是使用者
      // 剛剛明確要求的, 比任何一份現成的檔都優先
      controller = VideoPlayerController.networkUrl(
        client.streamPlaylistUrl(_sn, _quality),
        httpHeaders: client.authHeaders,
      );
    } else if (local != null) {
      controller = VideoPlayerController.file(local);
    } else if (_streaming) {
      controller = VideoPlayerController.networkUrl(
        client.hlsPlaylistUrl(_sn),
        httpHeaders: client.authHeaders,
      );
    } else {
      final res = _video?.resolution ?? 0;
      controller = VideoPlayerController.networkUrl(
        client.videoUrl(_sn, resolution: res > 0 ? res : null),
        httpHeaders: client.authHeaders,
      );
    }

    try {
      await controller.initialize();
    } catch (error) {
      unawaited(controller.dispose());
      if (!mounted) return;
      setState(() {
        _initialising = false;
        _error = state.offline
            ? '離線中，而且這一集沒有下載到手機。'
            : '播放失敗: $error';
      });
      return;
    }
    if (!mounted) {
      unawaited(controller.dispose());
      return;
    }

    controller.addListener(_onPlayerUpdate);
    await controller.setVolume(_volume);
    await controller.setPlaybackSpeed(_rate);
    await controller.setLooping(false);

    final duration = controller.value.duration.inMilliseconds / 1000.0;
    final target = seekTo ?? _resumeAt;
    if (target > 1) {
      await controller.seekTo(Duration(milliseconds: (target * 1000).round()));
    }

    if (!mounted) {
      unawaited(controller.dispose());
      return;
    }
    setState(() {
      _controller = controller;
      _initialising = false;
      _error = '';
      _duration = duration > 0 ? duration : _duration;
      _anchor = target > 1 ? target : 0;
      _anchorAt = DateTime.now().millisecondsSinceEpoch;
    });
    _clock.value = _anchor;

    if (autoplay) {
      await controller.play();
      unawaited(WakelockPlus.enable());
    }
    _armIdle();
  }

  // =============================================================== 片單 / 彈幕

  Future<void> _loadSeries() async {
    if (state.offline) return;
    try {
      final info = await client.series(_sn);
      if (!mounted) return;
      setState(() => _series = info);
    } catch (_) {
      // 舊版伺服器沒有 /watch/series.json, 下面會退回本機片庫湊選集
    }
  }

  Future<void> _loadDanmaku() async {
    setState(() {
      _danmaku = const [];
      _danmakuLoading = true;
    });
    String? text;
    final local = store.localDanmaku(_sn);
    if (local != null) {
      try {
        text = await local.readAsString();
      } catch (_) {
        text = null;
      }
    }
    if ((text == null || text.isEmpty) && !state.offline) {
      try {
        text = await client.danmakuAss(_sn);
        // 這一集有下載但還沒存到彈幕的話, 順手補一份給離線用
        if (text.trim().isNotEmpty) {
          unawaited(store.cacheDanmaku(_sn, text));
        }
      } catch (_) {
        text = null;
      }
    }
    if (!mounted) return;
    setState(() {
      _danmaku = (text == null || text.trim().isEmpty)
          ? const <DanmakuComment>[]
          : parseAss(text);
      _danmakuLoading = false;
    });
  }

  // =============================================================== 畫質

  /// 手上這一份是幾 P. 0 表示不知道 —— 舊資料沒帶 resolution, 那就當成怎樣都算數
  int get _onHandResolution {
    if (_localFile != null) return store.entryFor(_sn)?.resolution ?? 0;
    if (_streaming) return _streamResolution;
    return _video?.resolution ?? 0;
  }

  /// 要不要走 /stream/* 代理.
  ///
  /// 片庫一集只留一種畫質, 所以「換畫質」實際上就是「這一份不合用, 回頭跟動畫瘋
  /// 要別的」. 兩個地方刻意不換:
  ///  - 離線時. 手上只有那一份, 沒得挑, 更不該去撞一個連不上的伺服器.
  ///  - 手機裡有離線檔, 而且使用者這次沒有當場挑過. 那份是他自己特地下載的,
  ///    不該因為設定裡留著一個偏好值就繞過去重新連線抓.
  bool get _needsProxy {
    if (state.offline || _quality <= 0) return false;
    final have = _onHandResolution;
    if (have <= 0 || have == _quality) return false;
    if (_localFile != null && !_qualityPicked) return false;
    return true;
  }

  /// 選單上現在該顯示哪一個
  int get _currentQuality {
    if (_needsProxy) return _quality;
    final have = _onHandResolution;
    return have > 0 ? have : _quality;
  }

  Future<void> _loadQualities() async {
    if (state.offline || _qualitiesLoading || _qualities.value.isNotEmpty) return;
    _qualitiesLoading = true;
    // 開設定選單時才問, 不放在開頁流程裡: 伺服器那一支會真的去動畫瘋解析播放位址,
    // 每開一集就打一次太重了, 而且絕大多數人根本不會動畫質
    final list = await client.streamSources(_sn);
    _qualitiesLoading = false;
    if (!mounted) return;
    _qualities.value = list;
  }

  List<PlayerChoice<int>> _qualityChoices(List<int> options) {
    final have = _onHandResolution;
    final values = <int>{...options, if (have > 0) have, if (_quality > 0) _quality}
        .toList()
      ..sort((a, b) => b - a);
    return [
      for (final res in values) PlayerChoice(res, '${res}P${_qualitySuffix(res)}'),
    ];
  }

  /// 標一下哪個是現成的, 哪個要重新跟動畫瘋要
  String _qualitySuffix(int res) {
    if (res != _onHandResolution) return '';
    if (_localFile != null) return ' · 已下載';
    if (_streaming) return ' · 下載中';
    return ' · 伺服器片庫';
  }

  Future<void> _switchQuality(int res) async {
    if (res <= 0 || res == _currentQuality) return;
    final previousQuality = _quality;
    final previousPicked = _qualityPicked;
    final at = _clock.value;
    setState(() {
      _quality = res;
      _qualityPicked = true;
    });
    unawaited(state.savePref(() => prefs.setPlaybackResolution(res)));

    await _openSource(seekTo: at);
    if (!mounted) return;
    if (_error.isEmpty) {
      _flashMessage('已切換到 ${res}P');
      return;
    }
    // 換過去打不開就原路換回來: 挑錯畫質的代價不該是整個播放頁掛在那裡
    setState(() {
      _quality = previousQuality;
      _qualityPicked = previousPicked;
    });
    await _openSource(seekTo: at);
    if (mounted) _flashMessage('切換到 ${res}P 失敗，已還原');
  }

  // =============================================================== 邊看邊下載

  void _startPoll() {
    _streamTimer?.cancel();
    _streamTimer = Timer.periodic(kStreamPoll, (_) => unawaited(_pollStream()));
    unawaited(_pollStream());
  }

  void _stopPoll() {
    _streamTimer?.cancel();
    _streamTimer = null;
  }

  Future<void> _pollStream() async {
    if (!mounted || !_streaming) return;
    HlsStatus status;
    try {
      status = await client.hlsStatus(_sn);
    } catch (_) {
      return;
    }
    if (!mounted || !_streaming) return;

    if (status.mode == 'file') {
      await _finishStream();
      return;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    if (status.mode == 'none') {
      if (_streamNoneSince == 0) _streamNoneSince = now;
      if (now - _streamNoneSince > kStreamPendingGrace.inMilliseconds) {
        _stopPoll();
        setState(() => _downloading = '下載已停止');
      }
      return;
    }
    _streamNoneSince = 0;

    if (status.playlistId.isNotEmpty) {
      final changed = _streamPlaylistId.isNotEmpty &&
          status.playlistId != _streamPlaylistId;
      _streamPlaylistId = status.playlistId;
      // 正在看代理串流的話手上那份 HLS 早就不在畫面上了, 重建只是白跑一趟
      if (changed && !_needsProxy) {
        // 伺服器重開了一份清單 (例如換畫質重抓), 手上這份已經失效
        await _rebuildStream();
        if (!mounted) return;
      }
    }

    setState(() {
      _streamMode = status.mode;
      _streamReady = status.readyDuration;
      _streamTotal = status.totalDuration;
      _streamResolution = status.resolution;
      if (status.totalDuration > _duration) _duration = status.totalDuration;
      _downloading = _downloadingLabel(status);
    });

    if (!_streamAttached && status.ready > 0) {
      _streamAttached = true;
      await _openSource(autoplay: false);
      if (!mounted) return;
    }
    _maybeAutoplay();
  }

  String _downloadingLabel(HlsStatus status) {
    if (status.mode == 'finalising') return '下載完成，正在合併…';
    if (status.ready <= 0) {
      return status.status == 'parsing' ? '正在解析…' : '正在準備下載…';
    }
    final parts = <String>[];
    if (status.rate > 0) parts.add('${status.rate.round()}%');
    if (status.resolution > 0) parts.add('${status.resolution}P');
    if (parts.isEmpty) return '邊看邊下載';
    return '邊看邊下載 ${parts.join(' · ')}';
  }

  /// 攢夠 45 秒 (或已經在合併) 才開播, 免得開頭就卡住
  void _maybeAutoplay() {
    if (_streamAutoplayed) return;
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    // 代理串流是整集一次給完的 VOD, 不必陪下載器等頭
    if (!_needsProxy &&
        _streamReady < kStreamHeadStart &&
        _streamMode != 'finalising') {
      return;
    }
    _streamAutoplayed = true;
    unawaited(controller.play());
    unawaited(WakelockPlus.enable());
  }

  Future<void> _rebuildStream() async {
    final at = _clock.value;
    _streamAttached = false;
    _streamAutoplayed = false;
    await _openSource(seekTo: at, autoplay: false);
  }

  /// 下載完成: 換成完整 mp4, 位置留在原地, 彈幕重讀一次
  Future<void> _finishStream() async {
    _stopPoll();
    final at = _clock.value;
    setState(() {
      _streaming = false;
      _streamAttached = false;
      _streamAutoplayed = false;
      _downloading = '';
    });
    unawaited(state.refreshLibrary().then((_) {
      if (!mounted) return;
      setState(() => _video = state.videoOf(_sn) ?? _video);
    }));
    if (_needsProxy) {
      // 他正在看自己挑的畫質, 而下載的是另一種. 換過去等於把人從選好的東西上拽走
      unawaited(_loadDanmaku());
      return;
    }
    await _openSource(seekTo: at);
    if (!mounted) return;
    unawaited(_loadDanmaku());
    _flashMessage('下載完成，已切換到完整影片');
  }

  void _noteStall() {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastStallFlash < 20000) return;
    _lastStallFlash = now;
    _flashMessage('下載速度跟不上播放，正在等待');
  }

  // =============================================================== 時鐘

  void _onFrame(Duration _) {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    if (_scrubbing) return;
    final value = controller.value;
    var position = _anchor;
    if (value.isPlaying) {
      final elapsed = (DateTime.now().millisecondsSinceEpoch - _anchorAt) / 1000;
      position = _anchor + elapsed * _rate;
    }
    final limit = _playableDuration;
    if (limit > 0 && position > limit) position = limit;
    if (position < 0) position = 0;
    if ((position - _clock.value).abs() > 0.008) _clock.value = position;
  }

  void _onPlayerUpdate() {
    final controller = _controller;
    if (controller == null) return;
    final value = controller.value;
    if (!value.isInitialized) return;

    final position = value.position.inMilliseconds / 1000.0;
    if ((position - _anchor).abs() > 0.05 || !value.isPlaying) {
      _anchor = position;
      _anchorAt = DateTime.now().millisecondsSinceEpoch;
    }
    final duration = value.duration.inMilliseconds / 1000.0;

    if (value.isPlaying) unawaited(_syncTime());
    if (_streaming && value.isBuffering && _streamReady - position < 6) {
      _noteStall();
    }

    if (!_ended &&
        duration > 1 &&
        !value.isPlaying &&
        position >= duration - 0.4) {
      _onEnded();
    }

    if (value.isPlaying != _playing ||
        value.isBuffering != _buffering ||
        (duration > 0 && (duration - _duration).abs() > 0.5)) {
      if (!mounted) return;
      setState(() {
        _playing = value.isPlaying;
        _buffering = value.isBuffering;
        if (duration > 0) _duration = duration;
      });
      if (value.isPlaying) {
        unawaited(WakelockPlus.enable());
      } else {
        unawaited(WakelockPlus.disable());
      }
    }
  }

  // =============================================================== 進度同步

  Future<void> _syncTime({bool ended = false, bool force = false}) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (!force && now - _lastSync < 10000) return;
    _lastSync = now;

    final seconds = ended ? 0 : _clock.value.round();
    final duration = _duration.round();
    state.noteWatchTime(
      _sn,
      WatchTime(
        time: seconds,
        ended: ended,
        duration: duration,
        timestamp: now ~/ 1000,
      ),
    );
    if (state.offline) return;
    try {
      await client.setWatchTime(_sn, seconds,
          ended: ended, duration: duration > 0 ? duration : null);
    } catch (_) {
      // 沒登入 / 斷線時就只留在本機, 下次連上會被覆蓋回來
    }
  }

  // =============================================================== 播放控制

  double get _playableDuration =>
      _streaming && _streamTotal > 0 ? _streamTotal : _duration;

  double get _seekableDuration {
    if (!_streaming) return _duration;
    if (_streamReady > 0) return _streamReady;
    return 0;
  }

  double _clampSeek(double value) {
    final playable = _playableDuration;
    var target = value;
    if (target < 0) target = 0;
    if (playable > 0 && target > playable) target = playable;
    if (_streaming) {
      final limit = _seekableDuration;
      if (limit > 0 && target > limit - 1) {
        _flashMessage('還沒下載到這裡');
        return math.max(0, limit - 1);
      }
    }
    return target;
  }

  Future<void> _seekTo(double seconds) async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    final target = _clampSeek(seconds);
    _anchor = target;
    _anchorAt = DateTime.now().millisecondsSinceEpoch;
    _clock.value = target;
    _ended = false;
    await controller.seekTo(Duration(milliseconds: (target * 1000).round()));
    unawaited(_syncTime(force: true));
  }

  Future<void> _seekBy(double delta) => _seekTo(_clock.value + delta);

  Future<void> _togglePlay() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    if (controller.value.isPlaying) {
      await controller.pause();
      unawaited(_syncTime(force: true));
      unawaited(WakelockPlus.disable());
    } else {
      if (_ended) {
        _ended = false;
        await _seekTo(0);
      }
      _streamAutoplayed = true;
      await controller.play();
      unawaited(WakelockPlus.enable());
    }
    _armIdle();
  }

  Future<void> _setRate(double rate) async {
    setState(() => _rate = rate);
    _anchor = _clock.value;
    _anchorAt = DateTime.now().millisecondsSinceEpoch;
    await _controller?.setPlaybackSpeed(rate);
    await state.savePref(() => prefs.setRate(rate));
    _flashMessage('播放速度 ${rate == 1 ? '正常' : '$rate×'}');
  }

  Future<void> _setVolume(double value) async {
    final volume = value.clamp(0.0, 1.0);
    setState(() => _volume = volume);
    await _controller?.setVolume(volume);
    await state.savePref(() => prefs.setVolume(volume));
  }

  Future<void> _setBrightness(double value) async {
    final brightness = value.clamp(kMinBrightness, 1.0);
    setState(() => _brightness = brightness);
    await state.savePref(() => prefs.setBrightness(brightness));
  }

  Future<void> _setDanmaku(bool on) async {
    setState(() => _danmakuOn = on);
    await state.savePref(() => prefs.setDanmakuOn(on));
    _flashMessage(on ? '彈幕開啟' : '彈幕關閉');
  }

  Future<void> _setAspect(String mode) async {
    setState(() => _aspect = mode);
    await state.savePref(() => prefs.setAspect(mode));
    final label = kAspectModes
        .firstWhere((m) => m.value == mode, orElse: () => kAspectModes.first)
        .label;
    _flashMessage(label);
  }

  Future<void> _setFullscreen(bool on) async {
    setState(() => _fullscreen = on);
    if (on) {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    } else {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    }
    _armIdle();
  }

  // =============================================================== HUD

  void _flashMessage(String message) {
    if (!mounted) return;
    setState(() => _flash = message);
    _flashTimer?.cancel();
    _flashTimer = Timer(const Duration(milliseconds: 1600), () {
      if (!mounted) return;
      setState(() => _flash = '');
    });
  }

  void _armIdle() {
    _idleTimer?.cancel();
    if (!_controlsVisible) return;
    _idleTimer = Timer(kControlsIdle, () {
      if (!mounted) return;
      if (!(_controller?.value.isPlaying ?? false)) return;
      setState(() => _controlsVisible = false);
    });
  }

  void _showControls() {
    if (!_controlsVisible) setState(() => _controlsVisible = true);
    _armIdle();
  }

  void _toggleControls() {
    setState(() => _controlsVisible = !_controlsVisible);
    _armIdle();
  }

  // =============================================================== 手勢

  void _onDoubleTapDown(TapDownDetails details, Size size) {
    final left = details.localPosition.dx < size.width / 2;
    unawaited(_seekBy(left ? -kSkipSeconds.toDouble() : kSkipSeconds.toDouble()));
    _flashMessage(left ? '倒退 $kSkipSeconds 秒' : '快進 $kSkipSeconds 秒');
  }

  void _onLongPressStart() {
    final controller = _controller;
    if (controller == null || !controller.value.isPlaying) return;
    _boostFrom = _rate;
    setState(() => _boosting = true);
    unawaited(controller.setPlaybackSpeed(2));
    _anchor = _clock.value;
    _anchorAt = DateTime.now().millisecondsSinceEpoch;
    _flashMessage('2× 快轉中');
  }

  void _onLongPressEnd() {
    if (!_boosting) return;
    setState(() => _boosting = false);
    unawaited(_controller?.setPlaybackSpeed(_boostFrom));
    _anchor = _clock.value;
    _anchorAt = DateTime.now().millisecondsSinceEpoch;
  }

  void _onHorizontalStart(DragStartDetails details) {
    _dragFrom = _clock.value;
    _dragAccum = 0;
    _showControls();
  }

  void _onHorizontalUpdate(DragUpdateDetails details, Size size) {
    if (size.width <= 0) return;
    _dragAccum += details.delta.dx / size.width * kGestureSeekSpan;
    final target = (_dragFrom + _dragAccum)
        .clamp(0.0, math.max(0.0, _playableDuration))
        .toDouble();
    _scrubbing = true;
    _clock.value = target;
    final delta = target - _dragFrom;
    final sign = delta >= 0 ? '+' : '-';
    setState(() => _hud =
        '${formatClock(target)} / ${formatClock(_playableDuration)}  $sign${formatClock(delta.abs())}');
  }

  void _onHorizontalEnd(DragEndDetails details) {
    _scrubbing = false;
    setState(() => _hud = '');
    unawaited(_seekTo(_dragFrom + _dragAccum));
  }

  void _onVerticalStart(DragStartDetails details, Size size) {
    _dragSide = details.localPosition.dx < size.width / 2 ? 'brightness' : 'volume';
    _showControls();
  }

  void _onVerticalUpdate(DragUpdateDetails details, Size size) {
    if (size.height <= 0) return;
    final step = -details.delta.dy / size.height;
    if (_dragSide == 'brightness') {
      unawaited(_setBrightness(_brightness + step));
      setState(() => _hud = '畫面亮度 ${(_brightness * 100).round()}%');
    } else {
      unawaited(_setVolume(_volume + step));
      setState(() => _hud = _volume <= 0
          ? '靜音'
          : '音量 ${(_volume * 100).round()}%');
    }
  }

  void _onVerticalEnd(DragEndDetails details) {
    _dragSide = '';
    setState(() => _hud = '');
  }

  // =============================================================== 選集

  List<SeriesEpisode> _orderedEpisodes() {
    final info = _series;
    if (info != null && info.allEpisodes.isNotEmpty) return info.allEpisodes;
    final name = _video?.displayName ?? '';
    if (name.isEmpty) return const [];
    return [
      for (final video in state.episodesOf(name))
        SeriesEpisode(
          videoSn: video.sn,
          episode: video.episode,
          local: true,
          resolution: video.resolution,
        ),
    ];
  }

  SeriesEpisode? _neighbour(int step) {
    final list = _orderedEpisodes();
    final index = list.indexWhere((e) => e.videoSn == _sn);
    if (index < 0) return null;
    final target = index + step;
    if (target < 0 || target >= list.length) return null;
    return list[target];
  }

  void _goRelative(int step) {
    final next = _neighbour(step);
    if (next == null) {
      _flashMessage(step > 0 ? '已是最後一集' : '已是第一集');
      return;
    }
    unawaited(_switchTo(next));
  }

  Future<void> _switchTo(SeriesEpisode episode) async {
    if (episode.videoSn == _sn) return;
    final downloaded = store.isDownloaded(episode.videoSn);
    if (!episode.local && !downloaded) {
      await _streamEpisode(episode);
      return;
    }
    await _syncTime(force: true);
    _stopPoll();
    _nextTimer?.cancel();
    _flashTimer?.cancel();
    final controller = _controller;
    if (controller != null) {
      controller.removeListener(_onPlayerUpdate);
      unawaited(controller.pause());
    }
    if (!mounted) return;
    setState(() {
      _sn = episode.videoSn;
      _streaming = false;
      _streamAttached = false;
      _streamAutoplayed = false;
      _streamMode = '';
      _streamReady = 0;
      _streamTotal = 0;
      _streamPlaylistId = '';
      _streamNoneSince = 0;
      _downloading = '';
      _duration = 0;
      _ended = false;
      _nextOffer = null;
      _flash = '';
      _controlsVisible = true;
    });
    _clock.value = 0;
    _anchor = 0;
    await _boot();
  }

  /// 選集裡點到還沒下載的那一格: 丟一個單集任務下去, 然後改走邊看邊下載
  Future<void> _streamEpisode(SeriesEpisode episode) async {
    if (!state.queued.contains(episode.videoSn)) {
      try {
        await state.startServerDownload(
          episode.videoSn,
          resolution: prefs.downloadResolution,
          mode: 'single',
          thread: 1,
          classify: true,
          danmu: true,
        );
        state.queued.add(episode.videoSn);
      } on ApiException catch (error) {
        if (!mounted) return;
        toast(context, error.needsLogin ? '需要管理員權限才能下載。' : '加入下載失敗。');
        return;
      } catch (_) {
        if (!mounted) return;
        toast(context, '加入下載失敗。');
        return;
      }
    }
    if (!mounted) return;
    await _syncTime(force: true);
    _stopPoll();
    _nextTimer?.cancel();
    final controller = _controller;
    if (controller != null) {
      controller.removeListener(_onPlayerUpdate);
      unawaited(controller.pause());
    }
    if (!mounted) return;
    setState(() {
      _sn = episode.videoSn;
      _streaming = true;
      _streamAttached = false;
      _streamAutoplayed = false;
      _streamMode = '';
      _streamReady = 0;
      _streamTotal = 0;
      _streamPlaylistId = '';
      _streamNoneSince = 0;
      _downloading = '正在準備下載…';
      _duration = 0;
      _ended = false;
      _nextOffer = null;
      _controlsVisible = true;
    });
    _clock.value = 0;
    _anchor = 0;
    await _boot();
  }

  // =============================================================== 下一集

  void _onEnded() {
    if (_ended) return;
    _ended = true;
    unawaited(_syncTime(ended: true, force: true));
    unawaited(WakelockPlus.disable());
    final next = _neighbour(1);
    if (next == null) return;
    if (!mounted) return;
    setState(() {
      _nextOffer = next;
      _nextCountdown = kNextEpisodeCountdown;
      _controlsVisible = true;
    });
    if (!_autoNext) return;
    _nextTimer?.cancel();
    _nextTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() => _nextCountdown -= 1);
      if (_nextCountdown <= 0) {
        timer.cancel();
        final target = _nextOffer;
        setState(() => _nextOffer = null);
        if (target != null) unawaited(_switchTo(target));
      }
    });
  }

  void _cancelNext() {
    _nextTimer?.cancel();
    setState(() => _nextOffer = null);
  }

  // =============================================================== 標題等雜項

  String get _seriesName {
    final info = _series;
    if (info != null && info.title.isNotEmpty) return info.title;
    final video = _video;
    if (video != null && video.displayName.isNotEmpty) return video.displayName;
    return 'sn $_sn';
  }

  String get _hereLabel => episodeLabel(_video?.episode ?? _currentEpisode?.episode);

  SeriesEpisode? get _currentEpisode {
    for (final episode in _orderedEpisodes()) {
      if (episode.videoSn == _sn) return episode;
    }
    return null;
  }

  Favourite get _favouriteEntry => Favourite(
        name: _seriesName,
        alias: _video?.animeName ?? '',
        sn: _sn,
        res: _video?.resolution ?? 0,
        cover: _series?.cover ?? '',
      );

  Future<void> _toggleFavourite() async {
    final added = await state.toggleFavourite(_favouriteEntry);
    if (!mounted) return;
    toast(context, added ? '已加入收藏。' : '已取消收藏。');
  }

  Future<void> _saveToPhone() async {
    final video = _video ??
        VideoItem(
          sn: _sn,
          animeName: _seriesName,
          title: _seriesName,
          episode: _currentEpisode?.episode ?? '',
          resolution: _currentEpisode?.resolution ?? 0,
          danmu: true,
        );
    await store.enqueue(video, withDanmaku: prefs.downloadDanmaku);
    if (!mounted) return;
    toast(context, '已加入手機下載佇列。');
  }

  Future<void> _openOnBahamut() async {
    final url = Uri.parse('https://ani.gamer.com.tw/animeVideo.php?sn=$_sn');
    try {
      await launchUrl(url, mode: LaunchMode.externalApplication);
    } catch (_) {
      if (!mounted) return;
      toast(context, '開不了動畫瘋, 手動搜尋 sn=$_sn 吧');
    }
  }

  Future<void> _forgetProgress() async {
    await state.forgetWatchTime(_sn);
    if (!mounted) return;
    toast(context, '已刪除這一集的觀看紀錄。');
  }

  // =============================================================== 畫面

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_fullscreen,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        unawaited(_setFullscreen(false));
      },
      child: Scaffold(
        backgroundColor: _fullscreen ? Colors.black : null,
        body: _fullscreen
            ? _playerSurface()
            : SafeArea(
                bottom: false,
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    // 平板橫著拿的時候, 整片 16:9 會把螢幕吃光, 底下的作品資訊
                    // 跟選集一格都露不出來. 播放器最多只能佔這麼高, 超過就
                    // 連寬度一起縮, 維持 16:9 置中, 兩側留黑.
                    final height = math.min(
                      constraints.maxWidth * 9 / 16,
                      constraints.maxHeight * kPlayerMaxHeightRatio,
                    );
                    final width = math.min(
                      constraints.maxWidth,
                      height * 16 / 9,
                    );
                    return Column(
                      children: [
                        _titleBar(),
                        SizedBox(
                          height: height,
                          width: constraints.maxWidth,
                          child: ColoredBox(
                            color: Colors.black,
                            child: Center(
                              child: SizedBox(
                                width: width,
                                height: height,
                                child: _playerSurface(),
                              ),
                            ),
                          ),
                        ),
                        Expanded(child: _pageBody()),
                      ],
                    );
                  },
                ),
              ),
      ),
    );
  }

  // ------------------------------------------------------------- 標題列

  Widget _titleBar() {
    final favourite = state.isFavourite(_seriesName, _video?.animeName);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 6),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back_rounded),
            tooltip: '返回',
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _seriesName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
                ),
                Text(
                  '$_hereLabel${_video != null && _video!.resolution > 0 ? ' · ${_video!.resolution}P' : ''}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11.5, color: AgpColors.fgFaint),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: favourite ? '已收藏' : '收藏',
            icon: Icon(
              favourite ? Icons.favorite_rounded : Icons.favorite_border_rounded,
              color: favourite ? AgpColors.accent : null,
            ),
            onPressed: _toggleFavourite,
          ),
          PopupMenuButton<String>(
            tooltip: '更多',
            icon: const Icon(Icons.more_vert_rounded),
            onSelected: (value) {
              if (value == 'phone') {
                unawaited(_saveToPhone());
              } else if (value == 'server') {
                unawaited(_queueOnServer());
              } else if (value == 'bahamut') {
                unawaited(_openOnBahamut());
              } else if (value == 'forget') {
                unawaited(_forgetProgress());
              } else if (value == 'reload') {
                unawaited(_boot());
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'phone',
                child: ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.download_for_offline_outlined, size: 20),
                  title: Text('下載到手機'),
                ),
              ),
              if (state.isAdmin)
                const PopupMenuItem(
                  value: 'server',
                  child: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.cloud_download_outlined, size: 20),
                    title: Text('加入伺服器下載'),
                  ),
                ),
              const PopupMenuItem(
                value: 'bahamut',
                child: ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.open_in_new_rounded, size: 20),
                  title: Text('在動畫瘋開啟'),
                ),
              ),
              const PopupMenuItem(
                value: 'forget',
                child: ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.history_toggle_off_rounded, size: 20),
                  title: Text('刪除觀看紀錄'),
                ),
              ),
              const PopupMenuItem(
                value: 'reload',
                child: ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.refresh_rounded, size: 20),
                  title: Text('重新載入'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _queueOnServer() async {
    try {
      await state.startServerDownload(
        _sn,
        resolution: prefs.downloadResolution,
        danmu: prefs.downloadDanmaku,
      );
      state.queued.add(_sn);
      if (!mounted) return;
      toast(context, '已送進伺服器的下載佇列。');
    } on ApiException catch (error) {
      if (!mounted) return;
      toast(context, error.needsLogin ? '需要管理員權限才能下載。' : '加入下載失敗。');
    } catch (_) {
      if (!mounted) return;
      toast(context, '加入下載失敗。');
    }
  }

  // ------------------------------------------------------------- 播放區

  Widget _playerSurface() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        final controller = _controller;
        final ready = controller != null && controller.value.isInitialized;

        return ColoredBox(
          color: Colors.black,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (ready) _fitted(controller) else _poster(),
              if (_danmakuOn && _danmaku.isNotEmpty)
                Positioned.fill(
                  child: IgnorePointer(
                    child: ValueListenableBuilder<double>(
                      valueListenable: _clock,
                      builder: (context, position, _) => DanmakuOverlay(
                        comments: _danmaku,
                        positionSeconds: position,
                        playing: _playing && !_scrubbing,
                        enabled: _danmakuOn,
                        opacity: _danmakuOpacity / 100,
                        area: _danmakuArea,
                        scale: _danmakuScale,
                        speed: _danmakuSpeed,
                      ),
                    ),
                  ),
                ),
              if (_brightness < 1)
                Positioned.fill(
                  child: IgnorePointer(
                    child: ColoredBox(
                      color: Colors.black.withValues(alpha: 1 - _brightness),
                    ),
                  ),
                ),
              Positioned.fill(child: _gestureLayer(size)),
              if ((_initialising || !ready) && _error.isEmpty)
                const Center(
                  child: SizedBox(
                    width: 34,
                    height: 34,
                    child: CircularProgressIndicator(strokeWidth: 2.4),
                  ),
                ),
              if (_error.isNotEmpty) _errorOverlay(),
              if (ready && _buffering)
                const Center(
                  child: SizedBox(
                    width: 30,
                    height: 30,
                    child: CircularProgressIndicator(strokeWidth: 2.4),
                  ),
                ),
              if (_downloading.isNotEmpty) _downloadBadge(),
              AnimatedOpacity(
                opacity: _controlsVisible ? 1 : 0,
                duration: const Duration(milliseconds: 180),
                child: IgnorePointer(
                  ignoring: !_controlsVisible,
                  child: _controls(),
                ),
              ),
              if (_flash.isNotEmpty || _hud.isNotEmpty) _hudChip(),
              if (_nextOffer != null) _nextCard(),
            ],
          ),
        );
      },
    );
  }

  Widget _fitted(VideoPlayerController controller) {
    final size = controller.value.size;
    final width = size.width > 0 ? size.width : 16.0;
    final height = size.height > 0 ? size.height : 9.0;
    final fit = switch (_aspect) {
      'cover' => BoxFit.cover,
      'fill' => BoxFit.fill,
      _ => BoxFit.contain,
    };
    return ClipRect(
      child: FittedBox(
        fit: fit,
        child: SizedBox(
          width: width,
          height: height,
          child: VideoPlayer(controller),
        ),
      ),
    );
  }

  Widget _poster() {
    final thumb = store.localThumb(_sn);
    return Opacity(
      opacity: 0.35,
      child: CoverImage(
        name: _seriesName,
        file: thumb,
        url: (thumb == null && !state.offline)
            ? client.thumbnailUrl(_sn).toString()
            : null,
        headers: client.authHeaders,
        radius: 0,
        fit: BoxFit.cover,
      ),
    );
  }

  Widget _errorOverlay() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 30, color: AgpColors.accent),
            const SizedBox(height: 10),
            Text(
              _error,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13, color: Colors.white),
            ),
            const SizedBox(height: 12),
            FilledButton.tonal(
              onPressed: () => unawaited(_boot()),
              child: const Text('重試'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _downloadBadge() {
    return Positioned(
      left: 12,
      top: 10,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.62),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 11,
              height: 11,
              child: CircularProgressIndicator(strokeWidth: 1.8),
            ),
            const SizedBox(width: 7),
            Text(
              _downloading,
              style: const TextStyle(fontSize: 11.5, color: Colors.white),
            ),
          ],
        ),
      ),
    );
  }

  Widget _hudChip() {
    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.7),
          borderRadius: BorderRadius.circular(kRadiusSmall),
        ),
        child: Text(
          _hud.isNotEmpty ? _hud : _flash,
          style: const TextStyle(
            fontSize: 13.5,
            color: Colors.white,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }

  Widget _nextCard() {
    final next = _nextOffer!;
    final label = episodeLabel(next.episode);
    return Positioned(
      right: 14,
      bottom: 70,
      child: Container(
        width: 236,
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.82),
          borderRadius: BorderRadius.circular(kRadius),
          border: Border.all(color: AgpColors.lineStrong),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              '即將播放下一集',
              style: TextStyle(
                fontSize: 12,
                color: AgpColors.fgFaint,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 5),
            Text(
              '$label · $_seriesName',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13.5, color: Colors.white),
            ),
            const SizedBox(height: 11),
            Row(
              children: [
                Expanded(
                  child: FilledButton(
                    onPressed: () {
                      _nextTimer?.cancel();
                      setState(() => _nextOffer = null);
                      unawaited(_switchTo(next));
                    },
                    child: Text(
                      _autoNext && _nextCountdown > 0
                          ? '立即播放 ($_nextCountdown)'
                          : '立即播放',
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: _cancelNext,
                  child: const Text('取消'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ------------------------------------------------------------- 手勢層

  Widget _gestureLayer(Size size) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _toggleControls,
      onDoubleTapDown: (details) => _onDoubleTapDown(details, size),
      onDoubleTap: () {},
      onLongPressStart: (_) => _onLongPressStart(),
      onLongPressEnd: (_) => _onLongPressEnd(),
      onLongPressCancel: _onLongPressEnd,
      onHorizontalDragStart: _onHorizontalStart,
      onHorizontalDragUpdate: (details) => _onHorizontalUpdate(details, size),
      onHorizontalDragEnd: _onHorizontalEnd,
      onVerticalDragStart: (details) => _onVerticalStart(details, size),
      onVerticalDragUpdate: (details) => _onVerticalUpdate(details, size),
      onVerticalDragEnd: _onVerticalEnd,
    );
  }

  // ------------------------------------------------------------- 控制列

  Widget _controls() {
    return Stack(
      fit: StackFit.expand,
      children: [
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Color(0x99000000),
                Color(0x00000000),
                Color(0x00000000),
                Color(0xB3000000),
              ],
              stops: [0, 0.28, 0.62, 1],
            ),
          ),
        ),
        if (_fullscreen)
          Positioned(
            left: 6,
            right: 6,
            top: 6,
            child: SafeArea(
              bottom: false,
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
                    onPressed: () => unawaited(_setFullscreen(false)),
                  ),
                  Expanded(
                    child: Text(
                      '$_seriesName · $_hereLabel',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14,
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        Center(child: _centreButtons()),
        Positioned(left: 0, right: 0, bottom: 0, child: _bottomBar()),
      ],
    );
  }

  Widget _centreButtons() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _roundButton(
          Icons.replay_10_rounded,
          () => unawaited(_seekBy(-kSkipSeconds.toDouble())),
          size: 26,
        ),
        const SizedBox(width: 26),
        _roundButton(
          _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
          () => unawaited(_togglePlay()),
          size: 40,
        ),
        const SizedBox(width: 26),
        _roundButton(
          Icons.forward_10_rounded,
          () => unawaited(_seekBy(kSkipSeconds.toDouble())),
          size: 26,
        ),
      ],
    );
  }

  Widget _roundButton(IconData icon, VoidCallback onTap, {double size = 26}) {
    return Material(
      color: Colors.black.withValues(alpha: 0.34),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: () {
          _showControls();
          onTap();
        },
        child: Padding(
          padding: EdgeInsets.all(size * 0.28),
          child: Icon(icon, size: size, color: Colors.white),
        ),
      ),
    );
  }

  Widget _bottomBar() {
    final playable = _playableDuration;
    final seekable = _seekableDuration;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ValueListenableBuilder<double>(
              valueListenable: _clock,
              builder: (context, position, _) {
                final shown = _scrubbing ? _scrubValue : position;
                final max = playable > 0 ? playable : 1.0;
                final secondary = _streaming && seekable > 0
                    ? seekable.clamp(0.0, max)
                    : _bufferedSeconds().clamp(0.0, max);
                return Row(
                  children: [
                    SizedBox(
                      width: 52,
                      child: Text(
                        formatClock(shown),
                        style: const TextStyle(fontSize: 11.5, color: Colors.white),
                      ),
                    ),
                    Expanded(
                      child: SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          trackHeight: 3,
                          thumbShape:
                              const RoundSliderThumbShape(enabledThumbRadius: 6),
                          overlayShape:
                              const RoundSliderOverlayShape(overlayRadius: 14),
                          activeTrackColor: AgpColors.accent,
                          inactiveTrackColor: const Color(0x4DFFFFFF),
                          secondaryActiveTrackColor: const Color(0x80FFFFFF),
                          thumbColor: AgpColors.accent,
                        ),
                        child: Slider(
                          value: shown.clamp(0.0, max),
                          max: max,
                          secondaryTrackValue: secondary,
                          onChangeStart: (value) {
                            _scrubbing = true;
                            _showControls();
                            setState(() => _scrubValue = value);
                          },
                          onChanged: (value) {
                            setState(() => _scrubValue = value);
                            _clock.value = value;
                          },
                          onChangeEnd: (value) {
                            _scrubbing = false;
                            unawaited(_seekTo(value));
                          },
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 52,
                      child: Text(
                        formatClock(playable),
                        textAlign: TextAlign.right,
                        style: const TextStyle(fontSize: 11.5, color: Colors.white),
                      ),
                    ),
                  ],
                );
              },
            ),
            SizedBox(
              height: 40,
              child: Row(
                children: [
                  _barButton(Icons.skip_previous_rounded, '上一集',
                      () => _goRelative(-1)),
                  _barButton(
                      Icons.skip_next_rounded, '下一集', () => _goRelative(1)),
                  _barButton(
                    _danmakuOn
                        ? Icons.subtitles_rounded
                        : Icons.subtitles_off_rounded,
                    _danmakuOn ? '關閉彈幕' : '開啟彈幕',
                    () => unawaited(_setDanmaku(!_danmakuOn)),
                    active: _danmakuOn && _danmaku.isNotEmpty,
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: () {
                      _showControls();
                      _openRateSheet();
                    },
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.white,
                      minimumSize: const Size(40, 34),
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    ),
                    child: Text(
                      _rate == 1 ? '倍速' : '$_rate×',
                      style: const TextStyle(fontSize: 12.5),
                    ),
                  ),
                  _barButton(Icons.view_list_rounded, '選集', _openEpisodeSheet),
                  _barButton(Icons.tune_rounded, '設定', _openSettingsSheet),
                  _barButton(
                    _fullscreen
                        ? Icons.fullscreen_exit_rounded
                        : Icons.fullscreen_rounded,
                    _fullscreen ? '離開全螢幕' : '全螢幕',
                    () => unawaited(_setFullscreen(!_fullscreen)),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _barButton(IconData icon, String tooltip, VoidCallback onTap,
      {bool active = false}) {
    return IconButton(
      tooltip: tooltip,
      iconSize: 20,
      visualDensity: VisualDensity.compact,
      color: active ? AgpColors.accent : Colors.white,
      icon: Icon(icon),
      onPressed: () {
        _showControls();
        onTap();
      },
    );
  }

  double _bufferedSeconds() {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return 0;
    final ranges = controller.value.buffered;
    if (ranges.isEmpty) return 0;
    return ranges.last.end.inMilliseconds / 1000.0;
  }

  // ------------------------------------------------------------- 頁面內容

  Widget _pageBody() {
    return ListView(
      padding: const EdgeInsets.only(bottom: 30),
      children: [
        _episodeSection(),
        _infoCard(),
        _danmakuSection(),
      ],
    );
  }

  Widget _episodeSection() {
    final info = _series;
    final groups = info != null && info.groups.isNotEmpty
        ? info.groups
        : [SeriesGroup(name: '', episodes: _orderedEpisodes())];
    final total = groups.fold<int>(0, (sum, g) => sum + g.episodes.length);
    if (total == 0) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(title: '選集', subtitle: '$total 集'),
        for (final group in groups) ...[
          if (group.name.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 2),
              child: Text(
                group.name,
                style: const TextStyle(
                  fontSize: 12.5,
                  color: AgpColors.fgFaint,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 4, 14, 8),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final episode in group.episodes) _episodeChip(episode),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _episodeChip(SeriesEpisode episode, {VoidCallback? onTap}) {
    final here = episode.videoSn == _sn;
    final downloaded = store.isDownloaded(episode.videoSn);
    final remote = !episode.local && !downloaded;
    final label = episode.episode.trim().isEmpty ? '單集' : episode.episode.trim();

    return Tooltip(
      message: remote
          ? '尚未下載，點一下邊看邊下載'
          : (downloaded ? '已下載到這支手機' : '從伺服器片庫播放'),
      child: Material(
        color: here
            ? AgpColors.accent
            : (remote ? Colors.transparent : AgpColors.card),
        borderRadius: BorderRadius.circular(kRadiusSmall),
        child: InkWell(
          borderRadius: BorderRadius.circular(kRadiusSmall),
          onTap: here ? null : (onTap ?? () => unawaited(_switchTo(episode))),
          child: Container(
            constraints: const BoxConstraints(minWidth: 48),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(kRadiusSmall),
              border: Border.all(
                color: here
                    ? AgpColors.accent
                    : (remote ? AgpColors.line : AgpColors.lineStrong),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (downloaded && !here)
                  const Padding(
                    padding: EdgeInsets.only(right: 4),
                    child: Icon(Icons.smartphone_rounded,
                        size: 12, color: AgpColors.fgFaint),
                  ),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: here ? FontWeight.w800 : FontWeight.w600,
                    color: here
                        ? Colors.white
                        : (remote ? AgpColors.fgFaint : AgpColors.fg),
                  ),
                ),
                if (remote)
                  const Padding(
                    padding: EdgeInsets.only(left: 4),
                    child: Icon(Icons.cloud_download_outlined,
                        size: 12, color: AgpColors.fgFaint),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _infoCard() {
    final info = _series;
    final video = _video;
    final rows = <MapEntry<String, String>>[];

    void add(String key, String value) {
      if (value.trim().isEmpty) return;
      rows.add(MapEntry(key, value.trim()));
    }

    if (info != null) {
      add('首播', info.seasonStart);
      add('導演', info.director);
      add('代理商', info.publisher);
      if (info.score > 0) add('評分', info.score.toString());
      add('人氣', formatCount(info.popular));
      if (info.totalEpisode.isNotEmpty) {
        add('集數', '${info.totalEpisode} 集，目前為 $_hereLabel');
      }
    }
    if (video != null) {
      if (video.resolution > 0) add('畫質', '${video.resolution}P');
      add('彈幕', video.danmu ? '支援' : '此集無彈幕檔');
      final added = video.addedAt;
      if (added != null) {
        add('最後更新', '${dayLabel(added)} ${clockOf(added)}');
      }
      add('來源', video.source.isNotEmpty ? video.source : '本機片庫');
      if (video.path.isNotEmpty) {
        add('檔案', video.path.split(RegExp(r'[\\/]')).last);
      }
    }
    final entry = store.entryFor(_sn);
    if (entry != null && entry.status == DownloadStatus.done) {
      add('離線', '已下載到這支手機');
    }

    final synopsis = (info != null && info.content.trim().isNotEmpty)
        ? info.content.trim()
        : '《$_seriesName》目前收錄 ${_orderedEpisodes().length} 集，由 aniGamerPlus+ 直接從本機片庫串流播放，無須再次下載。';
    final tags = info?.tags ?? const <String>[];

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
        decoration: BoxDecoration(
          color: Theme.of(context).cardTheme.color,
          borderRadius: BorderRadius.circular(kRadius),
          border: Border.all(color: AgpColors.line),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '作品資訊',
              style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 9),
            Text(
              synopsis,
              style: const TextStyle(
                  fontSize: 12.8, height: 1.65, color: AgpColors.fgDim),
            ),
            if (tags.isNotEmpty) ...[
              const SizedBox(height: 11),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [for (final tag in tags) Pill(label: tag, dense: true)],
              ),
            ],
            if (rows.isNotEmpty) ...[
              const SizedBox(height: 13),
              for (final row in rows)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 62,
                        child: Text(
                          row.key,
                          style: const TextStyle(
                              fontSize: 12.3, color: AgpColors.fgFaint),
                        ),
                      ),
                      Expanded(
                        child: Text(
                          row.value,
                          style: const TextStyle(fontSize: 12.6),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _danmakuSection() {
    if (_danmakuLoading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 22),
        child: Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    if (_danmaku.isEmpty) {
      return const Padding(
        padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Text(
          '這一集沒有彈幕。',
          style: TextStyle(fontSize: 12.8, color: AgpColors.fgFaint),
        ),
      );
    }

    final shown = _danmaku.length > 400 ? _danmaku.sublist(0, 400) : _danmaku;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(title: '彈幕', subtitle: '${_danmaku.length} 則'),
        Container(
          height: 260,
          margin: const EdgeInsets.fromLTRB(16, 2, 16, 4),
          decoration: BoxDecoration(
            color: Theme.of(context).cardTheme.color,
            borderRadius: BorderRadius.circular(kRadius),
            border: Border.all(color: AgpColors.line),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(kRadius),
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 4),
              itemCount: shown.length,
              itemBuilder: (context, index) {
                final comment = shown[index];
                return InkWell(
                  onTap: () => unawaited(_seekTo(comment.start)),
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 48,
                          child: Text(
                            formatClock(comment.start),
                            style: const TextStyle(
                              fontSize: 11.5,
                              color: AgpColors.fgFaint,
                            ),
                          ),
                        ),
                        Expanded(
                          child: Text(
                            comment.text,
                            style: TextStyle(fontSize: 12.6, color: comment.color),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ),
        if (_danmaku.length > shown.length)
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 2, 16, 8),
            child: Text(
              '只列出前 400 則，畫面上還是照播全部。',
              style: TextStyle(fontSize: 11.5, color: AgpColors.fgFaint),
            ),
          ),
      ],
    );
  }

  // ------------------------------------------------------------- 各種 sheet

  void _openRateSheet() {
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const _SheetTitle('播放速度'),
            for (final rate in kPlaybackRates)
              ListTile(
                dense: true,
                title: Text(rate == 1 ? '正常' : '$rate×'),
                trailing: _rate == rate
                    ? const Icon(Icons.check_rounded,
                        size: 18, color: AgpColors.accent)
                    : null,
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  unawaited(_setRate(rate));
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  void _openEpisodeSheet() {
    final info = _series;
    final groups = info != null && info.groups.isNotEmpty
        ? info.groups
        : [SeriesGroup(name: '', episodes: _orderedEpisodes())];
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.55,
        maxChildSize: 0.9,
        builder: (context, scrollController) => Column(
          children: [
            const _SheetTitle('選集'),
            Expanded(
              child: ListView(
                controller: scrollController,
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 22),
                children: [
                  for (final group in groups) ...[
                    if (group.name.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(2, 8, 2, 6),
                        child: Text(
                          group.name,
                          style: const TextStyle(
                            fontSize: 12.5,
                            color: AgpColors.fgFaint,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final episode in group.episodes)
                          _episodeChip(
                            episode,
                            onTap: () {
                              Navigator.of(sheetContext).pop();
                              unawaited(_switchTo(episode));
                            },
                          ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _openSettingsSheet() {
    unawaited(_loadQualities());
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) {
          void refresh(VoidCallback action) {
            action();
            setSheetState(() {});
          }

          return SafeArea(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const _SheetTitle('播放設定'),
                  _pickerTile<double>(
                    '播放速度',
                    _rate == 1 ? '正常' : '$_rate×',
                    kPlaybackRates
                        .map((r) => PlayerChoice(r, r == 1 ? '正常' : '$r×'))
                        .toList(),
                    _rate,
                    (value) => refresh(() => unawaited(_setRate(value))),
                  ),
                  // 清單是開這張選單時才去問的, 用 ValueNotifier 而不是頁面的
                  // setState —— StatefulBuilder 在另一棵樹上, 頁面重建帶不動它
                  ValueListenableBuilder<List<int>>(
                    valueListenable: _qualities,
                    builder: (context, options, _) => _pickerTile<int>(
                      '畫質',
                      _currentQuality > 0 ? '${_currentQuality}P' : '自動',
                      _qualityChoices(options),
                      _currentQuality,
                      (value) => refresh(() => unawaited(_switchQuality(value))),
                      note: state.offline
                          ? '離線中，只能播手機裡的那一份。'
                          : (options.isEmpty ? '正在問伺服器這一集還有哪些畫質…' : ''),
                    ),
                  ),
                  SwitchListTile(
                    dense: true,
                    title: const Text('彈幕'),
                    subtitle: _danmaku.isEmpty
                        ? const Text('這一集沒有彈幕檔，開啟後畫面不會有變化。',
                            style: TextStyle(fontSize: 11.5))
                        : null,
                    value: _danmakuOn,
                    onChanged: (value) =>
                        refresh(() => unawaited(_setDanmaku(value))),
                  ),
                  _pickerTile<int>(
                    '彈幕透明度',
                    '$_danmakuOpacity%',
                    kDanmakuOpacities
                        .map((o) => PlayerChoice(o, '$o%'))
                        .toList(),
                    _danmakuOpacity,
                    (value) => refresh(() {
                      setState(() => _danmakuOpacity = value);
                      unawaited(
                          state.savePref(() => prefs.setDanmakuOpacity(value)));
                    }),
                  ),
                  _pickerTile<double>(
                    '彈幕顯示區域',
                    kDanmakuAreas
                        .firstWhere((a) => a.value == _danmakuArea,
                            orElse: () => kDanmakuAreas.first)
                        .label,
                    kDanmakuAreas,
                    _danmakuArea,
                    (value) => refresh(() {
                      setState(() => _danmakuArea = value);
                      unawaited(state.savePref(() => prefs.setDanmakuArea(value)));
                    }),
                  ),
                  _pickerTile<double>(
                    '彈幕字級',
                    kDanmakuScales
                        .firstWhere((s) => s.value == _danmakuScale,
                            orElse: () => kDanmakuScales[1])
                        .label,
                    kDanmakuScales,
                    _danmakuScale,
                    (value) => refresh(() {
                      setState(() => _danmakuScale = value);
                      unawaited(state.savePref(() => prefs.setDanmakuScale(value)));
                    }),
                  ),
                  _pickerTile<double>(
                    '彈幕速度',
                    kDanmakuSpeeds
                        .firstWhere((s) => s.value == _danmakuSpeed,
                            orElse: () => kDanmakuSpeeds[1])
                        .label,
                    kDanmakuSpeeds,
                    _danmakuSpeed,
                    (value) => refresh(() {
                      setState(() => _danmakuSpeed = value);
                      unawaited(state.savePref(() => prefs.setDanmakuSpeed(value)));
                    }),
                  ),
                  _pickerTile<String>(
                    '畫面比例',
                    kAspectModes
                        .firstWhere((m) => m.value == _aspect,
                            orElse: () => kAspectModes.first)
                        .label,
                    kAspectModes,
                    _aspect,
                    (value) => refresh(() => unawaited(_setAspect(value))),
                  ),
                  _pickerTile<int>(
                    '畫面亮度',
                    '${(_brightness * 100).round()}%',
                    kBrightnessLevels.map((b) => PlayerChoice(b, '$b%')).toList(),
                    (_brightness * 100).round(),
                    (value) => refresh(
                        () => unawaited(_setBrightness(value / 100))),
                    note: '這會調暗播放畫面本身；App 不會改到裝置的螢幕亮度。',
                  ),
                  SwitchListTile(
                    dense: true,
                    title: const Text('自動播放下一集'),
                    value: _autoNext,
                    onChanged: (value) => refresh(() {
                      setState(() => _autoNext = value);
                      unawaited(state.savePref(() => prefs.setAutoNext(value)));
                    }),
                  ),
                  ListTile(
                    dense: true,
                    title: const Text('手勢說明'),
                    trailing: const Icon(Icons.chevron_right_rounded, size: 20),
                    onTap: () {
                      Navigator.of(sheetContext).pop();
                      _openGestureSheet();
                    },
                  ),
                  const SizedBox(height: 10),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _pickerTile<T>(
    String title,
    String value,
    List<PlayerChoice<T>> choices,
    T current,
    void Function(T value) onPick, {
    String note = '',
  }) {
    return ListTile(
      dense: true,
      title: Text(title),
      subtitle: note.isEmpty
          ? null
          : Text(note, style: const TextStyle(fontSize: 11.5)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(value,
              style: const TextStyle(fontSize: 12.5, color: AgpColors.fgFaint)),
          const Icon(Icons.chevron_right_rounded, size: 20),
        ],
      ),
      onTap: () async {
        final picked = await showModalBottomSheet<T>(
          context: context,
          builder: (sheetContext) => SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _SheetTitle(title),
                for (final choice in choices)
                  ListTile(
                    dense: true,
                    title: Text(choice.label),
                    trailing: choice.value == current
                        ? const Icon(Icons.check_rounded,
                            size: 18, color: AgpColors.accent)
                        : null,
                    onTap: () => Navigator.of(sheetContext).pop(choice.value),
                  ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        );
        if (picked != null) onPick(picked);
      },
    );
  }

  void _openGestureSheet() {
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const _SheetTitle('手勢說明'),
            for (final row in kGestureHelp)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 7),
                child: Row(
                  children: [
                    SizedBox(
                      width: 110,
                      child: Text(
                        row[0],
                        style: const TextStyle(
                            fontSize: 12.5, fontWeight: FontWeight.w700),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        row[1],
                        style: const TextStyle(
                            fontSize: 12.5, color: AgpColors.fgDim),
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }
}

class _SheetTitle extends StatelessWidget {
  const _SheetTitle(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          title,
          style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w800),
        ),
      ),
    );
  }
}
