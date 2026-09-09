/// 影片的本機快取 —— 一台只聽 127.0.0.1 的小 HTTP 伺服器.
///
/// 為什麼要繞這一圈: video_player 底下是 ExoPlayer / AVPlayer, 它們自己去抓
/// http 位址, 中間沒有任何地方讓我們插手. 於是有兩件事做不到 ——
///
///  1. 快取. 播放器每次 initialize() 都要重新把檔頭要一遍. 巴哈那邊下下來的
///     mp4 moov 在檔尾 (faststart 是這個 fork 才改成預設開的), 所以「檔頭」
///     實際上是檔案開頭 + 檔案結尾兩塊, 加起來三四 MB. app 關掉再開, 這三四
///     MB 就要重來一次 —— 那就是從觀看紀錄點進去空等的前半段.
///  2. 現在到底下載多快. 播放器不會說, 而緩衝進度換算出來的是估計值.
///
/// 把播放位址換成 `http://127.0.0.1:<port>/...` 之後兩件事都成立: 檔頭落在磁碟
/// 上, app 重開照樣算數; 而每一個 byte 都是我們自己轉手的, 速度是真的量出來的.
///
/// 只快取頭尾兩塊, 不是整支影片 —— 整支要離線看的話, 這個 app 本來就有「下載
/// 到手機」。這裡要解決的只有「開播前那一段」。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// 檔案開頭留多少. ftyp 加上前面幾個 box 而已, 不必留大.
const int kCacheHeadBytes = 512 * 1024;

/// 檔案結尾留多少. moov 在檔尾時播放器會來要這一段, 一集 24 分鐘的 1080p
/// 大約 1 MB.
const int kCacheTailBytes = 2 * 1024 * 1024;

/// 整個快取目錄的上限. 一集頭尾加起來 2.5 MB, 這個額度放得下一百多集.
const int kCacheBudgetBytes = 320 * 1024 * 1024;

/// 速度是拿這段時間內轉手的量算的
const Duration kSpeedWindow = Duration(milliseconds: 2500);

/// 補齊快取之前, 要先看到播放這條路安靜多久.
///
/// 這是整個快取最重要的一條規矩: 補快取是為了「下次開快一點」, 不能拿現在
/// 正在看的那一集的頻寬去換. 線路慢的時候, 一邊補 quota 一邊要播放器在
/// 14:00 那裡緩衝, 結果就是兩邊都卡住 —— 補快取永遠讓路.
const Duration kPrimeIdleGap = Duration(seconds: 4);

/// 等不到空檔就放棄這一輪, 下次開這一集再說
const Duration kPrimeGiveUp = Duration(minutes: 3);

/// 被打斷的話重排幾次
const int kPrimeAttempts = 4;

class _Target {
  _Target({required this.upstream, required this.headers, required this.key});

  final Uri upstream;
  final Map<String, String> headers;
  final String key;
}

class _Meta {
  _Meta({required this.total, this.etag = '', this.modified = ''});

  final int total;
  final String etag;
  final String modified;

  Map<String, dynamic> toJson() =>
      {'total': total, 'etag': etag, 'modified': modified};

  factory _Meta.fromJson(Map<String, dynamic> json) => _Meta(
        total: int.tryParse('${json['total']}') ?? 0,
        etag: (json['etag'] ?? '').toString(),
        modified: (json['modified'] ?? '').toString(),
      );

  /// 伺服器上的檔案換過了嗎. 兩個驗證標頭有一個對得上就當作沒換.
  bool matches(_Meta other) {
    if (total != other.total) return false;
    if (etag.isNotEmpty && other.etag.isNotEmpty) return etag == other.etag;
    if (modified.isNotEmpty && other.modified.isNotEmpty) {
      return modified == other.modified;
    }
    return true;
  }
}

/// 一段要送出去的位元組: 不是從磁碟讀, 就是跟伺服器要.
class _Segment {
  _Segment.cache(this.file, this.offset, this.length)
      : upstreamStart = -1,
        upstreamEnd = -1;

  _Segment.upstream(this.upstreamStart, this.upstreamEnd)
      : file = null,
        offset = 0,
        length = 0;

  final File? file;
  final int offset;
  final int length;
  final int upstreamStart;
  final int upstreamEnd;

