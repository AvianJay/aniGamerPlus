/// 整支 app 共用的狀態: 連的是哪台伺服器、登入的是誰、片庫跟片單的快取.
///
/// 刻意不引入狀態管理套件 —— ChangeNotifier 加 ListenableBuilder 就夠了,
/// 少一個相依就少一次在 CI 上編不過的機會.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../api/client.dart';
import '../api/models.dart';
import 'downloads.dart';
import 'prefs.dart';
import 'video_cache.dart';

class AppState extends ChangeNotifier {
  AppState._(this.prefs)
      : client = AgpClient(
          baseUrl: prefs.server,
          token: prefs.token.isEmpty ? null : prefs.token,
        ) {
    downloads = DownloadStore(client);
  }

  static AppState? _instance;
  static AppState get instance {
    final value = _instance;
    if (value == null) throw StateError('AppState.boot() 還沒跑完');
    return value;
  }

  static Future<AppState> boot() async {
    final prefs = await Prefs.load();
    final state = AppState._(prefs);
    _instance = state;
    await state.downloads.init(concurrency: prefs.downloadConcurrency);
    return state;
  }

  final Prefs prefs;
  final AgpClient client;
  late final DownloadStore downloads;

  ServerInfo serverInfo = ServerInfo();
  CurrentUser? currentUser;

  /// 影片的本機快取. 第一次要用時才起 —— 沒在看影片的人不必背一台伺服器,
  /// 而且 widget test 不會碰到它 (那邊一律 offline).
  VideoCacheServer? videoCache;
  Future<VideoCacheServer?>? _videoCacheBoot;

  /// 連不上伺服器. 這時首頁只剩下載好的那幾集.
  bool offline = false;
  String lastError = '';
  bool booting = true;

  List<VideoItem> library = const [];
  CatalogIndex catalog = CatalogIndex();
  Map<String, WatchTime> watchTimes = const {};

  /// sn -> 片庫條目. videoOf() 在觀看紀錄那一頁是每一列各叫一次, 片庫大起來
  /// 之後線性掃描會變成整頁重畫時最貴的一段.
  Map<String, VideoItem> _libraryIndex = const {};

  /// 這一輪按過「加入下載」的集數. 伺服器要等排程跑到才會回報, 在那之前
  /// 畫面上得先認帳, 不然按鈕看起來像沒反應.
  final Set<String> queued = <String>{};

  bool get hasServer => client.hasServer;
  bool get loggedIn => currentUser != null;
  bool get isAdmin => currentUser?.isAdmin ?? false;

  /// 沒開帳號系統的時候, 每個人都是管理員 —— 網頁版的 canDownload() 就是這樣判的
  bool get canManage => !serverInfo.userControl || isAdmin;

  /// 需要登入才看得到片庫, 但還沒登入
  bool get needsLogin =>
      serverInfo.userControl && serverInfo.onlineWatchRequiresLogin && !loggedIn;

  // --------------------------------------------------------------- 伺服器設定

  Future<void> setServer(String url) async {
    client.baseUrl = url;
    await prefs.setServer(client.baseUrl);
    await refreshAll();
  }

  // -------------------------------------------------------------------- 外觀

  ThemeMode get themeMode {
    switch (prefs.themeMode) {
      case 'light':
        return ThemeMode.light;
      case 'system':
        return ThemeMode.system;
      default:
        return ThemeMode.dark;
    }
  }

  Future<void> setThemeMode(String value) async {
    await prefs.setThemeMode(value);
    notifyListeners();
  }

  /// 手機端偏好改了就要立刻反映在畫面上, 所以統一走這裡
  Future<void> savePref(Future<void> Function() write) async {
    await write();
    notifyListeners();
  }

  // ------------------------------------------------------------------- 開機

  Future<void> refreshAll() async {
    booting = true;
    await _libraryDir();
    // 上次的片庫跟片單先擺上去: 開機畫面後面已經有東西了, 網路回來再換掉
    seedCachedCatalog();
    if (library.isEmpty) {
      library = _cachedLibrary();
      _indexLibrary();
    }
    notifyListeners();
    await _loadSession();
    await Future.wait([
      refreshLibrary(),
      refreshCatalog(),
      refreshWatchTimes(),
    ]);
    booting = false;
    notifyListeners();
  }

