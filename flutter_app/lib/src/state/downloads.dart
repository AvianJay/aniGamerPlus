/// 把片庫裡的一集抓到手機上, 離線也能看.
///
/// 這是網頁版沒有的功能, 但它沒有繞過伺服器: 抓的就是 /get_video.mp4 那一支,
/// 用 Range 續傳, 彈幕跟封面一起收在旁邊. 播放時只要本機有檔, 播放器就改讀
/// file://, 完全不碰網路.
///
/// iOS 上影片檔本身不是 Dart 在抓: App 退到背景幾秒之後就會被系統暫停, Dart
/// 跟著停. 那邊改交給系統的背景 URLSession ([NativeTransfer]), 這裡只管排隊、
/// 狀態跟收尾 (封面、彈幕). 見 [_runNative].
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:background_download/background_download.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../api/client.dart';
import '../api/models.dart';

/// waiting: 伺服器上還沒有這一集, 已經幫它排了一個任務, 檔案出現才開始抓.
enum DownloadStatus { waiting, queued, running, paused, done, failed }

/// 下載完之後隔多久回頭問一次彈幕. 伺服器是收到請求才開始生 .ass, 生完
/// 之前一律 404 —— 所以第一次一定撲空.
///
/// 這串以前只排到 34 秒就永遠放棄, 但伺服器生一集彈幕常常要更久 (它得先去
/// 巴哈把整份留言撈回來再轉檔), 於是「下載好的集數離線沒彈幕」就成了常態.
/// 現在退避拉到八分鐘, 而且過程記在 entry 上, 這一輪用完還有 retryMissingDanmaku().
const List<Duration> kDanmakuRetryWaits = [
  Duration.zero,
  Duration(seconds: 3),
  Duration(seconds: 6),
  Duration(seconds: 10),
  Duration(seconds: 15),
  Duration(seconds: 30),
  Duration(seconds: 60),
  Duration(seconds: 120),
  Duration(seconds: 240),
];

/// 這段文字真的是一份 ASS 字幕嗎.
///
/// 非得檢查不可: 伺服器把 danmu 關掉的時候, /get_danmu.ass 回的是
/// 「Danmu is not enabled」這句 HTML, 而且是 HTTP 200. 只看「回來的東西
/// 不是空的」就存檔的話, 那句話會被當成彈幕檔寫進 `<sn>.ass`, 之後永遠
/// 解析不出一條彈幕, 也不會有人再去重抓.
bool looksLikeAss(String text) {
  if (text.length < 16) return false;
  return text.contains('[Script Info]') || text.contains('Dialogue:');
}

/// 同一集最快隔多久才願意再去問一次彈幕 (retryMissingDanmaku 用)
const Duration kDanmakuRetryCooldown = Duration(minutes: 10);

/// 等伺服器下載完的輪詢間隔. 只是一個 HEAD, 但沒必要問太勤 ——
/// 伺服器抓一集本來就是好幾分鐘的事.
const Duration kWaitingPollInterval = Duration(seconds: 45);

class DownloadEntry {
  final String sn;
  String animeName;
  String episode;
  String title;
  int resolution;
  int received;
  int total;
  DownloadStatus status;
  String error;
  int addedAt;

  /// 使用者想不想要彈幕 (下載時的「一起抓彈幕」)
  bool wantDanmaku;

  /// 彈幕檔真的躺在硬碟上了
  bool hasDanmaku;
  bool hasThumb;

  /// 已經為彈幕試過幾次, 上次是什麼時候. 落盤留著 —— app 被關掉重開之後
  /// 才知道這一集是「剛下載完還在等」還是「試了很久都沒有」.
  int danmakuTries;
  int danmakuLastTry;

  DownloadEntry({
    required this.sn,
    this.animeName = '',
    this.episode = '',
    this.title = '',
    this.resolution = 0,
    this.received = 0,
    this.total = 0,
    this.status = DownloadStatus.queued,
    this.error = '',
    int? addedAt,
    this.wantDanmaku = true,
    this.hasDanmaku = false,
    this.hasThumb = false,
    this.danmakuTries = 0,
    this.danmakuLastTry = 0,
  }) : addedAt = addedAt ?? DateTime.now().millisecondsSinceEpoch;

  double get progress {
    if (status == DownloadStatus.done) return 1;
    if (total <= 0) return 0;
    final value = received / total;
    return value.isNaN ? 0 : value.clamp(0.0, 1.0);
  }

  String get videoFileName =>
      resolution > 0 ? '$sn-${resolution}p.mp4' : '$sn.mp4';

  String get displayName => animeName.isNotEmpty ? animeName : title;

  Map<String, dynamic> toJson() => {
        'sn': sn,
        'anime_name': animeName,
        'episode': episode,
        'title': title,
        'resolution': resolution,
        'received': received,
        'total': total,
        'status': status.name,
        'error': error,
        'addedAt': addedAt,
        'wantDanmaku': wantDanmaku,
        'hasDanmaku': hasDanmaku,
        'hasThumb': hasThumb,
        'danmakuTries': danmakuTries,
        'danmakuLastTry': danmakuLastTry,
      };

