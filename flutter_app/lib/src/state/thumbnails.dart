/// 封面/縮圖的來源與落盤快取.
///
/// 以前每張封面都是去打伺服器的 /thumbnail.jpg?id=sn: 那條路在伺服器上可能要
/// 先問一次動畫瘋 API, 再去 CDN 抓圖, 全部卡在一個 per-sn 的鎖後面. 片庫有
/// 兩百多部作品時就是兩百多筆這種請求同時擠過去, 慢得跟沒圖一樣.
///
/// 現在改成: 開機時抓一份 /thumbnails.json (伺服器只是把自己 anime_info 快取裡
/// 的 cover 網址整理出來, 不會對外連線), 之後客戶端直接去 CDN 抓圖, 自己存在
/// `<support>/covers/` 下面. 伺服器那條路只留給清單裡沒有的 sn.
///
/// 快取的檔名只用「網址」算 sha1 —— 不要把 auth header 摻進去. CachedNetwork
/// Image 那邊原本的 cacheKey 就是連 header 一起 hash 的, 結果每次 token 變動
/// 整個磁碟快取就等於全毀.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../api/client.dart';

/// 磁碟上最多留幾張. 一頁片庫大概 30~40 張, 留 600 張夠使用者來回翻好幾頁.
const int kCoverCacheMax = 600;

/// 也順便設一個位元組上限 —— 動畫瘋的 3:4 封面大多在 60~120 KB.
const int kCoverCacheBytes = 80 * 1024 * 1024;

/// 同時去 CDN 抓幾張. CDN 很快, 放寬一點捲動起來才跟得上.
const int kCoverFetchConcurrency = 6;

/// 同時去伺服器要幾張. 每一筆都可能在伺服器上開一支 ffmpeg, 所以壓得很低.
const int kServerThumbConcurrency = 2;

/// 一次非同步排隊的名額. 交棒時直接把名額傳給下一個等待者 —— 先減再加的話
/// 中間那一瞬間會被新來的插隊, 實際在飛的數量就超收了.
class _Gate {
  _Gate(this._limit);

  final int _limit;
  int _active = 0;
  final Queue<Completer<void>> _waiting = Queue<Completer<void>>();

  Future<T> run<T>(Future<T> Function() body) async {
    if (_active >= _limit) {
      final waiter = Completer<void>();
      _waiting.add(waiter);
      await waiter.future;
    } else {
      _active++;
    }
    try {
      return await body();
    } finally {
      if (_waiting.isEmpty) {
        _active--;
      } else {
        _waiting.removeFirst().complete();
      }
    }
  }
}

class ThumbnailStore extends ChangeNotifier {
  ThumbnailStore(this._client);

  final AgpClient _client;
  final http.Client _http = http.Client();

  /// animeSn -> 3:4 主視覺
  Map<String, String> _posters = const {};

  /// videoSn -> (animeSn, 16:9 劇照)
  Map<String, List<String>> _episodes = const {};

  Directory? _dir;
  Directory? _coverDir;
  String _etag = '';
  bool _loaded = false;

  final _Gate _cdnGate = _Gate(kCoverFetchConcurrency);
  final _Gate _serverGate = _Gate(kServerThumbConcurrency);

  /// 同一張圖正在抓的時候別再開第二筆 —— 捲動時同一個 sn 會被 build 很多次.
  final Map<String, Future<File?>> _inFlight = {};

  /// 抓過但失敗的, 這一輪不要再試. 不然每次重畫都會再打一次同一個 404.
  final Set<String> _failed = <String>{};

  bool get isEmpty => _posters.isEmpty && _episodes.isEmpty;

  // ------------------------------------------------------------------ 清單

  Future<Directory> _supportDir() async =>
      _dir ??= await getApplicationSupportDirectory();

  Future<File> _manifestFile() async =>
      File('${(await _supportDir()).path}/thumbnails.json');

