/// 片庫縮圖的手機端快取: 直接問巴哈, 圖片存在手機上.
///
/// 之前片庫卡片是拿 `AgpClient.thumbnailUrl(sn)` 去打自家伺服器的
/// /thumbnail.jpg 代理 —— 伺服器一換憑證 / 一擋就整面變成漸層 fallback.
/// 這裡改成手機自己來:
///
///   1. 打巴哈 mobile v4 API 問這一集的 cover (`data.video.cover`);
///   2. 把那張圖直接抓下來, 存到 application support 目錄下的 thumbnails/;
///   3. 下次先看磁碟, 有就直接用, 沒網路也一樣.
///
/// 只送公開的手機 User-Agent / Accept / Referer, 絕對不帶自家伺服器的
/// Cookie token —— 那是兩邊不同的信任域.
///
/// 純 Dart, 不碰 flutter: 邏輯可以用一般的 Dart SDK 直接測.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// 手機瀏覽器的樣子. 巴哈擋沒有 UA 的請求, 送這個跟其他平台的 app 一致.
const String kBahamutMobileUserAgent =
    'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) '
    'AppleWebKit/605.1.15 (KHTML, like Gecko) '
    'Version/17.0 Mobile/15E148 Safari/604.1';

/// thumbnails/ 底下最多留幾張. 超過就把最久沒碰的整張丟掉 ——
/// 縮圖一張幾十 KB, 300 張大約十幾 MB, 不會無限長大.
const int kThumbnailMaxEntries = 300;

/// 單張圖片最多收幾個 byte. 封面不該是 MB 級的東西, 超過就是異常回應.
const int kThumbnailMaxBytes = 10 * 1024 * 1024;

const Duration _kMetaTimeout = Duration(seconds: 15);
const Duration _kImageTimeout = Duration(seconds: 30);

/// 直接跟巴哈要一集的縮圖 bytes. 回 null 表示拿不到 (呼叫端退回漸層).
///
/// [client] 是測試縫: 沒給就自己開一個用完即丟的. 不論哪條路都不送 Cookie.
Future<Uint8List?> fetchBahamutThumbnailBytes(
  String sn, {
  http.Client? client,
}) async {
  final cover = await _coverFor(sn, client: client);
  if (cover == null) return null;
  return _downloadCover(cover, client: client);
}

Future<String?> _coverFor(String sn, {http.Client? client}) async {
  if (sn.trim().isEmpty) return null;
  final owned = client == null;
  final httpClient = client ?? http.Client();
  try {
    final response = await httpClient
        .get(ThumbnailStore.metadataUrl(sn.trim()),
            headers: ThumbnailStore.metadataHeaders)
        .timeout(_kMetaTimeout);
    if (response.statusCode != 200 || response.bodyBytes.isEmpty) {
      return null;
    }
    dynamic data;
    try {
      data = jsonDecode(utf8.decode(response.bodyBytes));
    } catch (_) {
      return null;
    }
    return ThumbnailStore.coverUrlOf(data);
  } on TimeoutException {
    return null;
  } catch (_) {
    return null;
  } finally {
    if (owned) httpClient.close();
  }
}

Future<Uint8List?> _downloadCover(String url, {http.Client? client}) async {
  final owned = client == null;
  final httpClient = client ?? http.Client();
  try {
    final response = await httpClient
        .get(Uri.parse(url), headers: ThumbnailStore.imageHeaders)
        .timeout(_kImageTimeout);
    if (response.statusCode != 200) return null;
    final contentType =
        response.headers['content-type'] ?? response.headers['Content-Type'];
    if (!_looksLikeImage(
        response.bodyBytes, (contentType ?? '').toLowerCase())) {
      return null;
    }
    return response.bodyBytes;
  } on TimeoutException {
    return null;
  } catch (_) {
    return null;
  } finally {
    if (owned) httpClient.close();
  }
}

