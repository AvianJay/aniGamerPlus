/// 把片庫裡的一集抓到手機上, 離線也能看.
///
/// 這是網頁版沒有的功能, 但它沒有繞過伺服器: 抓的就是 /get_video.mp4 那一支,
/// 用 Range 續傳, 彈幕跟封面一起收在旁邊. 播放時只要本機有檔, 播放器就改讀
/// file://, 完全不碰網路.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../api/client.dart';
import '../api/models.dart';
import 'thumbnail_store.dart';

enum DownloadStatus { queued, running, paused, done, failed }

/// 下載完之後隔多久回頭問一次彈幕. 伺服器是收到請求才開始生 .ass, 生完
/// 之前一律 404, 所以第一次一定撲空 —— 加起來大概等半分鐘.
const List<Duration> kDanmakuRetryWaits = [
  Duration.zero,
  Duration(seconds: 3),
  Duration(seconds: 6),
  Duration(seconds: 10),
  Duration(seconds: 15),
];

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
    );
  }

  /// 這一集是不是可以離線播
  bool get playable => status == DownloadStatus.done;
}

class DownloadStore extends ChangeNotifier {
  DownloadStore(this._client);

  AgpClient _client;
  set client(AgpClient value) => _client = value;

  /// 縮圖下載用的 http.Client. 平時是 null (用完即丟); 測試時可以塞一支假的.
  http.Client? thumbClient;

