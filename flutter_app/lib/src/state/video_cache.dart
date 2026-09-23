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
///
/// 整台跑在自己的 isolate 裡. 播放器讀的每一個 byte 都要經過這裡一手 (複製、
/// 落盤、再寫回 socket), 以前這些全擠在畫面那條執行緒上, 跟彈幕搶同一顆核心
/// —— 播放器一口氣緩衝的那幾秒, 彈幕就一頓一頓的. 主 isolate 這邊只剩一層
/// 薄薄的殼: 轉發 wrap(), 收速度.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

/// 一塊多大. 小塊比較省 (跳轉時對齊浪費的少), 但一集會生出很多檔案;
/// 1 MB 的話 428 MB 的一集全看完大約 428 塊.
const int kCacheBlockBytes = 1024 * 1024;

/// 整個快取目錄的上限. 滿了就整集整集地丟, 最久沒碰的先走.
const int kCacheBudgetBytes = 1536 * 1024 * 1024;

/// 速度是拿這段時間內轉手的量算的
const Duration kSpeedWindow = Duration(milliseconds: 2500);

/// 跟上游要東西時, 從連線到拿到回應標頭最多等多久.
///
/// 不設的話會等到天荒地老: 切過 VPN、換過 Wi-Fi 之後, 連線池裡那條舊連線
/// 寫得進去卻永遠等不到回應, 播放器就卡在緩衝, 只能把 app 整個關掉重開.
const Duration kUpstreamConnectTimeout = Duration(seconds: 12);

/// 資料流到一半, 完全沒有東西進來多久就算這條連線死了.
///
/// 只算「我們在等上游」的時間. 播放器緩衝滿了不讀的那段, 上游本來就該停,
/// 那時候計時器是停著的 (回壓會一路 pause 到這一層).
const Duration kUpstreamStallTimeout = Duration(seconds: 10);

/// 同一段連續失敗幾次就放棄, 交還給播放器自己處理
const int kUpstreamRetries = 4;

// ignore: constant_identifier_names
const String HLS_MIME = 'application/vnd.apple.mpegurl';

/// 速度回報多久送一次. 每一包都送的話主 isolate 一秒要被叫醒幾十次.
const Duration _kSpeedReport = Duration(milliseconds: 100);

/// 最近開過的這幾集不會被淘汰 —— 正在播的、剛退出去等著接回來的都在裡面
const int _kProtectedKeys = 4;

class _Target {
  _Target({
    required this.upstream,
    required this.headers,
    required this.key,
    this.hls = false,
  });

  final Uri upstream;
  final Map<String, String> headers;
  final String key;

  /// 換畫質時走的是 /stream/playlist.m3u8, 那是一份 HLS 播放清單, 不是可以用
  /// Range 切的單一檔案 —— 快取的方式完全不一樣, 一片一片存.
  final bool hls;
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

String _sanitize(String key) => key.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_');

// =================================================================== 主 isolate

/// 主 isolate 這一側. 真正在收發資料的是 [_CacheWorker], 在另一個 isolate.
class VideoCacheServer {
  VideoCacheServer._(
      this._isolate, this._commands, this.port, this._events, this._exit);

  final Isolate _isolate;
  final SendPort _commands;
  final ReceivePort _events;
  final ReceivePort _exit;
  final Completer<void> _closedAck = Completer<void>();
  final Completer<void> _exited = Completer<void>();
  final List<List<int>> _samples = <List<int>>[];

  /// 本機那台聽的埠
  final int port;

  int _token = 0;
  bool _closed = false;