  /// 還沒設定伺服器位址時走這條 —— 沒有東西可以抓, 直接把開機畫面收掉.
  void finishBoot() {
    booting = false;
    notifyListeners();
  }

  Future<void> _loadSession() async {
    if (!hasServer) {
      offline = true;
      return;
    }
    try {
      serverInfo = await client.serverInfo();
      offline = false;
      lastError = '';
    } catch (error) {
      offline = true;
      lastError = error.toString();
      currentUser = null;
      return;
    }

    if (!serverInfo.userControl) {
      currentUser = null;
      return;
    }
    currentUser = await client.currentUser();
    if (currentUser == null && client.token != null) {
      // token 過期了
      await prefs.clearToken();
      client.token = null;
    }
  }

  Future<void> refreshLibrary() async {
    if (offline || !hasServer) {
      library = downloads.asVideoItems();
      _indexLibrary();
      notifyListeners();
      return;
    }
    try {
      // 帶著上次的 ETag 去問. 沒有新集數的話伺服器只回一個 304, 手上那份原封
      // 不動 —— 四千集的片庫是 2.7 MB, 每次開 app 重抓一遍太浪費了.
      final fresh = await client.videoListIfChanged(await _libraryEtag());
      if (fresh.notModified && library.isNotEmpty) {
        lastError = '';
        notifyListeners();
        return;
      }
      final body = fresh.body;
      if (body != null) {
        library = AgpClient.parseVideoList(jsonDecode(body));
        _indexLibrary();
        // 存伺服器發下來的原文, 不要自己再序列化一次: 省掉一趟 4000 個物件的
        // encode, 而且下次 304 時用的就是同一份 bytes.
        unawaited(_saveLibraryCache(body, fresh.etag));
      }
      lastError = '';
    } on ApiException catch (error) {
      if (error.needsLogin) {
        library = const [];
      } else {
        library = _cachedLibrary();
      }
      _indexLibrary();
      lastError = error.message;
    } catch (error) {
      offline = true;
      lastError = error.toString();
      library = _cachedLibrary();
      _indexLibrary();
    }
    notifyListeners();
  }

  // ------------------------------------------------------------- 片庫快取
  //
  // 放檔案不放 SharedPreferences: 那邊是給小設定用的, 塞一份 2.7 MB 的字串
  // 進去等於每次刷新都在主執行緒上寫一次幾 MB 的 XML.

  Directory? _cacheDir;

  Future<Directory> _libraryDir() async =>
      _cacheDir ??= await getApplicationSupportDirectory();

  Future<File> _libraryFile() async =>
      File('${(await _libraryDir()).path}/library.json');

  Future<File> _libraryEtagFile() async =>
      File('${(await _libraryDir()).path}/library.etag');

  Future<String?> _libraryEtag() async {
    try {
      final file = await _libraryEtagFile();
      if (!file.existsSync()) return null;
      // 手上沒有內容的話 ETag 就沒有意義, 拿了只會換到一個沒東西可用的 304
      final body = await _libraryFile();
      if (!body.existsSync()) return null;
      return (await file.readAsString()).trim();
    } catch (_) {
      return null;
    }
  }

  Future<void> _saveLibraryCache(String body, String etag) async {
    try {
      await (await _libraryFile()).writeAsString(body);
      await (await _libraryEtagFile()).writeAsString(etag);
    } catch (_) {
      // 存不下就算了, 下次還是抓得到
    }
  }