  bool get cached => file != null;
  int get size => cached ? length : upstreamEnd - upstreamStart + 1;
}

class VideoCacheServer {
  VideoCacheServer._(this._server, this._dir);

  final HttpServer _server;
  final Directory _dir;
  final http.Client _http = http.Client();
  final Map<String, _Target> _targets = {};
  final Map<String, Future<void>> _priming = {};
  final List<List<int>> _samples = <List<int>>[];

  int _token = 0;
  bool _closed = false;

  /// 起一台. 起不來 (權限、沒有 loopback) 就回 null, 呼叫端退回直連.
  static Future<VideoCacheServer?> start(Directory dir) async {
    try {
      if (!await dir.exists()) await dir.create(recursive: true);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final cache = VideoCacheServer._(server, dir);
      server.listen(cache._handle, onError: (Object _) {});
      unawaited(cache._evict());
      return cache;
    } catch (_) {
      return null;
    }
  }

  int get port => _server.port;

  /// 現在跟伺服器之間的實際速度 (bytes/秒). 從磁碟讀的不算 —— 那不是流量.
  double get bytesPerSecond {
    final now = DateTime.now().millisecondsSinceEpoch;
    _prune(now);
    if (_samples.isEmpty) return 0;
    var total = 0;
    for (final sample in _samples) {
      total += sample[1];
    }
    return total * 1000 / kSpeedWindow.inMilliseconds;
  }

  void _prune(int now) {
    final cutoff = now - kSpeedWindow.inMilliseconds;
    _samples.removeWhere((sample) => sample[0] < cutoff);
  }

  void _note(int bytes) {
    if (bytes <= 0) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    _samples.add(<int>[now, bytes]);
    _prune(now);
  }

  /// 把一個伺服器上的位址換成本機的. key 要能代表「哪一集的哪一份」——
  /// 換了畫質就是另一份, 不能共用同一塊快取.
  Uri wrap({
    required Uri upstream,
    required Map<String, String> headers,
    required String key,
  }) {
    if (_closed) return upstream;
    final token = (++_token).toString();
    _targets[token] = _Target(
        upstream: upstream, headers: headers, key: _sanitize(key));
    // 刻意不在這裡開始補快取: 這一刻播放器正要去要它開播需要的東西, 跟它搶
    // 頻寬只會讓開播更慢. _prime() 自己會等到播放那條路安靜下來再動.
    unawaited(_prime(token));
    return Uri.parse('http://127.0.0.1:${_server.port}/v/$token');
  }

  static String _sanitize(String key) =>
      key.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_');

  File _headFile(String key) => File('${_dir.path}/$key.head');
  File _tailFile(String key) => File('${_dir.path}/$key.tail');
  File _metaFile(String key) => File('${_dir.path}/$key.json');

  // ------------------------------------------------------------------ 中繼資料

  Future<_Meta?> _readMeta(String key) async {
    final file = _metaFile(key);
    if (!file.existsSync()) return null;
    try {
      final raw = jsonDecode(await file.readAsString());
      if (raw is! Map) return null;
      final meta = _Meta.fromJson(raw.cast<String, dynamic>());
      return meta.total > 0 ? meta : null;
    } catch (_) {
      return null;
    }
  }

  /// 跟伺服器要一個 byte, 從 Content-Range 把總長度撈出來.
  ///
  /// 不用 HEAD: 這條路由後面接的是 send_file, HEAD 不保證帶得回 Content-Range,
  /// 而 1 byte 的 Range 一定會.
  Future<_Meta?> _fetchMeta(_Target target) async {
    try {
      final response = await _http.get(target.upstream,
          headers: {...target.headers, 'Range': 'bytes=0-0'});
      if (response.statusCode >= 400) return null;
      final range = response.headers['content-range'] ?? '';
      final total = int.tryParse(range.split('/').last.trim()) ?? 0;
      if (total <= 0) return null;
      return _Meta(
        total: total,
        etag: response.headers['etag'] ?? '',
        modified: response.headers['last-modified'] ?? '',
      );
    } catch (_) {
      return null;
    }
  }