  Directory? _dir;
  final Map<String, DownloadEntry> _entries = {};
  final Map<String, _Job> _jobs = {};
  int concurrency = 1;
  bool _ready = false;

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
          e.status == DownloadStatus.paused ||
          e.status == DownloadStatus.failed)
      .toList();

  int get runningCount =>
      _entries.values.where((e) => e.status == DownloadStatus.running).length;

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
            // 上一輪是被系統殺掉的, 不會有人幫它把狀態寫回去
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
    _ready = true;
    notifyListeners();
    unawaited(_pump());
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
    final index = File('${directory.path}/index.json');
    await index.writeAsString(
      jsonEncode(_entries.values.map((e) => e.toJson()).toList()),
    );
  }

  // ------------------------------------------------------------------ 佇列

  Future<DownloadEntry> enqueue(
    VideoItem video, {
    bool withDanmaku = true,
  }) async {
    final existing = _entries[video.sn];
    if (existing != null && existing.playable) return existing;

    final entry = existing ??
        DownloadEntry(
          sn: video.sn,
          animeName: video.animeName,
          episode: video.episode,
          title: video.title,
          resolution: video.resolution,
        );
    entry.animeName = video.animeName.isNotEmpty ? video.animeName : entry.animeName;
    entry.episode = video.episode.isNotEmpty ? video.episode : entry.episode;
    entry.title = video.title.isNotEmpty ? video.title : entry.title;
    if (video.resolution > 0) entry.resolution = video.resolution;
    entry.status = DownloadStatus.queued;
    entry.error = '';
    // video.danmu 是「伺服器現在手上有沒有這一集的彈幕」, 拿它當條件的話,
    // 伺服器還沒生檔的集數就永遠不會去抓. 想不想要是使用者決定的, 有沒有
    // 抓到等 _fetchDanmaku 回報.
    entry.wantDanmaku = withDanmaku;
    entry.hasDanmaku = entry.hasDanmaku && danmakuFile(entry.sn).existsSync();
    _entries[entry.sn] = entry;

    await _save();
    notifyListeners();
    unawaited(_pump());
    return entry;
  }

  Future<void> pause(String sn) async {
    final entry = _entries[sn];
    if (entry == null) return;
    _jobs.remove(sn)?.cancel();
    if (entry.status == DownloadStatus.running ||
        entry.status == DownloadStatus.queued) {
      entry.status = DownloadStatus.paused;
    }
    await _save();
    notifyListeners();
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
    _jobs.remove(sn)?.cancel();
    final entry = _entries.remove(sn);
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
    await _save();
    notifyListeners();
    unawaited(_pump());
  }

  Future<void> pauseAll() async {
    for (final entry in _entries.values) {
      if (entry.status == DownloadStatus.running ||
          entry.status == DownloadStatus.queued) {
        _jobs.remove(entry.sn)?.cancel();
        entry.status = DownloadStatus.paused;
      }
    }
    await _save();
    notifyListeners();
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

  Future<void> _pump() async {
    if (_dir == null) return;
    while (runningCount < concurrency) {
      DownloadEntry? next;
      for (final entry in entries.reversed) {
        if (entry.status == DownloadStatus.queued) {
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
    final entry = job.entry;
    final part = partFile(entry);
    final target = videoFile(entry);
    IOSink? sink;

    try {
      var start = 0;
      if (await part.exists()) {
        start = await part.length();
      }

      final request = http.Request('GET', _client.videoUrl(
        entry.sn,
        resolution: entry.resolution > 0 ? entry.resolution : null,
      ));
      request.headers.addAll(_client.authHeaders);
      if (start > 0) request.headers['Range'] = 'bytes=$start-';

      final response = await job.client.send(request);

      if (response.statusCode == 416) {
        // 已經抓完了, 只是上次沒改名
        await part.rename(target.path);
        await _finish(job, entry);
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
        if (entry.status == DownloadStatus.running) {
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
      _jobs.remove(entry.sn);
      unawaited(_pump());
    }
  }

  Future<void> _finish(_Job job, DownloadEntry entry) async {
    entry.status = DownloadStatus.done;
    entry.error = '';
    notifyListeners();

    // 封面是配菜, 抓不到不該讓整集算失敗. 直接跟巴哈要, 不走伺服器的
    // /thumbnail.jpg —— 那條代理一出問題, 離線頁整面會沒圖.
    try {
      final bytes =
          await fetchBahamutThumbnailBytes(entry.sn, client: thumbClient);
      if (bytes != null && bytes.isNotEmpty) {
        await thumbFile(entry.sn).writeAsBytes(bytes);
        entry.hasThumb = true;
      }
    } catch (_) {
      entry.hasThumb = thumbFile(entry.sn).existsSync();
    }

    await _save();
    notifyListeners();

    // 彈幕另外跑, 不佔佇列: 見 _fetchDanmaku, 最久要等半分鐘
    if (entry.wantDanmaku) unawaited(_fetchDanmaku(entry));
  }

  /// 伺服器的 /get_danmu.ass 是被問到才去生檔的 —— 檔案還沒生出來之前它
  /// 直接回 404, 同時在背景開一條 thread 去抓. 問一次就放棄的話, 剛下載完
  /// 的那一集離線永遠沒有彈幕, 所以這裡多問幾輪等它生完.
  Future<void> _fetchDanmaku(DownloadEntry entry) async {
    for (final wait in kDanmakuRetryWaits) {
      if (wait > Duration.zero) await Future<void>.delayed(wait);
      // 等待途中被刪掉了就別再寫檔
      if (!_entries.containsKey(entry.sn)) return;
      try {
        final ass = await _client.danmakuAss(entry.sn);
        if (ass.trim().isNotEmpty) {
          await danmakuFile(entry.sn).writeAsString(ass);
          entry.hasDanmaku = true;
          await _save();
          notifyListeners();
          return;
        }
      } catch (_) {
        // 網路斷了就算了, 彈幕是配菜
      }
    }
    if (entry.hasDanmaku && !danmakuFile(entry.sn).existsSync()) {
      entry.hasDanmaku = false;
      await _save();
      notifyListeners();
    }
  }

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
      return text.trim().isEmpty ? null : text;
    } catch (_) {
      return null;
    }
  }

  Future<void> writeCachedDanmaku(String sn, String ass) async {
    final file = _danmakuCacheFile(sn);
    if (file == null || ass.trim().isEmpty) return;
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
  Future<void> cacheDanmaku(String sn, String ass) async {
    final entry = _entries[sn];
    if (entry == null || !entry.playable || !entry.wantDanmaku) return;
    if (ass.trim().isEmpty || entry.hasDanmaku) return;
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

  void cancel() {
    cancelled = true;
    try {
      client.close();
    } catch (_) {
      // 已經關掉了
    }
  }
}
