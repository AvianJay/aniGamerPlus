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

enum DownloadStatus { queued, running, paused, done, failed }

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
    entry.hasDanmaku = entry.hasDanmaku || (withDanmaku && video.danmu);
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

    // 彈幕跟封面是配菜, 抓不到不該讓整集算失敗
    try {
      final ass = await _client.danmakuAss(entry.sn);
      if (ass.trim().isNotEmpty) {
        await danmakuFile(entry.sn).writeAsString(ass);
        entry.hasDanmaku = true;
      }
    } catch (_) {
      entry.hasDanmaku = entry.hasDanmaku && danmakuFile(entry.sn).existsSync();
    }

    try {
      final response = await http.get(
        _client.thumbnailUrl(entry.sn),
        headers: _client.authHeaders,
      );
      if (response.statusCode == 200 && response.bodyBytes.isNotEmpty) {
        await thumbFile(entry.sn).writeAsBytes(response.bodyBytes);
        entry.hasThumb = true;
      }
    } catch (_) {
      entry.hasThumb = thumbFile(entry.sn).existsSync();
    }

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