  /// 開機時先擺上去的那一份. 同步讀 —— 開機路徑上不值得為它多轉一次事件圈.
  List<VideoItem> _cachedLibrary() {
    try {
      final dir = _cacheDir;
      if (dir != null) {
        final file = File('${dir.path}/library.json');
        if (file.existsSync()) {
          final cached =
              AgpClient.parseVideoList(jsonDecode(file.readAsStringSync()));
          if (cached.isNotEmpty) return cached;
        }
      }
    } catch (_) {
      // 壞掉就當作沒有
    }
    // 舊版是存在 SharedPreferences 裡的, 讀得到就沿用, 下一次刷新會搬到檔案
    final raw = prefs.readCachedJson('library');
    if (raw is List) {
      final cached = raw
          .whereType<Map>()
          .map((e) => VideoItem.fromJson(e.cast<String, dynamic>()))
          .toList();
      if (cached.isNotEmpty) return cached;
    }
    return downloads.asVideoItems();
  }

  Future<void> refreshCatalog() async {
    if (offline || !hasServer) return;
    try {
      final json = await client.catalogIndexJson();
      catalog = CatalogIndex.fromJson(json);
      unawaited(prefs.cacheJson('catalog', json));
    } catch (_) {
      // 片單是站上的東西, 抓不到就用上次那份, 首頁不必為此空一塊
    }
    notifyListeners();
  }

  /// 冷啟動時先把上次的片單畫出來, 不必等 /catalog/index.json 回來.
  /// 伺服器那邊本來就是一小時才重爬一次, 這份不會差到哪去.
  void seedCachedCatalog() {
    if (catalog.season.isNotEmpty || catalog.hot.isNotEmpty) return;
    final raw = prefs.readCachedJson('catalog');
    if (raw is! Map) return;
    catalog = CatalogIndex.fromJson(raw.cast<String, dynamic>());
  }

  Future<void> refreshWatchTimes() async {
    if (offline || !hasServer || (serverInfo.userControl && !loggedIn)) {
      watchTimes = const {};
      notifyListeners();
      return;
    }
    try {
      watchTimes = await client.allWatchTimes();
    } catch (_) {
      watchTimes = const {};
    }
    notifyListeners();
  }

  /// 起 (或取得) 影片快取. 起不來就回 null, 呼叫端直接連伺服器.
  Future<VideoCacheServer?> ensureVideoCache() async {
    final running = videoCache;
    if (running != null) {
      if (!running.closed && await running.healthy()) return running;
      // 切到背景時被系統收掉了, 重起一台 (磁碟上那些塊還在, 不受影響)
      videoCache = null;
      _videoCacheBoot = null;
      await running.close();
    }
    return _videoCacheBoot ??= () async {
      final dir = Directory('${(await getApplicationSupportDirectory()).path}'
          '/video-cache');
      _videoCacheDir = dir;
      final server = await VideoCacheServer.start(dir);
      videoCache = server;
      return server;
    }();
  }

  Directory? _videoCacheDir;

  /// 影片快取現在佔多少
  Future<int> videoCacheBytes() async {
    final dir = _videoCacheDir;
    if (dir == null || !dir.existsSync()) return 0;
    var total = 0;
    try {
      await for (final item in dir.list(recursive: true)) {
        if (item is File) total += (await item.stat()).size;
      }
    } catch (_) {
      // 掃到一半被改也沒關係, 這只是拿來顯示的
    }
    return total;
  }

  /// 把影片快取整個丟掉. 已經下載到手機的那些集數不受影響 —— 它們在別的目錄.
  Future<void> clearVideoCache() async {
    final server = videoCache;
    videoCache = null;
    _videoCacheBoot = null;
    if (server != null) await server.close();
    final dir = _videoCacheDir;
    try {
      if (dir != null && dir.existsSync()) await dir.delete(recursive: true);
    } catch (_) {
      // 有檔案正被讀就留著, 下次再清
    }
  }

  WatchTime? watchTimeOf(String sn) => watchTimes[sn];

  void noteWatchTime(String sn, WatchTime value) {
    final next = Map<String, WatchTime>.from(watchTimes);
    next[sn] = value;
    watchTimes = next;
    notifyListeners();
  }

  Future<void> forgetWatchTime(String sn) async {
    try {
      await client.deleteWatchTime(sn);
    } catch (_) {
      // 伺服器沒收到也先把畫面更新掉, 下次同步會補回來
    }
    final next = Map<String, WatchTime>.from(watchTimes)..remove(sn);
    watchTimes = next;
    notifyListeners();
  }