/// 別把 HTML 錯誤頁 (登入頁 / 被擋) 當成圖片存起來.
///
/// 規則: Content-Type 是 text/* 或帶 html 字樣的一律不要; 剩下的看檔頭
/// magic (jpeg/png/gif/webp/bmp/ftyp), 對不上 magic 的也不要.
bool _looksLikeImage(List<int> bytes, String contentType) {
  if (bytes.isEmpty || bytes.length > kThumbnailMaxBytes) return false;
  if (contentType.contains('html') || contentType.startsWith('text/')) {
    return false;
  }
  // 前導空白後第一個字元是 '<' 就是 HTML, 不管 Content-Type 說什麼
  var start = 0;
  while (start < bytes.length &&
      (bytes[start] == 0x20 ||
          bytes[start] == 0x09 ||
          bytes[start] == 0x0A ||
          bytes[start] == 0x0D)) {
    start++;
  }
  if (start < bytes.length && bytes[start] == 0x3C) return false;

  bool magic(List<int> head) {
    if (bytes.length < head.length) return false;
    for (var i = 0; i < head.length; i++) {
      if (bytes[i] != head[i]) return false;
    }
    return true;
  }

  bool asciiAt(int offset, String text) {
    if (bytes.length < offset + text.length) return false;
    for (var i = 0; i < text.length; i++) {
      if (bytes[offset + i] != text.codeUnitAt(i)) return false;
    }
    return true;
  }

  // JPEG / PNG / GIF / BMP
  if (magic(const [0xFF, 0xD8, 0xFF])) return true;
  if (magic(const [0x89, 0x50, 0x4E, 0x47])) return true;
  if (asciiAt(0, 'GIF8')) return true;
  if (magic(const [0x42, 0x4D])) return true;
  // WebP: RIFF....WEBP
  if (asciiAt(0, 'RIFF') && asciiAt(8, 'WEBP')) return true;
  // AVIF / HEIC: ....ftyp
  if (asciiAt(4, 'ftyp')) return true;
  return false;
}

class ThumbnailStore {
  ThumbnailStore({
    http.Client? httpClient,
    Directory? directory,
    this.maxEntries = kThumbnailMaxEntries,
  })  : _http = httpClient ?? http.Client(),
        _dir = directory;

  final http.Client _http;
  Directory? _dir;
  final int maxEntries;

  /// 同一個 sn 同時被很多張卡片問時, 只真的打一次網路.
  final Map<String, Future<File?>> _inflight = {};

  static Uri metadataUrl(String sn) => Uri.https(
      'api.gamer.com.tw', '/mobile_app/anime/v4/video.php', {'sn': sn});

  /// 只送公開的手機標頭. 這裡永遠沒有 Cookie —— 自家伺服器的 token
  /// 絕對不能出現在往巴哈的請求裡.
  static Map<String, String> get metadataHeaders => const {
        'Accept': 'application/json',
        'User-Agent': kBahamutMobileUserAgent,
      };

  static Map<String, String> get imageHeaders => const {
        'Accept': 'image/*,*/*;q=0.8',
        'Referer': 'https://ani.gamer.com.tw/',
        'User-Agent': kBahamutMobileUserAgent,
      };

  /// 從 v4 video API 的回應裡把 `data.video.cover` 撿出來.
  /// 不是 http(s) URL 的一律回 null (不跟著跳轉、不吃 javascript:).
  static String? coverUrlOf(dynamic data) {
    try {
      if (data is! Map) return null;
      final root = data['data'];
      if (root is! Map) return null;
      final video = root['video'];
      if (video is! Map) return null;
      final cover = (video['cover'] ?? '').toString().trim();
      if (cover.isEmpty) return null;
      final uri = Uri.tryParse(cover);
      if (uri == null || uri.host.isEmpty) return null;
      if (uri.scheme != 'http' && uri.scheme != 'https') return null;
      return cover;
    } catch (_) {
      return null;
    }
  }

  Directory? get directory => _dir;

  /// 落到 application support 目錄下的 thumbnails/. 起不來就丟例外,
  /// 呼叫端 (AppState) 負責吞掉 —— 縮圖本來就是配菜.
  Future<void> init(Directory base) async {
    final dir = Directory('${base.path}/thumbnails');
    await dir.create(recursive: true);
    _dir = dir;
  }