  /// 磁碟上那份還算數嗎. 不算數就把它清掉, 回傳新的中繼資料.
  Future<_Meta?> _validate(_Target target) async {
    final live = await _fetchMeta(target);
    if (live == null) return null;
    final saved = await _readMeta(target.key);
    if (saved != null && saved.matches(live)) return saved;
    await _forget(target.key);
    try {
      await _metaFile(target.key).writeAsString(jsonEncode(live.toJson()));
    } catch (_) {
      return null;
    }
    return live;
  }

  Future<void> _forget(String key) async {
    for (final file in [_headFile(key), _tailFile(key)]) {
      try {
        if (file.existsSync()) await file.delete();
      } catch (_) {
        // 刪不掉就讓它留著, 下面的長度檢查會判它不完整
      }
    }
  }

  // -------------------------------------------------------------------- 補齊

  Future<void> _prime(String token) {
    final target = _targets[token];
    if (target == null) return Future<void>.value();
    final existing = _priming[target.key];
    if (existing != null) return existing;
    final work = _primeNow(target).whenComplete(() {
      _priming.remove(target.key);
    });
    _priming[target.key] = work;
    return work;
  }

  Future<void> _primeNow(_Target target) async {
    final meta = await _validate(target);
    if (meta == null || _closed) return;
    final head = _headSpan(meta);
    final tail = _tailSpan(meta);

    // 補到一半被播放器打斷的那一塊要再排一次. 不重試的話, 只要使用者一直在
    // 動 (拉進度條、換集), 檔頭就永遠補不齊 —— 那正是最需要它的情況.
    for (var attempt = 0; attempt < kPrimeAttempts; attempt++) {
      if (_closed) return;
      final headMissing = !_complete(_headFile(target.key), head);
      final tailMissing = tail > 0 && !_complete(_tailFile(target.key), tail);
      if (!headMissing && !tailMissing) break;
      if (!await _waitForQuiet()) return;

      // 尾巴先補: moov 在那裡, 那一塊才是開播前真正在等的東西
      if (tailMissing) {
        await _download(
            target, _tailFile(target.key), meta.total - tail, meta.total - 1);
      }
      if (headMissing && _quiet) {
        await _download(target, _headFile(target.key), 0, head - 1);
      }
    }
    unawaited(_evict());
  }

  /// 播放那條路最後一次搬東西是什麼時候
  int _playbackAt = 0;

  void _notePlayback() =>
      _playbackAt = DateTime.now().millisecondsSinceEpoch;

  bool get _quiet =>
      DateTime.now().millisecondsSinceEpoch - _playbackAt >
      kPrimeIdleGap.inMilliseconds;