  Future<File> _etagFile() async =>
      File('${(await _supportDir()).path}/thumbnails.etag');

  Future<Directory> _covers() async {
    final cached = _coverDir;
    if (cached != null) return cached;
    final dir = Directory('${(await _supportDir()).path}/covers');
    if (!dir.existsSync()) await dir.create(recursive: true);
    return _coverDir = dir;
  }

  /// 開機時叫一次: 把上次那份清單擺上去, 順便準備好目錄, 讓 cachedFile() 之後
  /// 都能同步回答 —— 熱的封面第一帧就該畫出來, 不能等一輪 await.
  Future<void> init() async {
    if (_loaded) return;
    _loaded = true;
    try {
      await _covers();
      final file = await _manifestFile();
      if (file.existsSync()) _apply(jsonDecode(await file.readAsString()));
      final etag = await _etagFile();
      if (etag.existsSync()) _etag = (await etag.readAsString()).trim();
    } catch (_) {
      // 壞掉就當作沒有, refresh() 會重抓
    }
    notifyListeners();
  }

  /// 跟伺服器要新的清單. 帶 ETag, 沒變就只是一個 304.
  ///
  /// 失敗一律靜靜吞掉: 舊版伺服器根本沒有 /thumbnails.json (404), 那種情況該
  /// 退化回 /thumbnail.jpg, 不是在畫面上彈錯誤.
  Future<void> refresh() async {
    if (!_client.hasServer) return;
    await init();
    try {
      final fresh = await _client.thumbnailManifest(_etag.isEmpty ? null : _etag);
      // 問得到伺服器就表示網路通了, 之前抓不到的那些再給一次機會 —— 離線時
      // 每一格都會失敗一次並記在黑名單裡, 不清掉的話回線上還是一片漸層
      _failed.clear();
      if (fresh.notModified) return;
      final body = fresh.body;
      if (body == null) return;
      _apply(jsonDecode(body));
      _etag = fresh.etag;
      notifyListeners();
      // 先讓畫面拿到新清單, 再把它存下來. 存這一步要等 —— unawaited 的話
      // 「下次開機還在」就變成跟關 app 的時間點賽跑.
      await _saveManifest(body, fresh.etag);
    } catch (_) {
      // 沒清單就沒清單
    }
  }

  void _apply(dynamic decoded) {
    if (decoded is! Map) return;
    final anime = decoded['anime'];
    if (anime is Map) {
      _posters = {
        for (final entry in anime.entries)
          if (entry.value is String && (entry.value as String).isNotEmpty)
            entry.key.toString(): entry.value as String,
      };
    }
    final episodes = decoded['episodes'];
    if (episodes is Map) {
      _episodes = {
        for (final entry in episodes.entries)
          if (entry.value is List && (entry.value as List).isNotEmpty)
            entry.key.toString(): [
              for (final value in entry.value as List) value?.toString() ?? '',
            ],
      };
    }
  }

  Future<void> _saveManifest(String body, String etag) async {
    try {
      await (await _manifestFile()).writeAsString(body);
      await (await _etagFile()).writeAsString(etag);
    } catch (_) {
      // 存不下就算了
    }
  }

  Future<void> clear() async {
    _posters = const {};
    _episodes = const {};
    _etag = '';
    _failed.clear();
    try {
      final manifest = await _manifestFile();
      if (manifest.existsSync()) await manifest.delete();
      final etag = await _etagFile();
      if (etag.existsSync()) await etag.delete();
      final covers = await _covers();
      if (covers.existsSync()) await covers.delete(recursive: true);
      _coverDir = null;
    } catch (_) {
      // 刪不掉下次再說
    }
    notifyListeners();
  }

  // ------------------------------------------------------------------ 查表

  /// 這一集所屬作品的 animeSn. 清單裡沒有就回 null.
  String? animeSnOf(String sn) {
    final row = _episodes[sn];
    if (row == null || row.isEmpty) return null;
    return row[0].isEmpty ? null : row[0];
  }