  factory DownloadEntry.fromJson(Map<String, dynamic> json) {
    final rawStatus = (json['status'] ?? 'queued').toString();
    return DownloadEntry(
      sn: (json['sn'] ?? '').toString(),
      animeName: (json['anime_name'] ?? '').toString(),
      episode: (json['episode'] ?? '').toString(),
      title: (json['title'] ?? '').toString(),
      resolution: int.tryParse('${json['resolution']}') ?? 0,
      received: int.tryParse('${json['received']}') ?? 0,
      total: int.tryParse('${json['total']}') ?? 0,
      status: DownloadStatus.values.firstWhere(
        (s) => s.name == rawStatus,
        // 上次是在下載中被殺掉的, 重開之後當成暫停, 由使用者決定要不要續
        orElse: () => DownloadStatus.queued,
      ),
      error: (json['error'] ?? '').toString(),
      addedAt: int.tryParse('${json['addedAt']}') ?? 0,
      // 舊紀錄沒這個欄位, 當成「要」—— 這是預設值
      wantDanmaku: json['wantDanmaku'] != false,
      hasDanmaku: json['hasDanmaku'] == true,
      hasThumb: json['hasThumb'] == true,
      danmakuTries: int.tryParse('${json['danmakuTries']}') ?? 0,
      danmakuLastTry: int.tryParse('${json['danmakuLastTry']}') ?? 0,
    );
  }

  /// 這一集是不是可以離線播
  bool get playable => status == DownloadStatus.done;

  /// 在等伺服器把這一集抓下來
  bool get waitingForServer => status == DownloadStatus.waiting;

  /// 還缺彈幕, 而且使用者是要的
  bool get danmakuPending => playable && wantDanmaku && !hasDanmaku;
}

class DownloadStore extends ChangeNotifier {
  /// [native] 給了就由它抓影片檔 (iOS 的背景 URLSession), 否則 Dart 自己抓.
  DownloadStore(this._client, {NativeTransfer? native}) : _native = native;

  AgpClient _client;
  set client(AgpClient value) => _client = value;

  final NativeTransfer? _native;
  final Map<String, Completer<TransferResult>> _nativeWaiters = {};
  final List<StreamSubscription<Object>> _nativeSubscriptions = [];

  /// App 在背景: 原生傳輸的話把排隊的全部交出去 —— App 被暫停之後就沒人
  /// 能再開下一集了, 由系統自己排.
  bool _backgrounded = false;

  /// 「只用 Wi-Fi」關著的時候才准用行動網路. 原生傳輸要在請求上標好,
  /// App 被暫停之後換了網路也不會偷用行動數據. 見 [DownloadNetwork].
  bool cellularAllowed = true;

  Directory? _dir;
  final Map<String, DownloadEntry> _entries = {};
  final Map<String, _Job> _jobs = {};
  int _concurrency = 1;
  int get concurrency => _concurrency;
  set concurrency(int value) {
    _concurrency = value.clamp(0, 3);
    unawaited(_pump());
  }

  bool _ready = false;
  bool _disposed = false;
  bool _networkAllowed = true;
  bool get networkAllowed => _networkAllowed;

  Future<void> setNetworkAllowed(bool allowed) async {
    if (_disposed || allowed == _networkAllowed) return;
    _networkAllowed = allowed;
    if (!allowed) {
      for (final job in _jobs.values) {
        job.cancel();
        if (job.entry.status == DownloadStatus.running) {
          job.entry.status = DownloadStatus.queued;
        }
      }
    }
    await _save();
    notifyListeners();
    _syncWaitingTimer();
    if (allowed) {
      unawaited(_pump());
      unawaited(pollWaiting());
      unawaited(retryMissingDanmaku());
    }
  }

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  bool get ready => _ready;

  List<DownloadEntry> get entries {
    final list = _entries.values.toList();
    list.sort((a, b) => b.addedAt.compareTo(a.addedAt));
    return list;
  }

  List<DownloadEntry> get finished =>
      entries.where((e) => e.status == DownloadStatus.done).toList();

  List<DownloadEntry> get active => entries
      .where((e) =>
          e.status == DownloadStatus.running ||
          e.status == DownloadStatus.queued ||
          e.status == DownloadStatus.waiting ||
          e.status == DownloadStatus.paused ||
          e.status == DownloadStatus.failed)
      .toList();

  int get runningCount =>
      _entries.values.where((e) => e.status == DownloadStatus.running).length;

  /// 有沒有集數在等伺服器
  bool get hasWaiting =>
      _entries.values.any((e) => e.status == DownloadStatus.waiting);

  /// 下載好了但還沒拿到彈幕的集數
  List<DownloadEntry> get danmakuPending =>
      entries.where((e) => e.danmakuPending).toList();

  DownloadEntry? entryFor(String sn) => _entries[sn];

  bool isDownloaded(String sn) => _entries[sn]?.playable ?? false;

  Future<void> init({int concurrency = 1}) async {
    this.concurrency = concurrency < 1 ? 1 : concurrency;
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/downloads');
    if (!await dir.exists()) await dir.create(recursive: true);
    _dir = dir;
    _danmakuCache = Directory('${base.path}/danmaku-cache');

    final index = File('${dir.path}/index.json');
    if (await index.exists()) {
      try {
        final list = jsonDecode(await index.readAsString());
        if (list is List) {
          for (final raw in list.whereType<Map>()) {
            final entry = DownloadEntry.fromJson(raw.cast<String, dynamic>());
            if (entry.sn.isEmpty) continue;
            // 上一輪是被系統殺掉的, 不會有人幫它把狀態寫回去.
            // 原生傳輸的話可能其實還在背景跑, _attachNative 會再把它接回來.
            if (entry.status == DownloadStatus.running) {
              entry.status = DownloadStatus.paused;
            }
            _entries[entry.sn] = entry;
          }
        }
      } catch (_) {
        // 索引壞了就從零開始, 檔案還在, 使用者可以重下
      }
    }
    await _reconcile();
    if (_native != null) await _attachNative();
    _ready = true;
    notifyListeners();
    unawaited(_pump());
    // 上次關掉時還在等伺服器 / 還缺彈幕的, 開機就接手
    _syncWaitingTimer();
    unawaited(pollWaiting());
    unawaited(retryMissingDanmaku());
  }