  /// 等到播放器不再要東西為止. 等太久就放棄 —— 一直在看的人不需要我們現在
  /// 就把快取補好.
  Future<bool> _waitForQuiet() async {
    final deadline = DateTime.now().add(kPrimeGiveUp);
    while (!_closed && DateTime.now().isBefore(deadline)) {
      if (_quiet) return true;
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    return false;
  }

  int _headSpan(_Meta meta) =>
      meta.total < kCacheHeadBytes ? meta.total : kCacheHeadBytes;

  /// 頭尾不重疊. 小到頭就已經蓋掉整支的話, 尾巴那塊就不要了.
  int _tailSpan(_Meta meta) {
    final remaining = meta.total - _headSpan(meta);
    if (remaining <= 0) return 0;
    return remaining < kCacheTailBytes ? remaining : kCacheTailBytes;
  }

  bool _complete(File file, int expected) {
    if (expected <= 0) return false;
    try {
      return file.existsSync() && file.lengthSync() == expected;
    } catch (_) {
      return false;
    }
  }

  /// 抓一段存成一個檔. 先寫 .part 再改名 —— 中途被砍掉的話, 留在磁碟上的
  /// 不會是一份長度對不上的半成品.
  Future<void> _download(_Target target, File file, int start, int end) async {
    final part = File('${file.path}.part');
    try {
      final request = http.Request('GET', target.upstream)
        ..headers.addAll({...target.headers, 'Range': 'bytes=$start-$end'});
      final response = await _http.send(request);
      if (response.statusCode >= 400) return;
      final sink = part.openWrite();
      var abandoned = false;
      try {
        await for (final chunk in response.stream) {
          if (_closed) break;
          // 播放器中途又開始要東西: 立刻把頻寬讓回去, 這一份下次再補
          if (!_quiet) {
            abandoned = true;
            break;
          }
          _note(chunk.length);
          sink.add(chunk);
        }
      } finally {
        await sink.close();
      }
      if (!abandoned && await part.length() == end - start + 1) {
        await part.rename(file.path);
      } else {
        await part.delete();
      }
    } catch (_) {
      try {
        if (part.existsSync()) await part.delete();
      } catch (_) {
        // 清不掉就算了, 下次會被覆蓋
      }
    }
  }

  // ------------------------------------------------------------------ 請求

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    try {
      final token = request.uri.pathSegments.length > 1
          ? request.uri.pathSegments[1]
          : '';
      final target = _targets[token];
      if (target == null) {
        response.statusCode = HttpStatus.notFound;
        await response.close();
        return;
      }
      if (request.method == 'HEAD') {
        // 播放器偶爾會先問一下. 有中繼資料就答, 沒有就讓它改用 Range
        final meta = await _readMeta(target.key);
        response.statusCode = HttpStatus.ok;
        response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
        response.headers.set(HttpHeaders.contentTypeHeader, 'video/mp4');
        if (meta != null) response.contentLength = meta.total;
        await response.close();
        return;
      }

      final meta = await _readMeta(target.key) ?? await _validate(target);
      if (meta == null) {
        // 問不到長度就純轉手, 至少不要因為快取壞掉就播不了
        await _passThrough(target, request, response);
        return;
      }

      final span = _parseRange(request.headers.value(HttpHeaders.rangeHeader),
          meta.total);
      final start = span[0];
      final end = span[1];
      if (start > end || start >= meta.total) {
        response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        await response.close();
        return;
      }

      final partial = request.headers.value(HttpHeaders.rangeHeader) != null;
      response.statusCode =
          partial ? HttpStatus.partialContent : HttpStatus.ok;
      response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      response.headers.set(HttpHeaders.contentTypeHeader, 'video/mp4');
      if (partial) {
        response.headers
            .set(HttpHeaders.contentRangeHeader, 'bytes $start-$end/${meta.total}');
      }
      response.contentLength = end - start + 1;

      for (final segment in _plan(target.key, meta, start, end)) {
        if (_closed) break;
        if (segment.cached) {
          _notePlayback();
          await response.addStream(segment.file!
              .openRead(segment.offset, segment.offset + segment.length));
        } else {
          final sent = await _stream(
              target, response, segment.upstreamStart, segment.upstreamEnd);
          if (!sent) break;
        }
      }
      await response.close();
    } catch (_) {
      // 播放器中途放棄 (拉進度條、換一集) 時最常見: 對面已經不在了, 寫回去
      // 會丟例外. 這不是錯誤, 收乾淨就好.
      try {
        await response.close();
      } catch (_) {
        // 已經斷了
      }
    }
  }

  /// 一個 Range 要怎麼湊出來: 落在頭尾快取裡的從磁碟讀, 其餘的跟伺服器要.
  List<_Segment> _plan(String key, _Meta meta, int start, int end) {
    final head = _headSpan(meta);
    final tail = _tailSpan(meta);
    final headFile = _headFile(key);
    final tailFile = _tailFile(key);
    final hasHead = _complete(headFile, head);
    final hasTail = tail > 0 && _complete(tailFile, tail);
    final tailStart = meta.total - tail;

    final segments = <_Segment>[];
    var at = start;
    while (at <= end) {
      if (hasHead && at < head) {
        final stop = end < head - 1 ? end : head - 1;
        segments.add(_Segment.cache(headFile, at, stop - at + 1));
        at = stop + 1;
        continue;
      }
      if (hasTail && at >= tailStart) {
        segments.add(_Segment.cache(tailFile, at - tailStart, end - at + 1));
        at = end + 1;
        continue;
      }
      // 這一段沒有快取: 一路要到下一塊快取的開頭為止
      var stop = end;
      if (hasTail && at < tailStart && end >= tailStart) stop = tailStart - 1;
      if (hasHead && at < head) stop = head - 1 < stop ? head - 1 : stop;
      segments.add(_Segment.upstream(at, stop));
      at = stop + 1;
    }
    return segments;
  }