  /// 3:4 主視覺. sn 可以是 animeSn, 也可以是某一集的 videoSn.
  String? posterFor(String sn) {
    final direct = _posters[sn];
    if (direct != null && direct.isNotEmpty) return direct;
    final animeSn = animeSnOf(sn);
    if (animeSn == null) return null;
    final poster = _posters[animeSn];
    return (poster == null || poster.isEmpty) ? null : poster;
  }

  /// 16:9 劇照. 沒有的話退回主視覺 —— 有圖比沒圖好, 比例交給 BoxFit.cover.
  String? stillFor(String sn) {
    final row = _episodes[sn];
    if (row != null && row.length > 1 && row[1].isNotEmpty) return row[1];
    return posterFor(sn);
  }

  String? urlFor(String sn, {bool poster = false}) =>
      poster ? posterFor(sn) : stillFor(sn);

  // -------------------------------------------------------------- 位元組快取

  String _key(String url) => sha1.convert(utf8.encode(url)).toString();

  /// 同步問「這張圖在磁碟上嗎」. 熱的封面靠這個在第一帧就畫出來.
  File? cachedFile(String? url) {
    if (url == null || url.isEmpty) return null;
    final dir = _coverDir;
    if (dir == null) return null;
    final file = File('${dir.path}/${_key(url)}.img');
    return file.existsSync() ? file : null;
  }

  /// 伺服器那條路的快取. key 只用 sn, 不含 token —— 換帳號不該讓圖全部重抓.
  File? cachedServerThumb(String sn) {
    final dir = _coverDir;
    if (dir == null) return null;
    final file = File('${dir.path}/${_key('thumb:$sn')}.img');
    return file.existsSync() ? file : null;
  }

  /// 這一格要的圖, 已經在磁碟上的話同步給. 給 build() 用.
  File? cached(String sn, {bool poster = false, String? fallbackUrl}) =>
      cachedFile(urlFor(sn, poster: poster)) ??
      cachedFile(fallbackUrl) ??
      cachedServerThumb(sn);

  /// 同一把 key 只准有一筆在飛 —— 捲動時同一張圖會被 build 很多次.
  Future<File?> _dedupe(String key, Future<File?> Function() body) {
    final running = _inFlight[key];
    if (running != null) return running;
    // 收尾一定要寫成大括號: `() => _inFlight.remove(key)` 回的是被移掉的那個
    // future, 也就是 task 自己 —— whenComplete 收到 Future 就會等它, task 等
    // 到的是 task, 整條直接鎖死, 圖永遠抓不完.
    final task = body().whenComplete(() {
      _inFlight.remove(key);
    });
    _inFlight[key] = task;
    return task;
  }

  /// 抓這一集/這部作品的圖.
  ///
  /// 順序: 清單上的 CDN 網址 → 呼叫端自己手上那個網址 (收藏清單、片單卡片本來
  /// 就帶著封面) → 伺服器的 /thumbnail.jpg. 最後那條最貴, 所以排最後.
  Future<File?> resolve(String sn, {bool poster = false, String? fallbackUrl}) =>
      _dedupe('$sn:${poster ? 'p' : 's'}',
          () => _resolve(sn, poster: poster, fallbackUrl: fallbackUrl));

  /// 直接給網址的那種 —— 片單卡片的 cover 本來就是動畫瘋 CDN 的網址, 不必
  /// 繞伺服器一圈, 但一樣要落盤.
  Future<File?> resolveUrl(String url, {Map<String, String>? headers}) {
    if (url.isEmpty || _failed.contains(url)) return Future<File?>.value(null);
    final hit = cachedFile(url);
    if (hit != null) return Future<File?>.value(hit);
    // 指回自己伺服器的那種 (/thumbnail.jpg) 走窄的那道閘: 每一筆都可能在
    // 伺服器上開一支 ffmpeg.
    final gate = _client.hasServer && url.startsWith(_client.baseUrl)
        ? _serverGate
        : _cdnGate;
    return _dedupe(url, () async {
      final file =
          await gate.run(() => _download(url, _key(url), headers: headers));
      if (file == null) _failed.add(url);
      return file;
    });
  }