  /// 檔案被系統清掉 / 使用者從檔案 app 刪掉的話, 索引要跟上
  Future<void> _reconcile() async {
    final gone = <String>[];
    for (final entry in _entries.values) {
      if (entry.status != DownloadStatus.done) continue;
      if (!await videoFile(entry).exists()) gone.add(entry.sn);
    }
    for (final sn in gone) {
      _entries[sn]!.status = DownloadStatus.failed;
      _entries[sn]!.error = '檔案不見了';
      _entries[sn]!.received = 0;
    }
    if (gone.isNotEmpty) await _save();
  }

  Directory get directory {
    final dir = _dir;
    if (dir == null) throw StateError('DownloadStore.init() 還沒跑完');
    return dir;
  }

  File videoFile(DownloadEntry entry) =>
      File('${directory.path}/${entry.videoFileName}');

  File partFile(DownloadEntry entry) =>
      File('${directory.path}/${entry.videoFileName}.part');

  File danmakuFile(String sn) => File('${directory.path}/$sn.ass');

  File thumbFile(String sn) => File('${directory.path}/$sn.jpg');

  /// 播放器問的就是這一支: 有本機檔就別走網路
  File? localVideo(String sn) {
    final entry = _entries[sn];
    if (entry == null || !entry.playable) return null;
    final file = videoFile(entry);
    return file.existsSync() ? file : null;
  }

  File? localDanmaku(String sn) {
    final file = danmakuFile(sn);
    return file.existsSync() ? file : null;
  }

  File? localThumb(String sn) {
    final file = thumbFile(sn);
    return file.existsSync() ? file : null;
  }

  Future<int> totalBytesOnDisk() async {
    var total = 0;
    if (_dir == null) return 0;
    await for (final item in directory.list()) {
      if (item is File) {
        try {
          total += await item.length();
        } catch (_) {
          // 正在被寫的檔案量不到就跳過
        }
      }
    }
    return total;
  }

  Future<void> _save() async {
    if (_dir == null) return;
    // A pause, progress update and completion can all save concurrently.
    // Serialize writes so an older snapshot cannot overwrite a newer one.
    final body = jsonEncode(_entries.values.map((e) => e.toJson()).toList());
    final previous = _saving;
    final write = () async {
      try {
        await previous;
      } catch (_) {}
      final index = File('${directory.path}/index.json');
      final temp = File('${index.path}.tmp');
      await temp.writeAsString(body, flush: true);
      await temp.rename(index.path);
    }();
    _saving = write;
    return write;
  }

  Future<void> _saving = Future<void>.value();

  // ------------------------------------------------------------------ 佇列

  Future<DownloadEntry> enqueue(
    VideoItem video, {
    bool withDanmaku = true,
  }) =>
      _put(video, withDanmaku: withDanmaku, status: DownloadStatus.queued);

  /// 伺服器上還沒有這一集: 先在清單裡佔位, 檔案出現了 pollWaiting() 會接手.
  ///
  /// 沒辦法直接開始抓 —— /get_video.mp4 是照片庫的清單找檔案的, 找不到就 404,
  /// 所以在伺服器抓完之前這裡除了等沒有別的事可做.
  Future<DownloadEntry> enqueueWaiting(
    VideoItem video, {
    bool withDanmaku = true,
  }) =>
      _put(video, withDanmaku: withDanmaku, status: DownloadStatus.waiting);

  Future<DownloadEntry> _put(
    VideoItem video, {
    required bool withDanmaku,
    required DownloadStatus status,
  }) async {
    final existing = _entries[video.sn];
    if (existing != null && existing.playable) return existing;
    if (existing != null && _jobs.containsKey(video.sn)) return existing;

    final entry = existing ??
        DownloadEntry(
          sn: video.sn,
          animeName: video.animeName,
          episode: video.episode,
          title: video.title,
          resolution: video.resolution,
        );
    entry.animeName =
        video.animeName.isNotEmpty ? video.animeName : entry.animeName;
    entry.episode = video.episode.isNotEmpty ? video.episode : entry.episode;
    entry.title = video.title.isNotEmpty ? video.title : entry.title;
    if (video.resolution > 0) entry.resolution = video.resolution;
    entry.status = status;
    entry.error = '';
    // video.danmu 是「伺服器現在手上有沒有這一集的彈幕」, 拿它當條件的話,
    // 伺服器還沒生檔的集數就永遠不會去抓. 想不想要是使用者決定的, 有沒有
    // 抓到等 _fetchDanmaku 回報.
    entry.wantDanmaku = withDanmaku;
    // 之前抓過的那一份還在就算有, 不必再跑一輪
    entry.hasDanmaku = danmakuFile(entry.sn).existsSync();
    _entries[entry.sn] = entry;

    await _save();
    notifyListeners();
    if (status == DownloadStatus.waiting) {
      _syncWaitingTimer();
    } else {
      unawaited(_pump());
    }
    return entry;
  }

  Future<void> pause(String sn) async {
    final entry = _entries[sn];
    if (entry == null) return;
    // cancel 但不從 _jobs 拿掉: 在那個 job 真的收完之前, _jobs 是唯一擋住
    // 「同一個 sn 又被 _pump() 開一個」的東西. 讓出那一格是 _run() 的 finally
    // 的事, 而且只有在那一格還是它自己的時候.
    _jobs[sn]?.cancel();
    if (entry.status == DownloadStatus.running ||
        entry.status == DownloadStatus.queued ||
        entry.status == DownloadStatus.waiting) {
      entry.status = DownloadStatus.paused;
    }
    await _save();
    notifyListeners();
    _syncWaitingTimer();
    unawaited(_pump());
  }

