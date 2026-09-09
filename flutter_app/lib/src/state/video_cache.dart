/// 影片的本機快取 —— 一台只聽 127.0.0.1 的小 HTTP 伺服器.
///
/// 為什麼要繞這一圈: video_player 底下是 ExoPlayer / AVPlayer, 它們自己去抓
/// http 位址, 中間沒有任何地方讓我們插手. 於是有兩件事做不到 ——
///
///  1. 快取. 播放器緩衝起來的東西全在記憶體裡, app 一關就沒了. 看到一半退出
///     再回來, 剛剛已經載好的那一段要整個重抓.
///  2. 現在到底下載多快. 播放器不會說, 而緩衝進度換算出來的是估計值.
///
/// 作法: 經過這裡的每一個 byte 都順手落盤, 之後同一段再被要就直接從磁碟發.
/// 「已經載過的就不要再載一次」在這裡是字面上的意思 —— 不分檔頭還是影片內容,
/// 看過的段落 app 重開之後照樣算數.
///
/// 刻意不做預抓. 快取只從「播放器本來就要的東西」順手撿, 所以永遠不會跟正在
/// 看的那一集搶頻寬 —— 慢線路上那是最要命的事.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

/// 一塊多大. 小塊比較省 (跳轉時對齊浪費的少), 但一集會生出很多檔案;
/// 1 MB 的話 428 MB 的一集全看完大約 428 塊.
const int kCacheBlockBytes = 1024 * 1024;

/// 整個快取目錄的上限. 滿了就整集整集地丟, 最久沒碰的先走.
const int kCacheBudgetBytes = 1536 * 1024 * 1024;

/// 速度是拿這段時間內轉手的量算的
const Duration kSpeedWindow = Duration(milliseconds: 2500);

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

class VideoCacheServer {
  VideoCacheServer._(this._server, this._dir);

  final HttpServer _server;
  final Directory _dir;
  final http.Client _http = http.Client();
  final Map<String, _Target> _targets = {};
  final Map<String, Future<_Meta?>> _metaWork = {};
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