  Future<File?> _resolve(String sn,
      {required bool poster, String? fallbackUrl}) async {
    for (final url in [urlFor(sn, poster: poster), fallbackUrl]) {
      if (url == null || url.isEmpty || _failed.contains(url)) continue;
      final hit = cachedFile(url);
      if (hit != null) return hit;
      final file = await _cdnGate.run(() => _download(url, _key(url)));
      if (file != null) return file;
      _failed.add(url);
    }
    final serverKey = 'thumb:$sn';
    if (_failed.contains(serverKey)) return null;
    final hit = cachedServerThumb(sn);
    if (hit != null) return hit;
    if (!_client.hasServer) return null;
    final file = await _serverGate.run(() => _download(
          _client.thumbnailUrl(sn).toString(),
          _key(serverKey),
          headers: _client.authHeaders,
        ));
    if (file == null) _failed.add(serverKey);
    return file;
  }

  Future<File?> _download(String url, String key,
      {Map<String, String>? headers}) async {
    try {
      final response = await _http
          .get(Uri.parse(url), headers: headers)
          .timeout(const Duration(seconds: 20));
      if (response.statusCode >= 400) return null;
      final bytes = response.bodyBytes;
      // 太小的一定不是圖 (伺服器那條路在出錯時會回一小段文字)
      if (bytes.length < 256) return null;
      final dir = await _covers();
      final file = File('${dir.path}/$key.img');
      // 先寫暫存檔再改名: 半張圖被別人同步讀到的話會變成一個壞掉的 Image.file
      final temp = File('${file.path}.part');
      await temp.writeAsBytes(bytes, flush: true);
      if (file.existsSync()) await file.delete();
      await temp.rename(file.path);
      unawaited(_trim());
      return file;
    } catch (_) {
      return null;
    }
  }

  bool _trimming = false;

  /// 照 mtime 丟掉最舊的. 跟彈幕快取同一個形狀.
  Future<void> _trim() async {
    if (_trimming) return;
    _trimming = true;
    try {
      final dir = await _covers();
      final files = <File>[];
      await for (final item in dir.list()) {
        if (item is File) files.add(item);
      }
      var total = 0;
      final stamped = <MapEntry<File, DateTime>>[];
      for (final file in files) {
        try {
          final stat = await file.stat();
          total += stat.size;
          stamped.add(MapEntry(file, stat.modified));
        } catch (_) {
          // 量不到就當它最舊, 優先丟掉
          stamped.add(MapEntry(file, DateTime.fromMillisecondsSinceEpoch(0)));
        }
      }
      if (stamped.length <= kCoverCacheMax && total <= kCoverCacheBytes) return;
      stamped.sort((a, b) => a.value.compareTo(b.value));
      var count = stamped.length;
      for (final entry in stamped) {
        if (count <= kCoverCacheMax && total <= kCoverCacheBytes) break;
        try {
          total -= (await entry.key.stat()).size;
          await entry.key.delete();
        } catch (_) {
          // 刪不掉下次再說
        }
        count--;
      }
    } catch (_) {
      // 掃到一半被改也沒關係, 這只是在省空間
    } finally {
      _trimming = false;
    }
  }

  /// 封面快取現在佔多少 (設定頁顯示用)
  Future<int> cacheBytes() async {
    final dir = _coverDir;
    if (dir == null || !dir.existsSync()) return 0;
    var total = 0;
    try {
      await for (final item in dir.list()) {
        if (item is File) total += (await item.stat()).size;
      }
    } catch (_) {
      // 只是拿來顯示的
    }
    return total;
  }

  @override
  void dispose() {
    _http.close();
    super.dispose();
  }
}