  Future<void> resume(String sn) async {
    final entry = _entries[sn];
    if (entry == null || entry.playable) return;
    entry.status = DownloadStatus.queued;
    entry.error = '';
    await _save();
    notifyListeners();
    unawaited(_pump());
  }

  Future<void> remove(String sn, {bool deleteFiles = true}) async {
    // Remove from the queue before awaiting cancellation; _run's finally must
    // not start another copy while this deletion is waiting for the file sink.
    final entry = _entries.remove(sn);
    final job = _jobs[sn];
    if (job != null) {
      job.cancel();
      // 等它真的收完再刪檔: 還開著 sink 的時候把 .part 刪掉, 在 Windows 上是
      // 一個例外, 在別的平台上是刪完又被寫回來
      await job.done.future
          .timeout(const Duration(seconds: 10), onTimeout: () {});
    }
    if (entry != null && deleteFiles) {
      for (final file in [
        videoFile(entry),
        partFile(entry),
        danmakuFile(sn),
        thumbFile(sn),
      ]) {
        try {
          if (await file.exists()) await file.delete();
        } catch (_) {
          // 刪不掉就算了, 下次 _reconcile 會處理
        }
      }
    }
    // 暫停時原生那邊留的續傳資料 (抓到一半的那一段在系統手上, 不在 .part 裡)
    if (entry != null && _native != null) {
      unawaited(_native.discard(entry.videoFileName).catchError((Object _) {}));
    }
    await _save();
    notifyListeners();
    _syncWaitingTimer();
    unawaited(_pump());
  }

  Future<void> pauseAll() async {
    for (final entry in _entries.values) {
      if (entry.status == DownloadStatus.running ||
          entry.status == DownloadStatus.queued ||
          entry.status == DownloadStatus.waiting) {
        _jobs[entry.sn]?.cancel();
        entry.status = DownloadStatus.paused;
      }
    }
    await _save();
    notifyListeners();
    _syncWaitingTimer();
  }

  Future<void> resumeAll() async {
    for (final entry in _entries.values) {
      if (entry.status == DownloadStatus.paused ||
          entry.status == DownloadStatus.failed) {
        entry.status = DownloadStatus.queued;
        entry.error = '';
      }
    }
    await _save();
    notifyListeners();
    unawaited(_pump());
  }

  // ------------------------------------------------------- 等伺服器下載完成
  //
  // 「下載單集到手機」對還沒進片庫的集數是分兩段的: 先請伺服器抓, 伺服器抓完
  // 才輪到手機. 中間這段沒有人會通知我們 —— /manualTask 送出去就沒下文了,
  // 任務監控的 WebSocket 又只有管理員連得上. 所以就照著問: 一個 HEAD 打在
  // /get_video.mp4 上, 有檔案了才轉成 queued.

  Timer? _waitingTimer;
  bool _polling = false;

  void _syncWaitingTimer() {
    if (!_disposed && _networkAllowed && hasWaiting) {
      _waitingTimer ??= Timer.periodic(
        kWaitingPollInterval,
        (_) => unawaited(pollWaiting()),
      );
    } else {
      _waitingTimer?.cancel();
      _waitingTimer = null;
    }
  }

  /// 問一輪伺服器: 等著的那幾集有沒有檔案了. 回線上時也叫這支.
  Future<void> pollWaiting() async {
    if (_disposed || !_networkAllowed || _polling || !_client.hasServer) return;
    final pending = _entries.values
        .where((e) => e.status == DownloadStatus.waiting)
        .toList();
    if (pending.isEmpty) {
      _syncWaitingTimer();
      return;
    }
    _polling = true;
    var promoted = false;
    try {
      for (final entry in pending) {
        // 一集一集問, 不要為了幾個 HEAD 同時開一堆連線
        if (!_entries.containsKey(entry.sn)) continue;
        if (entry.status != DownloadStatus.waiting) continue;
        if (!await _serverHasVideo(entry)) continue;
        if (_disposed ||
            !_networkAllowed ||
            !identical(_entries[entry.sn], entry) ||
            entry.status != DownloadStatus.waiting) {
          continue;
        }
        entry.status = DownloadStatus.queued;
        entry.error = '';
        promoted = true;
      }
    } finally {
      _polling = false;
    }
    if (promoted) {
      await _save();
      notifyListeners();
      unawaited(_pump());
    }
    _syncWaitingTimer();
  }