  /// 起一台. 起不來 (權限、沒有 loopback) 就回 null, 呼叫端退回直連.
  ///
  /// 兩個逾時只有測試會改 —— 正式的值要等十秒, 測試不想陪著等.
  static Future<VideoCacheServer?> start(
    Directory dir, {
    Duration connectTimeout = kUpstreamConnectTimeout,
    Duration stallTimeout = kUpstreamStallTimeout,
  }) async {
    final hello = ReceivePort();
    // 這兩個在 spawn 之前就開好: 那一頭一起來就可能開始回報, 也可能馬上掛掉
    final events = ReceivePort();
    final exit = ReceivePort();
    Isolate? isolate;
    try {
      isolate = await Isolate.spawn(
        _workerMain,
        _WorkerConfig(
          hello: hello.sendPort,
          events: events.sendPort,
          dir: dir.path,
          connectTimeout: connectTimeout,
          stallTimeout: stallTimeout,
        ),
        onExit: exit.sendPort,
        debugName: 'video-cache',
      );
      // 第一句話: [埠, 下指令用的 SendPort], 起不來就是 null
      final first = await hello.first.timeout(const Duration(seconds: 10));
      if (first is! List || first.length != 2) {
        throw StateError('video cache worker failed to bind');
      }
      final server = VideoCacheServer._(
          isolate, first[1] as SendPort, first[0] as int, events, exit);
      server._listen();
      return server;
    } catch (_) {
      hello.close();
      events.close();
      exit.close();
      isolate?.kill(priority: Isolate.immediate);
      return null;
    }
  }

  void _listen() {
    _events.listen((message) {
      if (message is List && message.length == 2) {
        // [這一批的第一個 byte 是什麼時候轉手的, 這一批多少 byte]
        _samples.add(<int>[message[0] as int, message[1] as int]);
        _prune(DateTime.now().millisecondsSinceEpoch);
      } else if (message == 'closed' && !_closedAck.isCompleted) {
        _closedAck.complete();
      }
    });
    _exit.listen((_) {
      // 那一頭不管是正常收掉還是掛了, 這一台都不能再用 —— healthy() 會回
      // false, 下次開播時 AppState 會重起一台
      _closed = true;
      if (!_exited.isCompleted) _exited.complete();
    });
  }

  bool get closed => _closed;