  static String _fileName(String sn) {
    final safe = sn.trim().replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    return 'thumb-$safe.jpg';
  }

  File? _fileFor(String sn) {
    final dir = _dir;
    if (dir == null || sn.trim().isEmpty) return null;
    return File('${dir.path}/${_fileName(sn)}');
  }

  /// 磁碟上有沒有這一集 (同步, UI build 裡直接問).
  /// 命中時順手把 mtime 往現在碰一下, 給 LRU 淘汰看.
  File? cachedFile(String sn) {
    final file = _fileFor(sn);
    if (file == null) return null;
    try {
      if (!file.existsSync() || file.lengthSync() <= 0) return null;
      try {
        file.setLastModifiedSync(DateTime.now());
      } catch (_) {
        // 碰不到就算了, 不影響使用
      }
      return file;
    } catch (_) {
      return null;
    }
  }

  /// 先看磁碟, 沒有才打網路. 失敗一律回 null (呼叫端畫漸層就好).
  Future<File?> load(String sn) {
    final key = sn.trim();
    if (key.isEmpty) return Future.value(null);
    final hit = cachedFile(key);
    if (hit != null) return Future.value(hit);
    return _inflight.putIfAbsent(key, () async {
      try {
        return await _fetchAndSave(key);
      } finally {
        _inflight.remove(key);
      }
    });
  }

  Future<File?> _fetchAndSave(String sn) async {
    // 排隊時別人已經抓好了就直接用
    final hit = cachedFile(sn);
    if (hit != null) return hit;
    final target = _fileFor(sn);
    if (target == null) return null;
    Uint8List? bytes;
    try {
      final cover = await _coverFor(sn, client: _http);
      if (cover == null) return null;
      bytes = await _downloadCover(cover, client: _http);
    } catch (_) {
      return null;
    }
    if (bytes == null || bytes.isEmpty) return null;
    try {
      // 目錄可能還沒建 (或中途被系統清掉), 先確保它在
      await target.parent.create(recursive: true);
      // 先寫 .part 再改名: 下載到一半被殺掉也不會留下半張圖被當成快取
      final part = File('${target.path}.part');
      await part.writeAsBytes(bytes, flush: true);
      await part.rename(target.path);
      // 同步等修剪做完: 目錄列舉很便宜, 換來的是「上限」真的有上限
      await _trim();
      return target;
    } catch (_) {
      try {
        final part = File('${target.path}.part');
        if (part.existsSync()) await part.delete();
      } catch (_) {
        // 收不乾淨就算了
      }
      return null;
    }
  }

  /// 超過上限就把最久沒碰的整張丟掉. 掃不動就跳過這一輪.
  Future<void> _trim() async {
    final dir = _dir;
    final cap = maxEntries < 1 ? kThumbnailMaxEntries : maxEntries;
    if (dir == null) return;
    try {
      final files = <File>[];
      await for (final item in dir.list()) {
        if (item is File &&
            item.path.endsWith('.jpg') &&
            !item.path.endsWith('.part')) {
          files.add(item);
        }
      }
      if (files.length <= cap) return;
      final stamped = <MapEntry<File, DateTime>>[];
      for (final file in files) {
        try {
          stamped.add(MapEntry(file, await file.lastModified()));
        } catch (_) {
          stamped.add(MapEntry(file, DateTime.fromMillisecondsSinceEpoch(0)));
        }
      }
      stamped.sort((a, b) => a.value.compareTo(b.value));
      for (final entry in stamped.take(stamped.length - cap)) {
        try {
          await entry.key.delete();
        } catch (_) {
          // 刪不掉下次再說
        }
      }
    } catch (_) {
      // 快取掃不動不該影響畫面
    }
  }

  void close() {
    try {
      _http.close();
    } catch (_) {
      // 已經關了
    }
    _inflight.clear();
  }
}