  // ------------------------------------------------------------------- 帳號

  Future<void> login(String username, String password) async {
    final token = await client.login(username, password);
    await prefs.setToken(token);
    await refreshAll();
  }

  Future<void> logout() async {
    await client.logout();
    await prefs.clearToken();
    currentUser = null;
    watchTimes = const {};
    await refreshAll();
  }

  // ------------------------------------------------------------------- 收藏

  bool isFavourite(String? name, [String? alias]) =>
      prefs.isFavourite(name, alias);

  Future<bool> toggleFavourite(Favourite entry) async {
    final added = await prefs.toggleFavourite(entry);
    notifyListeners();
    return added;
  }

  List<Favourite> get favourites => prefs.favourites;

  // ------------------------------------------------------------------- 片庫

  VideoItem? videoOf(String sn) => _libraryIndex[sn];

  void _indexLibrary() {
    final index = <String, VideoItem>{};
    for (final video in library) {
      index.putIfAbsent(video.sn, () => video);
    }
    _libraryIndex = index;
  }

  // ------------------------------------------------------------- 劇集表快取

  /// 播放頁的作品資訊 / 選集. 落盤留一份, 下次開同一集時先畫出來再去對答案 ——
  /// 這一段本來是空白等著 /watch/series.json 回來.
  static const Duration _seriesCacheTtl = Duration(days: 3);

  SeriesInfo? cachedSeries(String sn) {
    final memo = client.seriesJsonCached(sn);
    if (memo != null) return SeriesInfo.fromJson(memo);

    final raw = prefs.readCachedJson('series-$sn');
    if (raw is! Map) return null;
    final saved = raw.cast<String, dynamic>();
    final at = int.tryParse('${saved['_cachedAt']}') ?? 0;
    if (at > 0 &&
        DateTime.now().millisecondsSinceEpoch - at >
            _seriesCacheTtl.inMilliseconds) {
      return null;
    }
    client.seedSeriesJson(sn, saved);
    return SeriesInfo.fromJson(saved);
  }

  Future<SeriesInfo> loadSeries(String sn) async {
    final json = await client.seriesJson(sn);
    unawaited(prefs.cacheJson('series-$sn', {
      ...json,
      '_cachedAt': DateTime.now().millisecondsSinceEpoch,
    }));
    return SeriesInfo.fromJson(json);
  }

  /// 同一部作品的其他集數 (依 sn 排序, 跟網頁版一樣)
  List<VideoItem> episodesOf(String animeName) {
    final list = library.where((v) => v.animeName == animeName).toList();
    list.sort((a, b) =>
        (int.tryParse(a.sn) ?? 0).compareTo(int.tryParse(b.sn) ?? 0));
    return list;
  }

  /// 片庫裡有幾部作品 (首頁那幾個區塊都是以「部」為單位)
  List<VideoItem> get animeHeads {
    final seen = <String>{};
    final heads = <VideoItem>[];
    for (final video in library) {
      final key = video.displayName;
      if (key.isEmpty || seen.contains(key)) continue;
      seen.add(key);
      heads.add(video);
    }
    return heads;
  }

  /// 首頁的「繼續觀看」
  List<VideoItem> get continueWatching {
    final rows = <MapEntry<VideoItem, WatchTime>>[];
    for (final entry in watchTimes.entries) {
      final video = videoOf(entry.key);
      if (video == null) continue;
      if (entry.value.ended) continue;
      if (entry.value.time <= 0) continue;
      rows.add(MapEntry(video, entry.value));
    }
    rows.sort((a, b) => b.value.timestamp.compareTo(a.value.timestamp));
    return rows.map((e) => e.key).toList();
  }

  /// 送出一個手動任務 (加入下載 / 邊看邊下載)
  Future<void> startServerDownload(
    String sn, {
    String resolution = '1080',
    String mode = 'single',
    bool danmu = true,
    bool classify = true,
    int thread = 1,
  }) async {
    await client.manualTask(
      sn: sn,
      resolution: resolution,
      mode: mode,
      danmu: danmu,
      classify: classify,
      thread: thread,
    );
  }
}