  Future<bool> _serverHasVideo(DownloadEntry entry) async {
    try {
      final response = await http.head(
        _client.videoUrl(
          entry.sn,
          resolution: entry.resolution > 0 ? entry.resolution : null,
        ),
        headers: _client.authHeaders,
      );
      return response.statusCode >= 200 && response.statusCode < 300;
    } catch (_) {
      // 連不上就當作還沒好, 下一輪再問
      return false;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    for (final job in _jobs.values) {
      // 原生傳輸不叫停: 那是系統在抓, 這個 store 不在了, 下次起來還接得回去
      if (_native == null) {
        job.cancel();
      } else {
        job.cancelled = true;
      }
    }
    for (final waiter in _nativeWaiters.values) {
      if (!waiter.isCompleted) {
        waiter.complete(
            const TransferResult(sn: '', status: TransferStatus.cancelled));
      }
    }
    for (final subscription in _nativeSubscriptions) {
      unawaited(subscription.cancel());
    }
    _waitingTimer?.cancel();
    _waitingTimer = null;
    super.dispose();
  }

  /// App 進 / 出背景. 見 [_backgrounded].
  void setBackgrounded(bool value) {
    if (value == _backgrounded) return;
    _backgrounded = value;
    if (value) unawaited(_pump());
  }

  /// 同時開幾集. 原生傳輸又在背景的話不設限: 全部交給系統排.
  int get _slots =>
      _native != null && _backgrounded && _concurrency > 0
          ? _entries.length
          : _concurrency;

  Future<void> _pump() async {
    if (_disposed || !_networkAllowed || _dir == null) return;
    while (runningCount < _slots) {
      DownloadEntry? next;
      for (final entry in entries.reversed) {
        // 同一個 sn 已經有 job 在跑就跳過 —— 就算它已經被 cancel 了.
        //
        // 暫停只是把 cancelled 立起來, job 還要再跑好幾個 await 才收得完
        // (flush、close、量 .part 的長度、_save). 在那之前就讓第二個 job 進場
        // 的話: 兩個 job 對著同一個 .part 寫, 新的那個量到的長度是舊的還沒
        // flush 出去的舊值, 而且舊的那個收尾時會把新的那個從 _jobs 裡移掉、
        // 順手把它的狀態從 running 改成 paused.
        if (entry.status == DownloadStatus.queued &&
            !_jobs.containsKey(entry.sn)) {
          next = entry;
          break;
        }
      }
      if (next == null) return;
      next.status = DownloadStatus.running;
      notifyListeners();
      final job = _Job(next);
      _jobs[next.sn] = job;
      unawaited(_run(job));
    }
  }

  Future<void> _run(_Job job) async {
    if (_native != null) return _runNative(job);
    final entry = job.entry;
    final part = partFile(entry);
    final target = videoFile(entry);
    IOSink? sink;

    try {
      var start = 0;
      if (await part.exists()) {
        start = await part.length();
      }

      final request = http.Request(
          'GET',
          _client.videoUrl(
            entry.sn,
            resolution: entry.resolution > 0 ? entry.resolution : null,
          ));
      request.headers.addAll(_client.authHeaders);
      if (start > 0) request.headers['Range'] = 'bytes=$start-';

      final response = await job.client.send(request);
      if (job.cancelled || _disposed) return;

      if (response.statusCode == 416) {
        // 已經抓完了, 只是上次沒改名
        await part.rename(target.path);
        await _finish(job, entry);
        return;
      }
      if (response.statusCode == 404) {
        // 伺服器手上沒有這一集 —— 排隊中的伺服器任務還沒跑到, 或者檔案被清了.
        // 這不是失敗, 是還沒輪到: 退回去等, pollWaiting() 會盯著.
        entry.status = DownloadStatus.waiting;
        entry.error = '';
        await _save();
        notifyListeners();
        _syncWaitingTimer();
        return;
      }
      if (response.statusCode >= 400) {
        throw HttpException('伺服器回應 ${response.statusCode}');
      }

      // 200 表示伺服器不吃 Range (或檔案換了), 那就從頭來
      if (response.statusCode == 200 && start > 0) {
        start = 0;
        if (await part.exists()) await part.delete();
      }

      final length = response.contentLength ?? 0;
      entry.total = start + length;
      entry.received = start;
      notifyListeners();

      sink = part.openWrite(mode: start > 0 ? FileMode.append : FileMode.write);
      var sinceFlush = 0;

      await for (final chunk in response.stream) {
        if (job.cancelled) break;
        sink.add(chunk);
        entry.received += chunk.length;
        sinceFlush += chunk.length;
        // 每 1 MB 才通知一次: 每個封包都畫一次的話畫面全花在重繪上
        if (sinceFlush >= 1024 * 1024) {
          sinceFlush = 0;
          notifyListeners();
        }
      }

      await sink.flush();
      await sink.close();
      sink = null;

      if (job.cancelled) {
        entry.received = await part.length();
        // 只有這一格還是自己的時候才動它的狀態
        if (identical(_jobs[entry.sn], job) &&
            entry.status == DownloadStatus.running) {
          entry.status = DownloadStatus.paused;
        }
        await _save();
        notifyListeners();
        return;
      }

      final written = await part.length();
      if (entry.total > 0 && written < entry.total) {
        throw HttpException('傳輸中斷 ($written/${entry.total})');
      }
      if (await target.exists()) await target.delete();
      await part.rename(target.path);
      entry.received = written;
      entry.total = written;
      await _finish(job, entry);
    } catch (error) {
      try {
        await sink?.flush();
        await sink?.close();
      } catch (_) {
        // 已經關掉了
      }
      if (!job.cancelled) {
        entry.status = DownloadStatus.failed;
        entry.error = error.toString();
        await _save();
        notifyListeners();
      }
    } finally {
      job.client.close();
      // 只讓出自己那一格. 無條件 remove 的話, 被取消的舊 job 收尾時會把接手的
      // 新 job 從表上抹掉 —— 之後 pause() 找不到它, _pump() 又會再開一個.
      if (identical(_jobs[entry.sn], job)) _jobs.remove(entry.sn);
      job.finish();
      unawaited(_pump());
    }
  }

  // ------------------------------------------------------- 原生傳輸 (iOS)
  //
  // 影片檔交給系統的背景 URLSession, 這邊等它回報. 續傳還是 .part: 起點是
  // .part 的長度, 原生那邊抓完把剩下的接上去再改名, 所以做完的時候檔案已經在
  // videoFile() 了. 暫停的時候系統另外留一份續傳資料, 下次同一個檔名接著抓.
  //
  // App 被系統收掉的話, 這裡的 job 跟 Future 都沒了, 但系統還在抓. 下次起來
  // _attachNative 問一次: 還在跑的接回來, 已經做完的 (結果原生那邊有落盤) 照做.

  /// [attach]: 原生那邊本來就在跑 (App 重開), 只要等它的結果.
  Future<void> _runNative(_Job job, {bool attach = false}) async {
    final native = _native!;
    final entry = job.entry;
    final waiter = Completer<TransferResult>();
    _nativeWaiters[entry.sn] = waiter;
    var started = Future<void>.value();
    job.onCancel = () async {
      // start 還在路上的話, 原生那邊還沒有東西可以停: 等它建好再停
      try {
        await started;
      } catch (_) {}
      bool found;
      try {
        found = await native.cancel(entry.sn);
      } catch (_) {
        found = false;
      }
      // 沒停到東西就不會有結果回來, 自己把這一輪結束掉
      if (!found && !waiter.isCompleted) {
        waiter.complete(TransferResult(
          sn: entry.sn,
          status: TransferStatus.cancelled,
          received: entry.received,
        ));
      }
    };

    try {
      if (!attach) {
        final part = partFile(entry);
        var start = 0;
        if (await part.exists()) start = await part.length();
        if (entry.received < start) entry.received = start;
        if (job.cancelled || _disposed) return;
        started = native.start(
          sn: entry.sn,
          url: _client.videoUrl(
            entry.sn,
            resolution: entry.resolution > 0 ? entry.resolution : null,
          ),
          headers: _client.authHeaders,
          directory: directory.path,
          fileName: entry.videoFileName,
          offset: start,
          allowCellular: cellularAllowed,
          label: '${entry.displayName} ${entry.episode}'.trim(),
        );
        await started;
      }
      final result = await waiter.future;
      if (_disposed) return;
      await _applyNative(job, entry, result);
    } catch (error) {
      if (!job.cancelled && !_disposed) {
        entry.status = DownloadStatus.failed;
        entry.error = error is PlatformException
            ? (error.message ?? error.code)
            : error.toString();
        await _save();
        notifyListeners();
      }
    } finally {
      if (identical(_nativeWaiters[entry.sn], waiter)) {
        _nativeWaiters.remove(entry.sn);
      }
      job.client.close();
      if (identical(_jobs[entry.sn], job)) _jobs.remove(entry.sn);
      job.finish();
      unawaited(_pump());
    }
  }

  Future<void> _applyNative(
    _Job job,
    DownloadEntry entry,
    TransferResult result,
  ) async {
    switch (result.status) {
      case TransferStatus.done:
        // 就算剛好在這時候按了暫停: 檔案已經完整躺在那裡了
        final size = result.total > 0 ? result.total : result.received;
        entry.received = size;
        entry.total = size;
        await _finish(job, entry);
      case TransferStatus.notFound:
        // 同 _run 的 404: 還沒輪到, 退回去等
        entry.status = DownloadStatus.waiting;
        entry.error = '';
        await _save();
        notifyListeners();
        _syncWaitingTimer();
      case TransferStatus.failed:
        if (!job.cancelled) {
          entry.status = DownloadStatus.failed;
          entry.error = result.error.isEmpty ? '下載失敗' : result.error;
          await _save();
          notifyListeners();
        }
      case TransferStatus.cancelled:
        // 抓到一半的那一段在系統的續傳資料裡, 不在 .part 裡 —— 進度照原生報的
        if (result.received > entry.received) entry.received = result.received;
        if (identical(_jobs[entry.sn], job) &&
            entry.status == DownloadStatus.running) {
          entry.status = DownloadStatus.paused;
        }
        await _save();
        notifyListeners();
    }
    if (result.status != TransferStatus.cancelled) {
      unawaited(_native!.ack(entry.sn).catchError((Object _) {}));
    }
  }

  Future<void> _attachNative() async {
    final native = _native!;
    _nativeSubscriptions
      ..add(native.progress.listen(_onNativeProgress))
      ..add(native.results.listen(_onNativeResult));
    final TransferSnapshot snapshot;
    try {
      snapshot = await native.snapshot();
    } catch (_) {
      return;
    }
    // Dart 不在的時候做完的
    for (final result in snapshot.results) {
      await _adoptNativeResult(result);
    }
    // App 被收掉的時候還在抓、現在也還在抓的
    for (final task in snapshot.running) {
      final entry = _entries[task.sn];
      if (entry == null || entry.playable) {
        // 那一集在這段時間裡被刪了
        unawaited(() async {
          try {
            await native.cancel(task.sn);
            if (task.fileName.isNotEmpty) await native.discard(task.fileName);
          } catch (_) {}
        }());
        continue;
      }
      if (_jobs.containsKey(task.sn)) continue;
      if (!_networkAllowed) {
        // 只用 Wi-Fi 但現在不在 Wi-Fi 上: 停下來, 回到 Wi-Fi 再排
        entry.status = DownloadStatus.queued;
        unawaited(native.cancel(task.sn).catchError((Object _) => false));
        continue;
      }
      entry.status = DownloadStatus.running;
      entry.error = '';
      if (task.received > entry.received) entry.received = task.received;
      if (task.total > 0) entry.total = task.total;
      final job = _Job(entry);
      _jobs[entry.sn] = job;
      unawaited(_runNative(job, attach: true));
    }
    await _save();
  }

  void _onNativeProgress(TransferProgress progress) {
    final entry = _entries[progress.sn];
    if (entry == null || entry.status != DownloadStatus.running) return;
    entry.received = progress.received;
    if (progress.total > 0) entry.total = progress.total;
    notifyListeners();
  }

  void _onNativeResult(TransferResult result) {
    final waiter = _nativeWaiters[result.sn];
    if (waiter != null && !waiter.isCompleted) {
      waiter.complete(result);
      return;
    }
    unawaited(_adoptNativeResult(result));
  }

  /// 沒有 job 在等的結果: App 重開前做完的, 或是暫停之後才收到的.
  Future<void> _adoptNativeResult(TransferResult result) async {
    if (result.status == TransferStatus.cancelled || _disposed) return;
    final entry = _entries[result.sn];
    if (entry == null) {
      // 那一集已經被刪了, 檔案別留著佔空間
      if (result.status == TransferStatus.done && result.fileName.isNotEmpty) {
        try {
          final orphan = File('${directory.path}/${result.fileName}');
          if (await orphan.exists()) await orphan.delete();
        } catch (_) {}
      }
    } else if (!entry.playable && !_jobs.containsKey(entry.sn)) {
      switch (result.status) {
        case TransferStatus.done:
          if (await videoFile(entry).exists()) {
            final size = result.total > 0 ? result.total : result.received;
            entry.received = size;
            entry.total = size;
            final job = _Job(entry);
            try {
              await _finish(job, entry);
            } finally {
              job.client.close();
            }
          }
        case TransferStatus.notFound:
          entry.status = DownloadStatus.waiting;
          entry.error = '';
          _syncWaitingTimer();
        case TransferStatus.failed:
          entry.status = DownloadStatus.failed;
          entry.error = result.error.isEmpty ? '下載失敗' : result.error;
        case TransferStatus.cancelled:
          break;
      }
      await _save();
      notifyListeners();
    }
    try {
      await _native?.ack(result.sn);
    } catch (_) {}
  }

  Future<void> _finish(_Job job, DownloadEntry entry) async {
    entry.status = DownloadStatus.done;
    entry.error = '';
    await _save();
    notifyListeners();

    // 封面是配菜, 抓不到不該讓整集算失敗
    try {
      if (job.cancelled || _disposed || !_networkAllowed) return;
      final response = await job.client.get(
        _client.thumbnailUrl(entry.sn),
        headers: _client.authHeaders,
      );
      if (job.cancelled || _disposed || !identical(_entries[entry.sn], entry)) {
        return;
      }
      if (response.statusCode == 200 && response.bodyBytes.isNotEmpty) {
        await thumbFile(entry.sn).writeAsBytes(response.bodyBytes);
        entry.hasThumb = true;
      }
    } catch (_) {
      entry.hasThumb = thumbFile(entry.sn).existsSync();
    }

    await _save();
    notifyListeners();

    // 彈幕另外跑, 不佔佇列: 見 _fetchDanmaku, 這一輪最久撐八分鐘,
    // 還是沒有的話留給 retryMissingDanmaku()
    if (entry.wantDanmaku) unawaited(_fetchDanmaku(entry));
  }

  /// 伺服器的 /get_danmu.ass 是被問到才去生檔的 —— 檔案還沒生出來之前它
  /// 直接回 404, 同時在背景開一條 thread 去抓. 問一次就放棄的話, 剛下載完
  /// 的那一集離線永遠沒有彈幕, 所以這裡多問幾輪等它生完.
  Future<void> _fetchDanmaku(DownloadEntry entry) async {
    for (final wait in kDanmakuRetryWaits) {
      if (_disposed || !_networkAllowed) return;
      if (wait > Duration.zero) await Future<void>.delayed(wait);
      // 等待途中被刪掉了就別再寫檔
      if (_disposed ||
          !_networkAllowed ||
          !identical(_entries[entry.sn], entry)) {
        return;
      }
      if (await _tryDanmakuOnce(entry)) return;
    }
    if (entry.hasDanmaku && !danmakuFile(entry.sn).existsSync()) {
      entry.hasDanmaku = false;
      await _save();
      notifyListeners();
    }
  }

  /// 問一次. 拿到真的字幕就落盤並回 true.
  Future<bool> _tryDanmakuOnce(DownloadEntry entry) async {
    if (_disposed || !_networkAllowed) return false;
    entry.danmakuTries += 1;
    try {
      final ass = await _client.danmakuAss(entry.sn);
      if (_disposed ||
          !_networkAllowed ||
          !identical(_entries[entry.sn], entry)) {
        return false;
      }
      // 只有真的問到伺服器才算一次「試過」. 連線失敗不記 —— 不然離線開機時
      // 白跑的那一輪會把冷卻時間吃掉, 等真的有網路了反而被自己擋住.
      entry.danmakuLastTry = DateTime.now().millisecondsSinceEpoch;
      if (looksLikeAss(ass)) {
        await danmakuFile(entry.sn).writeAsString(ass);
        entry.hasDanmaku = true;
        await _save();
        notifyListeners();
        return true;
      }
      // 沒抓到也要落盤. 冷卻是記在索引裡的, 不寫回去的話重開 app 就等於
      // 從來沒試過, 每次開機都會把所有缺彈幕的集數再打一輪.
      await _save();
    } catch (_) {
      // 網路斷了就算了, 彈幕是配菜
    }
    return false;
  }

  /// 把還缺彈幕的集數再撈一遍.
  ///
  /// _fetchDanmaku 那一輪最多撐八分鐘, 但伺服器可能更慢 (或者當時根本沒網路).
  /// 開機、回到線上、使用者在下載頁按「補抓彈幕」都會走到這裡, 所以「當時沒抓到」
  /// 不再等於「永遠沒有」.
  Future<void> retryMissingDanmaku({bool force = false}) async {
    if (_disposed || !_networkAllowed || _dir == null || !_client.hasServer) {
      return;
    }
    if (_retryingDanmaku) return;
    _retryingDanmaku = true;
    try {
      final now = DateTime.now().millisecondsSinceEpoch;
      for (final entry in _entries.values.toList()) {
        if (!entry.danmakuPending) continue;
        // 手上已經有檔案的話只是狀態沒對上, 補一下就好
        if (danmakuFile(entry.sn).existsSync()) {
          entry.hasDanmaku = true;
          await _save();
          notifyListeners();
          continue;
        }
        if (!force &&
            entry.danmakuLastTry > 0 &&
            now - entry.danmakuLastTry < kDanmakuRetryCooldown.inMilliseconds) {
          continue;
        }
        // 一集一集來: 伺服器收到請求是要現生檔的, 一次灌一堆只是讓每一個都更慢
        await _tryDanmakuOnce(entry);
      }
    } finally {
      _retryingDanmaku = false;
    }
  }

  bool _retryingDanmaku = false;

  // --------------------------------------------------------- 線上彈幕快取
  //
  // 沒下載到手機的那些集數, 每次開播放頁都要把整份 .ass 重抓一次 —— 一集
  // 動輒好幾百 KB, 而且伺服器要現生. 這裡照著伺服器那邊的更新週期留六小時,
  // 檔案數有上限, 滿了就先丟最舊的.

  Directory? _danmakuCache;
  static const Duration _danmakuCacheTtl = Duration(hours: 6);
  static const int _danmakuCacheMax = 60;

  File? _danmakuCacheFile(String sn) {
    final dir = _danmakuCache;
    if (dir == null) return null;
    return File('${dir.path}/$sn.ass');
  }

  Future<String?> readCachedDanmaku(String sn) async {
    final file = _danmakuCacheFile(sn);
    if (file == null || !file.existsSync()) return null;
    try {
      final age = DateTime.now().difference(await file.lastModified());
      if (age > _danmakuCacheTtl) return null;
      final text = await file.readAsString();
      return looksLikeAss(text) ? text : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> writeCachedDanmaku(String sn, String ass) async {
    final file = _danmakuCacheFile(sn);
    if (file == null || !looksLikeAss(ass)) return;
    try {
      final dir = _danmakuCache!;
      if (!await dir.exists()) await dir.create(recursive: true);
      await file.writeAsString(ass);
      await _trimDanmakuCache(dir);
    } catch (_) {
      // 存不下就算了, 下次重抓而已
    }
  }

  Future<void> _trimDanmakuCache(Directory dir) async {
    final files = <File>[];
    await for (final item in dir.list()) {
      if (item is File) files.add(item);
    }
    if (files.length <= _danmakuCacheMax) return;
    final stamped = <MapEntry<File, DateTime>>[];
    for (final file in files) {
      try {
        stamped.add(MapEntry(file, await file.lastModified()));
      } catch (_) {
        // 量不到就當它最舊, 優先丟掉
        stamped.add(MapEntry(file, DateTime.fromMillisecondsSinceEpoch(0)));
      }
    }
    stamped.sort((a, b) => a.value.compareTo(b.value));
    for (final entry in stamped.take(stamped.length - _danmakuCacheMax)) {
      try {
        await entry.key.delete();
      } catch (_) {
        // 刪不掉下次再說
      }
    }
  }

  /// 播放頁從網路抓到彈幕時順手存一份: 這一集已經下載好的話, 下次沒網路
  /// 也有彈幕. 修好之前下載的那些集數靠的就是這裡.
  ///
  /// 不要求 playable —— 邊看邊下載那條路是「一邊抓一邊看」, 播放頁這時候拿到的
  /// 彈幕正好可以先擺著, 等影片抓完就是一組完整的離線檔.
  Future<void> cacheDanmaku(String sn, String ass) async {
    final entry = _entries[sn];
    if (entry == null || !entry.wantDanmaku) return;
    if (!looksLikeAss(ass) || entry.hasDanmaku) return;
    try {
      await danmakuFile(sn).writeAsString(ass);
    } catch (_) {
      return;
    }
    entry.hasDanmaku = true;
    await _save();
    notifyListeners();
  }

  /// 離線首頁用: 下載好的集數也是「片庫」
  List<VideoItem> asVideoItems() => finished
      .map((e) => VideoItem(
            sn: e.sn,
            title: e.title,
            animeName: e.animeName,
            episode: e.episode,
            resolution: e.resolution,
            timestamp: e.addedAt ~/ 1000,
            danmu: e.hasDanmaku,
          ))
      .toList();
}

class _Job {
  _Job(this.entry);

  final DownloadEntry entry;
  final http.Client client = http.Client();
  bool cancelled = false;

  /// _run() 整條跑完 (含 flush / close / 改名) 才會 complete.
  ///
  /// cancel() 只是叫它停, 停不是立刻的: 跳出 `await for` 之後還有好幾個
  /// await. 在那段時間裡這個 sn 還是它的 —— 想接手的人要等這個.
  final Completer<void> done = Completer<void>();

  /// 原生傳輸的話, 叫停要去原生那邊停 (見 _runNative)
  Future<void> Function()? onCancel;

  void cancel() {
    cancelled = true;
    try {
      client.close();
    } catch (_) {
      // 已經關掉了
    }
    final hook = onCancel;
    if (hook != null) unawaited(hook());
  }

  void finish() {
    if (!done.isCompleted) done.complete();
  }
}
