/// 整支 app 共用的狀態: 連的是哪台伺服器、登入的是誰、片庫跟片單的快取.
///
/// 刻意不引入狀態管理套件 —— ChangeNotifier 加 ListenableBuilder 就夠了,
/// 少一個相依就少一次在 CI 上編不過的機會.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../api/client.dart';
import '../api/models.dart';
import 'downloads.dart';
import 'prefs.dart';

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

  /// 連不上伺服器. 這時首頁只剩下載好的那幾集.
  bool offline = false;
  String lastError = '';
  bool booting = true;

  List<VideoItem> library = const [];
  CatalogIndex catalog = CatalogIndex();
  Map<String, WatchTime> watchTimes = const {};

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
      notifyListeners();
      return;
    }
    try {
      library = await client.videoList();
      await prefs.cacheJson('library', library.map((v) => v.toJson()).toList());
      lastError = '';
    } on ApiException catch (error) {
      if (error.needsLogin) {
        library = const [];
      } else {
        library = _cachedLibrary();
      }
      lastError = error.message;
    } catch (error) {
      offline = true;
      lastError = error.toString();
      library = _cachedLibrary();
    }
    notifyListeners();
  }

  List<VideoItem> _cachedLibrary() {
    final raw = prefs.readCachedJson('library');
    if (raw is! List) return downloads.asVideoItems();
    final cached = raw
        .whereType<Map>()
        .map((e) => VideoItem.fromJson(e.cast<String, dynamic>()))
        .toList();
    return cached.isEmpty ? downloads.asVideoItems() : cached;
  }

  Future<void> refreshCatalog() async {
    if (offline || !hasServer) return;
    try {
      catalog = await client.catalogIndex();
    } catch (_) {
      // 片單是站上的東西, 抓不到就先留空, 首頁的片庫區塊照樣畫得出來
    }
    notifyListeners();
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

  VideoItem? videoOf(String sn) {
    for (final video in library) {
      if (video.sn == sn) return video;
    }
    return null;
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