  /// 這台還連得上嗎.
  ///
  /// app 被切到背景之後, 監聽中的 socket 有機會已經被系統收走 (iOS 掛起時
  /// 尤其會). 那時候播放器連過來只會拿到一個連不上, 畫面就卡在載入 —— 回到
  /// 前景時要能發現這件事, 重起一台.
  Future<bool> healthy() async {
    if (_closed) return false;
    try {
      final socket = await Socket.connect(InternetAddress.loopbackIPv4, port,
          timeout: const Duration(milliseconds: 800));
      socket.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

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

  /// 把一個伺服器上的位址換成本機的. key 要能代表「哪一集的哪一份」——
  /// 換了畫質就是另一份, 不能共用同一塊快取.
  Uri wrap({
    required Uri upstream,
    required Map<String, String> headers,
    required String key,
  }) {
    if (_closed) return upstream;
    final token = (++_token).toString();
    // 這一句一定比播放器連過來那一下先到: 同一個 isolate 的訊息照送出的順序
    // 處理, 而播放器要等這個函式回傳之後才拿得到網址
    _commands.send(<Object>[
      'wrap',
      token,
      upstream.toString(),
      Map<String, String>.of(headers),
      _sanitize(key),
      false,
    ]);
    return Uri.parse('http://127.0.0.1:$port/v/$token');
  }

  /// 換畫質那條路 (/stream/playlist.m3u8) 的版本.
  ///
  /// 那份清單裡的分片寫的是相對路徑 (segment.ts?id=..&res=..&n=N), 所以只要
  /// 清單本身是從這台發出去的, 播放器要分片時就會回頭問我們 —— 於是每一片都
  /// 能存下來. 分片的內容由 (sn, res, n) 決定, 不會變, 存了就一直有效.
  Uri wrapHls({
    required Uri playlist,
    required Map<String, String> headers,
    required String key,
  }) {
    if (_closed) return playlist;
    final token = (++_token).toString();
    _commands.send(<Object>[
      'wrap',
      token,
      playlist.toString(),
      Map<String, String>.of(headers),
      _sanitize(key),
      true,
    ]);
    return Uri.parse('http://127.0.0.1:$port/h/$token/playlist.m3u8');
  }

  /// 收掉. 要等那一頭真的放開檔案才回來 —— 接著要刪快取目錄的人 (清除快取、
  /// 測試收尾) 在 Windows 上會撞到還開著的檔案.
  Future<void> close() async {
    if (_closed && _exited.isCompleted) return;
    _closed = true;
    try {
      _commands.send('close');
      await _closedAck.future.timeout(const Duration(seconds: 3));
    } catch (_) {
      // 那一頭已經不在了, 或者收不乾淨 —— 下面直接把它關掉
    }
    _isolate.kill(priority: Isolate.immediate);
    try {
      await _exited.future.timeout(const Duration(seconds: 3));
    } catch (_) {
      // 等不到就算了
    }
    _events.close();
    _exit.close();
  }
}

class _WorkerConfig {
  const _WorkerConfig({
    required this.hello,
    required this.events,
    required this.dir,
    required this.connectTimeout,
    required this.stallTimeout,
  });

  final SendPort hello;
  final SendPort events;
  final String dir;
  final Duration connectTimeout;
  final Duration stallTimeout;
}

void _workerMain(_WorkerConfig config) {
  // 這個 isolate 裡的任何一個例外都不該讓它整個掛掉 —— 那等於正在播的那一集
  // 突然斷線. 真的掛了主 isolate 那邊會收到 exit, 下次開播會重起一台.
  runZonedGuarded(() async {
    final worker = await _CacheWorker.start(Directory(config.dir),
        connectTimeout: config.connectTimeout,
        stallTimeout: config.stallTimeout);
    if (worker == null) {
      config.hello.send(null);
      return;
    }
    worker.events = config.events;
    final commands = ReceivePort();
    commands.listen((message) async {
      if (message is List && message.isNotEmpty && message[0] == 'wrap') {
        worker.register(
          message[1] as String,
          _Target(
            upstream: Uri.parse(message[2] as String),
            headers: (message[3] as Map).cast<String, String>(),
            key: message[4] as String,
            hls: message[5] as bool,
          ),
        );
      } else if (message == 'close') {
        await worker.close();
        config.events.send('closed');
        commands.close();
      }
    });
    config.hello.send(<Object>[worker.port, commands.sendPort]);
  }, (error, stack) {
    // 吞掉. 播放器那一頭會看到連線斷掉, 它自己會再要一次.
  });
}

// =================================================================== 工作 isolate

class _CacheWorker {
  _CacheWorker._(
    this._server,
    this._dir, {
    required Duration connectTimeout,
    required Duration stallTimeout,
  })  : _connectTimeout = connectTimeout,
        _stallTimeout = stallTimeout,
        _http = IOClient(HttpClient()
          ..connectionTimeout = connectTimeout
          // 閒置的連線別留太久: 切過網路之後, 池子裡那幾條多半已經是死的
          ..idleTimeout = const Duration(seconds: 5));

  final HttpServer _server;
  final Directory _dir;
  final Duration _connectTimeout;
  final Duration _stallTimeout;
  final http.Client _http;
  final Map<String, _Target> _targets = {};
  final Map<String, Future<_Meta?>> _metaWork = {};

  /// 最近 wrap 過的幾集, 淘汰時跳過
  final LinkedHashSet<String> _recentKeys = LinkedHashSet<String>();

  /// 每一集磁碟上有哪幾塊、各存到第幾個 byte.
  ///
  /// 以前每個請求都拿 existsSync / lengthSync 一塊一塊去問磁碟: 播放器發的
  /// 多半是「一路要到檔尾」, 那就是一個請求好幾百次同步的系統呼叫 —— 而且
  /// 當時還是在畫面那條執行緒上. 現在一集只掃一次, 之後照著寫入自己記帳.
  final Map<String, Map<int, int>> _index = {};

  /// 磁碟上總共用了多少. null = 還沒掃過.
  ///
  /// 以前每抓完一段就把整個快取目錄掃一遍 (一千多個檔案各 stat 一次), 只為了
  /// 知道有沒有超過額度. 現在開機掃一次, 之後照著寫入加上去, 真的超過了才掃.
  int? _usage;
  bool _evicting = false;

  /// 主 isolate 那邊收速度的地方
  SendPort? events;
  int _unreported = 0;
  int _unreportedSince = 0;
  int _reportedAt = 0;
  Timer? _reportTimer;

  bool _closed = false;

  static Future<_CacheWorker?> start(
    Directory dir, {
    required Duration connectTimeout,
    required Duration stallTimeout,
  }) async {
    try {
      if (!await dir.exists()) await dir.create(recursive: true);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final worker = _CacheWorker._(server, dir,
          connectTimeout: connectTimeout, stallTimeout: stallTimeout);
      server.listen(worker._handle, onError: (Object _) {});
      unawaited(worker._evict());
      return worker;
    } catch (_) {
      return null;
    }
  }

  int get port => _server.port;

  void register(String token, _Target target) {
    if (_closed) return;
    _targets[token] = target;
    _recentKeys
      ..remove(target.key)
      ..add(target.key);
    while (_recentKeys.length > _kProtectedKeys) {
      _recentKeys.remove(_recentKeys.first);
    }
    if (target.hls) return;
    // 開一集就跟伺服器對一次長度/驗證標頭: 檔案換過的話手上那堆塊就不算數了.
    // 只有一個 byte, 但它必須在發任何一塊快取出去之前做完.
    _metaWork[target.key] = _resolveMeta(target);
  }

  // ---------------------------------------------------------------- 速度

  void _note(int bytes) {
    if (bytes <= 0) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_unreported == 0) _unreportedSince = now;
    _unreported += bytes;
    if (now - _reportedAt >= _kSpeedReport.inMilliseconds) {
      _report();
    } else {
      _reportTimer ??= Timer(_kSpeedReport, _report);
    }
  }

  void _report() {
    _reportTimer?.cancel();
    _reportTimer = null;
    if (_unreported <= 0) return;
    _reportedAt = DateTime.now().millisecondsSinceEpoch;
    events?.send(<int>[_unreportedSince, _unreported]);
    _unreported = 0;
  }

  // ---------------------------------------------------------------- 塊

  Directory _episodeDir(String key) => Directory('${_dir.path}/$key');
  File _metaFile(String key) => File('${_dir.path}/$key/meta.json');
  File _blockFile(String key, int index) => File('${_dir.path}/$key/$index.blk');

  int _blockOf(int offset) => offset ~/ kCacheBlockBytes;
  int _blockStart(int index) => index * kCacheBlockBytes;

  /// 這一塊該有多長 (最後一塊通常不滿)
  int _blockLength(int index, _Meta meta) =>
      math.min(kCacheBlockBytes, meta.total - _blockStart(index));

  static final RegExp _blockName = RegExp(r'^(\d+)\.blk$');

  /// 這一集的塊帳本, 第一次用到時掃一次磁碟.
  ///
  /// 同步掃是故意的: 這裡是背景 isolate, 擋的是自己; 而同步做完就不會有「掃到
  /// 一半, 另一個請求剛好寫進一塊」那種帳對不起來的時候.
  Map<int, int> _coverage(String key) {
    final known = _index[key];
    if (known != null) return known;
    final found = <int, int>{};
    try {
      final dir = _episodeDir(key);
      if (dir.existsSync()) {
        for (final item in dir.listSync()) {
          if (item is! File) continue;
          final match =
              _blockName.firstMatch(item.uri.pathSegments.last);
          if (match == null) continue;
          final length = item.lengthSync();
          if (length > 0) found[int.parse(match.group(1)!)] = length;
        }
      }
    } catch (_) {
      // 掃不動就當作什麼都沒有, 最壞是重抓一次
    }
    return _index[key] = found;
  }

  /// 這一塊從塊開頭算起存了幾個 byte.
  ///
  /// 不是「有沒有」而是「到哪裡」: 播放器開一集時只會把檔頭讀個兩三百 KB 就
  /// 跑去拿 moov, 那一塊永遠湊不滿. 只認滿塊的話, 最常走的那條路就永遠快取
  /// 不到 —— 半塊也是有用的, 前綴照樣發得出去.
  int _blockCovered(String key, int index) => _coverage(key)[index] ?? 0;

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
      final response = await _open(
          target.upstream, {...target.headers, 'Range': 'bytes=0-0'});
      // 那一個 byte 也要讀掉, 連線才回得去池子裡
      await response.stream.timeout(_stallTimeout).drain<void>();
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
    // 帳本先清: 就算下面刪不乾淨, 剩下的檔案下次掃的時候會重新算
    final had = _index.remove(key);
    try {
      final dir = _episodeDir(key);
      if (dir.existsSync()) await dir.delete(recursive: true);
    } catch (_) {
      // 刪不掉的話下面的長度檢查會把那些塊判成不完整
    }
    final usage = _usage;
    if (usage != null && had != null) {
      _usage = math.max(0, usage - had.values.fold<int>(0, (a, b) => a + b));
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

  // -------------------------------------------------------------------- 上游

  /// 發一個 GET, 等到回應標頭為止. 等太久就把這條連線整個放掉, 不是只有不理它
  /// —— 不斷掉的話那條死連線會一直掛在池子裡.
  Future<http.StreamedResponse> _open(
      Uri url, Map<String, String> headers) async {
    final abort = Completer<void>();
    final timer = Timer(_connectTimeout, () {
      if (!abort.isCompleted) abort.complete();
    });
    try {
      return await _http.send(
          http.AbortableRequest('GET', url, abortTrigger: abort.future)
            ..headers.addAll(headers));
    } finally {
      timer.cancel();
    }
  }

  /// 跟上游要 [from]..[to], 中途卡住就從斷掉的地方重新要.
  ///
  /// 播放器那一頭的連線從頭到尾是同一條, 它只會覺得這一段慢了幾秒 —— 以前
  /// 上游那條一死, 播放器就永遠等在那裡, 畫面上是一個掛著「1 B/s」的緩衝,
  /// 只能把 app 關掉重開.
  Stream<List<int>> _upstreamRange(_Target target, int from, int to) async* {
    var at = from;
    var failures = 0;
    while (at <= to && !_closed) {
      if (failures > 0) {
        // 網路剛斷的那一下馬上重連多半也是失敗, 稍微等一下
        await Future<void>.delayed(Duration(milliseconds: 300 * failures));
      }
      http.StreamedResponse response;
      try {
        response = await _open(
            target.upstream, {...target.headers, 'Range': 'bytes=$at-$to'});
      } catch (error) {
        if (++failures > kUpstreamRetries) rethrow;
        continue;
      }
      final status = response.statusCode;
      // 200 = 伺服器不吃 Range, 回的是整個檔. 從頭開始要的那一次還用得上,
      // 接續的那幾次就接不起來了 —— 硬接會把錯的內容寫進快取
      if (status >= 400 || (status == 200 && at != 0)) {
        unawaited(response.stream.drain<void>().catchError((Object _) {}));
        throw HttpException('上游回應 $status', uri: target.upstream);
      }
      final before = at;
      Object? problem;
      try {
        await for (final chunk in response.stream.timeout(_stallTimeout)) {
          if (chunk.isEmpty) continue;
          final room = to - at + 1;
          final piece = chunk.length > room ? chunk.sublist(0, room) : chunk;
          at += piece.length;
          yield piece;
          if (at > to) break;
        }
      } catch (error) {
        // TimeoutException = 卡死了, 其它多半是連線被切斷. 兩種都一樣: 放掉
        // 這條 (await for 退出時會取消訂閱, 連線跟著斷), 從 at 接著要
        problem = error;
      }
      if (at > to) return;
      // 有進度就重新算: 慢但一直有東西進來的線路不該被放棄. 上游提早收掉
      // (沒有錯誤, 只是給得比說好的少) 也算一次失敗.
      failures = at > before ? 1 : failures + 1;
      if (failures > kUpstreamRetries) {
        throw problem ?? TimeoutException('上游一直沒有資料', _stallTimeout);
      }
    }
  }

  // -------------------------------------------------------------------- 請求

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    try {
      final parts = request.uri.pathSegments;
      final token = parts.length > 1 ? parts[1] : '';
      final target = _targets[token];
      if (target == null) {
        response.statusCode = HttpStatus.notFound;
        await response.close();
        return;
      }

      if (target.hls) {
        await _handleHls(
            target, request, response, parts.length > 2 ? parts[2] : '');
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

  /// HLS: 清單原樣轉手, 分片一片一片存起來.
  Future<void> _handleHls(_Target target, HttpRequest request,
      HttpResponse response, String name) async {
    // 清單裡的相對路徑會被解析成 /h/<token>/segment.ts?..., 所以名字就是
    // 上游那條路徑的最後一段
    final upstream = target.upstream.resolve(name.isEmpty ? '.' : name).replace(
        queryParameters: name == 'playlist.m3u8' || name.isEmpty
            ? target.upstream.queryParameters
            : request.uri.queryParameters);

    // 只有分片值得存: 清單很小而且可能過期, 金鑰也小
    if (name == 'segment.ts') {
      final index = request.uri.queryParameters['n'] ?? '';
      if (index.isNotEmpty) {
        final file = File('${_dir.path}/${target.key}/seg-$index.ts');
        if (file.existsSync() && file.lengthSync() > 0) {
          response.statusCode = HttpStatus.ok;
          response.headers.set(HttpHeaders.contentTypeHeader, 'video/mp2t');
          response.contentLength = file.lengthSync();
          await response.addStream(file.openRead());
          await response.close();
          unawaited(_touch(target.key));
          return;
        }
        await _fetchSegment(target, upstream, file, response);
        return;
      }
    }

    await _relay(target, upstream, response,
        mime: name == 'playlist.m3u8' ? HLS_MIME : null);
  }

  /// 抓一片, 邊送邊存
  Future<void> _fetchSegment(_Target target, Uri upstream, File file,
      HttpResponse response) async {
    final part = File('${file.path}.part');
    IOSink? sink;
    try {
      await Directory('${_dir.path}/${target.key}').create(recursive: true);
      sink = part.openWrite();
    } catch (_) {
      sink = null;
    }
    var ok = true;
    try {
      final result = await _open(upstream, target.headers);
      if (result.statusCode >= 400) {
        response.statusCode = result.statusCode;
        await response.close();
        return;
      }
      response.statusCode = HttpStatus.ok;
      response.headers.set(HttpHeaders.contentTypeHeader, 'video/mp2t');
      final length = result.contentLength;
      if (length != null) response.contentLength = length;
      // 一片卡死就整片放掉 (不留半片), 播放器會自己再要一次同一片
      await response
          .addStream(result.stream.timeout(_stallTimeout).map((chunk) {
        _note(chunk.length);
        sink?.add(chunk);
        return chunk;
      }));
      // 落盤要在 response.close() 之前做完. 客戶端看到 EOF 就會馬上回來要
      // 下一片 (或同一片), 那時候這一片必須已經是磁碟上的完成品, 不然它會
      // 再跟上游要一次.
      await sink?.close();
      sink = null;
      final saved = part.existsSync() ? await part.length() : 0;
      if (saved > 0) {
        await part.rename(file.path);
        _grew(saved);
      }
      await response.close();
    } catch (_) {
      ok = false;
      try {
        await response.close();
      } catch (_) {
        // 對面已經走了
      }
    }
    try {
      await sink?.close();
      if (!ok && part.existsSync()) await part.delete();
    } catch (_) {
      // 收不乾淨就算了, 下次重抓
    }
  }

  /// 原樣轉手一個小東西 (清單 / 金鑰)
  Future<void> _relay(_Target target, Uri upstream, HttpResponse response,
      {String? mime}) async {
    try {
      final result = await _open(upstream, target.headers);
      response.statusCode = result.statusCode;
      if (mime != null) {
        response.headers.set(HttpHeaders.contentTypeHeader, mime);
      }
      await response
          .addStream(result.stream.timeout(_stallTimeout).map((chunk) {
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
      try {
        await response.addStream(_blockFile(target.key, index)
            .openRead(at - _blockStart(index), stop - _blockStart(index) + 1));
      } on FileSystemException {
        // 帳上有, 磁碟上卻讀不到 (被系統或使用者清掉了). 帳本丟掉, 下一次
        // 重掃; 這一次讓播放器自己重要.
        _index.remove(target.key);
        rethrow;
      }
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
          final had = _blockCovered(target.key, block);
          // 半塊也留著 —— 但只有在比手上那份更長的時候才換, 不然中途被掐斷
          // 的一小段會把已經存好的整塊蓋掉
          if (grown > 0 && grown > had) {
            await part.rename(_blockFile(target.key, block).path);
            _coverage(target.key)[block] = grown;
            _grew(grown - had);
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

    // 一定要走 addStream: 它會照著 socket 排空的速度回壓上游那條 stream.
    // 手動 add() 沒有這層回壓 —— 播放器緩衝滿了就不再從 socket 讀, 但我們
    // 還是全速把上游灌進記憶體. 慢線路上那等於「頻寬全部拿去抓沒人要的
    // 資料」, 畫面看起來就是明明有東西卻一直在轉圈.
    Stream<List<int>> body() async* {
      await for (final chunk in _upstreamRange(target, aligned, stop)) {
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
          // 整包都落在同一塊裡 (幾乎每一包都是) 就不必再複製一份
          sink?.add(offset == 0 && take == chunk.length
              ? chunk
              : chunk.sublist(offset, offset + take));
          offset += take;
          pos += take;
          // 一塞滿就馬上收尾, 不要等下一塊或整條 stream 結束. 這樣「播放器
          // 收到這一塊的最後一個 byte」時, 那一塊在磁碟上已經是完成品 ——
          // 中途被掐斷也不會白抓一塊.
          if (pos == blockEnd) await settle(keep: true);
        }

        // 往前對齊多要的那一小段是拿來補快取的, 不能發給播放器
        if (pos <= start) continue;
        yield chunkStart >= start ? chunk : chunk.sublist(start - chunkStart);
      }
    }

    try {
      await response.addStream(body());
      await settle(keep: true);
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
      final upstream = await _open(target.upstream, headers);
      response.statusCode = upstream.statusCode;
      upstream.headers.forEach((name, value) {
        if (name == 'transfer-encoding' || name == 'content-encoding') return;
        response.headers.set(name, value);
      });
      await response
          .addStream(upstream.stream.timeout(_stallTimeout).map((chunk) {
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

  /// 磁碟上多了 [bytes]. 帳上超過額度了才真的去掃一遍.
  void _grew(int bytes) {
    final usage = _usage;
    if (usage == null) return; // 開機那一趟還在掃, 它會算到的
    _usage = usage + bytes;
    if (_usage! > kCacheBudgetBytes) unawaited(_evict());
  }

  /// 超過額度就整集整集地丟, 最久沒碰的先走. 丟半集沒有意義 —— 那只會留下
  /// 一堆補不齊的洞.
  Future<void> _evict() async {
    if (_closed || _evicting) return;
    _evicting = true;
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
      _usage = total;
      if (total <= kCacheBudgetBytes) return;

      final order = sizes.keys.toList()
        ..sort((a, b) => seen[a]!.compareTo(seen[b]!));
      for (final key in order) {
        if (total <= kCacheBudgetBytes) break;
        // 正在播的、剛退出去等著接回來的那幾集不能丟
        if (_recentKeys.contains(key)) continue;
        total -= sizes[key] ?? 0;
        await _forget(key);
      }
      _usage = total;
    } catch (_) {
      // 掃不動就跳過這一輪, 額度下次再收
    } finally {
      _evicting = false;
    }
  }

  Future<void> close() async {
    _closed = true;
    _report();
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