  static List<int> _parseRange(String? header, int total) {
    if (header == null || !header.startsWith('bytes=')) {
      return <int>[0, total - 1];
    }
    final spec = header.substring(6).split(',').first.trim();
    final dash = spec.indexOf('-');
    if (dash < 0) return <int>[0, total - 1];
    final headText = spec.substring(0, dash).trim();
    final tailText = spec.substring(dash + 1).trim();
    if (headText.isEmpty) {
      // bytes=-N: 最後 N 個 byte
      final want = int.tryParse(tailText) ?? 0;
      if (want <= 0 || want > total) return <int>[0, total - 1];
      return <int>[total - want, total - 1];
    }
    final start = int.tryParse(headText) ?? 0;
    final end = tailText.isEmpty ? total - 1 : (int.tryParse(tailText) ?? total - 1);
    return <int>[start, end > total - 1 ? total - 1 : end];
  }

  /// 跟伺服器要一段, 邊收邊往播放器送.
  Future<bool> _stream(
      _Target target, HttpResponse response, int start, int end) async {
    try {
      final request = http.Request('GET', target.upstream)
        ..headers.addAll({...target.headers, 'Range': 'bytes=$start-$end'});
      final upstream = await _http.send(request);
      if (upstream.statusCode >= 400) return false;
      // 一定要走 addStream: 它會照著 socket 排空的速度去回壓上游那條 stream.
      //
      // 手動 add() 沒有這層回壓 —— 播放器緩衝滿了就不再從 socket 讀, 但我們
      // 還是全速把上游灌進記憶體. 慢線路上那等於「頻寬全部拿去抓沒人要的
      // 資料」, 畫面看起來就是明明有東西卻一直在轉圈. 每一塊都 flush() 也
      // 不對, 那會把讀跟寫串成一條, 吞吐量砍半.
      await response.addStream(upstream.stream.map((chunk) {
        _note(chunk.length);
        _notePlayback();
        return chunk;
      }));
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 完全不管快取, 原樣轉手. 中繼資料拿不到時的退路.
  Future<void> _passThrough(
      _Target target, HttpRequest request, HttpResponse response) async {
    try {
      final headers = {...target.headers};
      final range = request.headers.value(HttpHeaders.rangeHeader);
      if (range != null) headers['Range'] = range;
      final upstream =
          await _http.send(http.Request('GET', target.upstream)..headers.addAll(headers));
      response.statusCode = upstream.statusCode;
      upstream.headers.forEach((name, value) {
        if (name == 'transfer-encoding' || name == 'content-encoding') return;
        response.headers.set(name, value);
      });
      await response.addStream(upstream.stream.map((chunk) {
        _note(chunk.length);
        _notePlayback();
        return chunk;
      }));
      await response.close();
    } catch (_) {
      try {
        await response.close();
      } catch (_) {
        // 對面已經走了
      }
    }
  }

  // -------------------------------------------------------------------- 清掃

  /// 超過額度就從最舊的開始丟. 一集的頭、尾、中繼資料是一組, 要一起丟.
  Future<void> _evict() async {
    try {
      final groups = <String, List<FileSystemEntity>>{};
      final stamps = <String, DateTime>{};
      var total = 0;
      await for (final item in _dir.list()) {
        if (item is! File) continue;
        final name = item.uri.pathSegments.last;
        final dot = name.lastIndexOf('.');
        if (dot <= 0) continue;
        final key = name.substring(0, dot);
        groups.putIfAbsent(key, () => <FileSystemEntity>[]).add(item);
        final stat = await item.stat();
        total += stat.size;
        final seen = stamps[key];
        if (seen == null || stat.modified.isAfter(seen)) {
          stamps[key] = stat.modified;
        }
      }
      if (total <= kCacheBudgetBytes) return;

      final keys = stamps.keys.toList()
        ..sort((a, b) => stamps[a]!.compareTo(stamps[b]!));
      for (final key in keys) {
        if (total <= kCacheBudgetBytes) break;
        for (final file in groups[key] ?? const <FileSystemEntity>[]) {
          try {
            total -= await (file as File).length();
            await file.delete();
          } catch (_) {
            // 正在被讀的檔案刪不掉, 下一輪再說
          }
        }
      }
    } catch (_) {
      // 掃不動就跳過這一輪, 額度下次再收
    }
  }

  Future<void> close() async {
    _closed = true;
    _targets.clear();
    _http.close();
    try {
      await _server.close(force: true);
    } catch (_) {
      // 已經關了
    }
  }
}