  bool get closed => _closed;

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
    final target =
        _Target(upstream: upstream, headers: headers, key: _sanitize(key));
    _targets[token] = target;
    // 開一集就跟伺服器對一次長度/驗證標頭: 檔案換過的話手上那堆塊就不算數了.
    // 只有一個 byte, 但它必須在發任何一塊快取出去之前做完.
    _metaWork[target.key] = _resolveMeta(target);
    return Uri.parse('http://127.0.0.1:${_server.port}/v/$token');
  }

  static String _sanitize(String key) =>
      key.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_');

  Directory _episodeDir(String key) => Directory('${_dir.path}/$key');
  File _metaFile(String key) => File('${_dir.path}/$key/meta.json');
  File _blockFile(String key, int index) => File('${_dir.path}/$key/$index.blk');

  int _blockOf(int offset) => offset ~/ kCacheBlockBytes;
  int _blockStart(int index) => index * kCacheBlockBytes;

  /// 這一塊該有多長 (最後一塊通常不滿)
  int _blockLength(int index, _Meta meta) =>
      math.min(kCacheBlockBytes, meta.total - _blockStart(index));

  /// 這一塊從塊開頭算起存了幾個 byte.
  ///
  /// 不是「有沒有」而是「到哪裡」: 播放器開一集時只會把檔頭讀個兩三百 KB 就
  /// 跑去拿 moov, 那一塊永遠湊不滿. 只認滿塊的話, 最常走的那條路就永遠快取
  /// 不到 —— 半塊也是有用的, 前綴照樣發得出去.
  int _blockCovered(String key, int index) {
    try {
      final file = _blockFile(key, index);
      return file.existsSync() ? file.lengthSync() : 0;
    } catch (_) {
      return 0;
    }
  }

  bool _hasFullBlock(String key, int index, _Meta meta) {
    if (_blockStart(index) >= meta.total) return false;
    return _blockCovered(key, index) == _blockLength(index, meta);
  }

  /// 從 [at] 開始, 磁碟上連續有幾個 byte 可以直接發 (最多到 [limit])
  int _cachedRun(String key, int at, int limit, _Meta meta) {
    var run = 0;
    var pos = at;
    while (pos <= limit) {
      final index = _blockOf(pos);
      final covered = _blockCovered(key, index);
      if (covered <= 0) break;
      final lastCached = _blockStart(index) + covered - 1;
      if (pos > lastCached) break;
      final take = math.min(limit, lastCached) - pos + 1;
      run += take;
      pos += take;
      // 這一塊沒存滿, 後面就一定接不下去了
      if (covered < _blockLength(index, meta)) break;
    }
    return run;
  }

  // ---------------------------------------------------------------- 中繼資料

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

  /// 磁碟上那堆塊還算數嗎. 不算數就整集丟掉.
  Future<_Meta?> _resolveMeta(_Target target) async {
    final saved = await _readMeta(target.key);
    final live = await _fetchMeta(target);
    if (live == null) {
      // 連不上就先用手上那份 —— 離線時已經快取的段落還是該播得出來
      return saved;
    }
    if (saved != null && saved.matches(live)) {
      unawaited(_touch(target.key));
      return saved;
    }
    await _forget(target.key);
    try {
      await _episodeDir(target.key).create(recursive: true);
      await _metaFile(target.key).writeAsString(jsonEncode(live.toJson()));
    } catch (_) {
      return null;
    }
    return live;
  }

  Future<_Meta?> _metaFor(_Target target) =>
      _metaWork[target.key] ??= _resolveMeta(target);

  Future<void> _forget(String key) async {
    try {
      final dir = _episodeDir(key);
      if (dir.existsSync()) await dir.delete(recursive: true);
    } catch (_) {
      // 刪不掉的話下面的長度檢查會把那些塊判成不完整
    }
  }

  /// 標記「這一集剛剛被用到」, 給 LRU 淘汰看的
  Future<void> _touch(String key) async {
    try {
      final file = _metaFile(key);
      if (file.existsSync()) await file.setLastModified(DateTime.now());
    } catch (_) {
      // 標不到就算了, 最壞是淘汰順序不準
    }
  }

  // -------------------------------------------------------------------- 請求

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    try {
      final token =
          request.uri.pathSegments.length > 1 ? request.uri.pathSegments[1] : '';
      final target = _targets[token];
      if (target == null) {
        response.statusCode = HttpStatus.notFound;
        await response.close();
        return;
      }

      final meta = await _metaFor(target);
      if (meta == null) {
        // 問不到長度就純轉手, 至少不要因為快取壞掉就播不了
        await _passThrough(target, request, response);
        return;
      }

      if (request.method == 'HEAD') {
        response.statusCode = HttpStatus.ok;
        response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
        response.headers.set(HttpHeaders.contentTypeHeader, 'video/mp4');
        response.contentLength = meta.total;
        await response.close();
        return;
      }

      final header = request.headers.value(HttpHeaders.rangeHeader);
      final span = _parseRange(header, meta.total);
      final start = span[0];
      final end = span[1];
      if (start > end || start >= meta.total) {
        response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        await response.close();
        return;
      }

      response.statusCode =
          header != null ? HttpStatus.partialContent : HttpStatus.ok;
      response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      response.headers.set(HttpHeaders.contentTypeHeader, 'video/mp4');
      if (header != null) {
        response.headers.set(
            HttpHeaders.contentRangeHeader, 'bytes $start-$end/${meta.total}');
      }
      response.contentLength = end - start + 1;

      await _serve(target, meta, response, start, end);
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

  /// 一個 Range 怎麼湊出來: 磁碟上有的直接發, 沒有的跟伺服器要 (順手存起來).
  Future<void> _serve(_Target target, _Meta meta, HttpResponse response,
      int start, int end) async {
    var at = start;
    while (at <= end && !_closed) {
      final run = _cachedRun(target.key, at, end, meta);
      if (run > 0) {
        await _sendCached(target, meta, response, at, at + run - 1);
        at += run;
        continue;
      }

      // 這裡沒有: 一路要到下一塊「完整的」為止. 半塊的也一起重要一次 ——
      // 反正接下去那段本來就得抓, 順手把它補成整塊.
      var stopIndex = _blockOf(at);
      while (_blockStart(stopIndex + 1) <= end &&
          !_hasFullBlock(target.key, stopIndex + 1, meta)) {
        stopIndex++;
      }
      final stop = math.min(
          end, _blockStart(stopIndex) + _blockLength(stopIndex, meta) - 1);
      final sent = await _fetchAndStore(target, meta, response, at, stop);
      if (!sent) return;
      at = stop + 1;
    }
  }

  /// 把 [from]..[to] 從磁碟上那幾塊讀出來發掉
  Future<void> _sendCached(_Target target, _Meta meta, HttpResponse response,
      int from, int to) async {
    var at = from;
    while (at <= to) {
      final index = _blockOf(at);
      final covered = _blockCovered(target.key, index);
      if (covered <= 0) return;
      final lastCached = _blockStart(index) + covered - 1;
      final stop = math.min(to, lastCached);
      await response.addStream(_blockFile(target.key, index)
          .openRead(at - _blockStart(index), stop - _blockStart(index) + 1));
      at = stop + 1;
    }
  }

  /// 跟伺服器要 [start]..[stop], 邊送給播放器邊把完整的塊寫到磁碟.
  ///
  /// 起點會往前對齊到塊的開頭 (最多多要 1 MB). 不對齊的話, 跳轉之後那一塊
  /// 永遠只拿得到半塊, 也就永遠存不起來 —— moov 在檔尾又不對齊, 正是會一直
  /// 踩到這件事的地方.
  Future<bool> _fetchAndStore(_Target target, _Meta meta,
      HttpResponse response, int start, int stop) async {
    final aligned = _blockStart(_blockOf(start));
    IOSink? sink;
    var sinkBlock = -1;
    var pos = aligned;

    Future<void> settle({required bool keep}) async {
      final open = sink;
      if (open == null) return;
      sink = null;
      final block = sinkBlock;
      var ok = keep;
      try {
        await open.close();
      } catch (_) {
        ok = false;
      }
      final part = File('${_blockFile(target.key, block).path}.part');
      try {
        if (ok && part.existsSync()) {
          final grown = await part.length();
          // 半塊也留著 —— 但只有在比手上那份更長的時候才換, 不然中途被掐斷
          // 的一小段會把已經存好的整塊蓋掉
          if (grown > 0 && grown > _blockCovered(target.key, block)) {
            await part.rename(_blockFile(target.key, block).path);
          } else {
            await part.delete();
          }
        } else if (part.existsSync()) {
          await part.delete();
        }
      } catch (_) {
        // 收不乾淨就算了, 下次會被覆蓋
      }
    }

    try {
      await _episodeDir(target.key).create(recursive: true);
    } catch (_) {
      // 建不出目錄就只是存不了, 照樣要能播
    }

    try {
      final request = http.Request('GET', target.upstream)
        ..headers.addAll({...target.headers, 'Range': 'bytes=$aligned-$stop'});
      final upstream = await _http.send(request);
      if (upstream.statusCode >= 400) return false;

      // 一定要走 addStream: 它會照著 socket 排空的速度回壓上游那條 stream.
      // 手動 add() 沒有這層回壓 —— 播放器緩衝滿了就不再從 socket 讀, 但我們
      // 還是全速把上游灌進記憶體. 慢線路上那等於「頻寬全部拿去抓沒人要的
      // 資料」, 畫面看起來就是明明有東西卻一直在轉圈.
      await response.addStream(upstream.stream.asyncExpand((chunk) async* {
        _note(chunk.length);
        final chunkStart = pos;

        var offset = 0;
        while (offset < chunk.length) {
          final block = _blockOf(pos);
          if (block != sinkBlock) {
            await settle(keep: true);
            sinkBlock = block;
            try {
              sink =
                  File('${_blockFile(target.key, block).path}.part').openWrite();
            } catch (_) {
              sink = null;
            }
          }
          final blockEnd = _blockStart(block) + _blockLength(block, meta);
          final take = math.min(chunk.length - offset, blockEnd - pos);
          sink?.add(chunk.sublist(offset, offset + take));
          offset += take;
          pos += take;
          // 一塞滿就馬上收尾, 不要等下一塊或整條 stream 結束. 這樣「播放器
          // 收到這一塊的最後一個 byte」時, 那一塊在磁碟上已經是完成品 ——
          // 中途被掐斷也不會白抓一塊.
          if (pos == blockEnd) await settle(keep: true);

        }

        // 往前對齊多要的那一小段是拿來補快取的, 不能發給播放器
        if (pos <= start) return;
        yield chunkStart >= start
            ? chunk
            : chunk.sublist(start - chunkStart);
      }));
      await settle(keep: true);
      unawaited(_evict());
      return true;
    } catch (_) {
      await settle(keep: true);
      return false;
    }
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
    final end =
        tailText.isEmpty ? total - 1 : (int.tryParse(tailText) ?? total - 1);
    return <int>[start, end > total - 1 ? total - 1 : end];
  }

  /// 完全不管快取, 原樣轉手. 中繼資料拿不到時的退路.
  Future<void> _passThrough(
      _Target target, HttpRequest request, HttpResponse response) async {
    try {
      final headers = {...target.headers};
      final range = request.headers.value(HttpHeaders.rangeHeader);
      if (range != null) headers['Range'] = range;
      final upstream = await _http
          .send(http.Request('GET', target.upstream)..headers.addAll(headers));
      response.statusCode = upstream.statusCode;
      upstream.headers.forEach((name, value) {
        if (name == 'transfer-encoding' || name == 'content-encoding') return;
        response.headers.set(name, value);
      });
      await response.addStream(upstream.stream.map((chunk) {
        _note(chunk.length);
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

  // ------------------------------------------------------------------ 清掃

  /// 超過額度就整集整集地丟, 最久沒碰的先走. 丟半集沒有意義 —— 那只會留下
  /// 一堆補不齊的洞.
  Future<void> _evict() async {
    if (_closed) return;
    try {
      final sizes = <String, int>{};
      final seen = <String, DateTime>{};
      var total = 0;
      await for (final item in _dir.list()) {
        // close() 之後就別再碰磁碟了: 掃描開著的時候目錄被刪掉 (測試收尾、
        // 使用者清快取) 會讓刪除那一邊拿到奇怪的錯
        if (_closed) return;
        if (item is! Directory) continue;
        final key =
            item.uri.pathSegments.where((part) => part.isNotEmpty).last;
        var size = 0;
        await for (final file in item.list()) {
          if (_closed) return;
          if (file is! File) continue;
          size += (await file.stat()).size;
        }
        sizes[key] = size;
        total += size;
        try {
          seen[key] = (await _metaFile(key).stat()).modified;
        } catch (_) {
          seen[key] = DateTime.fromMillisecondsSinceEpoch(0);
        }
      }
      if (total <= kCacheBudgetBytes) return;

      final order = sizes.keys.toList()
        ..sort((a, b) => seen[a]!.compareTo(seen[b]!));
      for (final key in order) {
        if (total <= kCacheBudgetBytes) break;
        // 正在播的那一集不能丟
        if (_targets.values.any((target) => target.key == key)) continue;
        total -= sizes[key] ?? 0;
        await _forget(key);
      }
    } catch (_) {
      // 掃不動就跳過這一輪, 額度下次再收
    }
  }

  Future<void> close() async {
    _closed = true;
    _targets.clear();
    _metaWork.clear();
    _http.close();
    try {
      await _server.close(force: true);
    } catch (_) {
      // 已經關了
    }
  }
}
