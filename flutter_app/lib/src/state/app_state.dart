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
import 'download_network.dart';
import 'prefs.dart';
import 'thumbnails.dart';
import 'video_cache.dart';

class AppState extends ChangeNotifier {
  AppState._(this.prefs, {AgpClient? api})
      : client = api ??
            AgpClient(
              baseUrl: prefs.server,
              token: prefs.token.isEmpty ? null : prefs.token,
            ) {
    downloads = DownloadStore(client);
    thumbnails = ThumbnailStore(client);
  }

  static AppState? _instance;
  static AppState get instance {
    final value = _instance;
    if (value == null) throw StateError('AppState.boot() 還沒跑完');
    return value;
  }

  static Future<AppState> boot({AgpClient? client}) async {
    final prefs = await Prefs.load();
    final state = AppState._(prefs, api: client);
    _instance = state;
    state.downloadNetwork = DownloadNetwork(state.downloads);
    await state.downloadNetwork.start(wifiOnly: prefs.downloadWifiOnly);
    await state.downloads.init(concurrency: prefs.downloadConcurrency);
    return state;
  }

  final Prefs prefs;
  final AgpClient client;
  late final DownloadStore downloads;
  late final DownloadNetwork downloadNetwork;

  Future<void> setDownloadWifiOnly(bool value) async {
    await prefs.setDownloadWifiOnly(value);
    await downloadNetwork.setWifiOnly(value);
    notifyListeners();
  }

  /// 封面/縮圖的來源表與落盤快取
  late final ThumbnailStore thumbnails;

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
      serverInfo.userControl &&
      serverInfo.onlineWatchRequiresLogin &&
      !loggedIn;

  /// 這台伺服器到底有沒有在替我們存進度.
  ///
  /// 伺服器上的觀看進度是掛在「使用者」底下的 (userdata.json 的
  /// users[].videotimes), 所以 user_control 關掉的時候根本沒有這回事:
  /// /watch/time 的每一條路都走到最後那個「找不到這個 token 的使用者」分支.
  /// 而那個分支回的是 HTTP 200, 裡面才寫著 403 —— 客戶端看狀態碼是看不出來的.
  ///
  /// config-sample.json 裡 user_control.enabled 是 false, 也就是出廠預設.
  bool get watchTimesAreServerBacked => serverInfo.userControl;

  /// 現在可以跟伺服器對進度嗎
  bool get canSyncWatchTimes =>
      hasServer && !offline && watchTimesAreServerBacked && loggedIn;

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
    // 封面清單也要在第一次 build 之前備好: cachedFile() 是同步的, 目錄還沒
    // 準備好的話熱的封面會白白閃一格漸層
    await thumbnails.init();
    // 上次的片庫跟片單先擺上去: 開機畫面後面已經有東西了, 網路回來再換掉
    seedCachedCatalog();
    if (library.isEmpty) {
      library = _cachedLibrary();
      _indexLibrary();
    }
    // 進度也一樣先從磁碟撿回來 —— 而且要在 _loadSession() 之前, 下面補送欠帳
    // 的時候才知道欠了哪幾筆
    await _loadCachedWatchTimes();
    notifyListeners();
    await _loadSession();
    if (!offline) {
      // 回到線上: 等伺服器抓的那幾集現在可能好了, 缺的彈幕也再問一次
      unawaited(downloads.pollWaiting());
      unawaited(downloads.retryMissingDanmaku());
    }
    // 離線時記的進度先補送出去, 下面 refreshWatchTimes() 的合併才會看到
    // 伺服器補完之後的狀態, 不然剛送上去的那幾筆會被舊值蓋回來
    await flushPendingWatchTimes();
    await Future.wait([
      refreshLibrary(),
      refreshCatalog(),
      refreshWatchTimes(),
      thumbnails.refresh(),
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
      thumbnails.seedCatalog(
          [...catalog.season, ...catalog.hot, ...catalog.newAdded]);
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
    thumbnails
        .seedCatalog([...catalog.season, ...catalog.hot, ...catalog.newAdded]);
  }

  // ----------------------------------------------------------- 觀看進度
  //
  // 進度以前只活在記憶體裡: 飛航模式下看的那幾分鐘, app 一關就沒了, 而且伺服器
  // 永遠不會知道 —— 因為離線那條路連送都沒送. 現在跟片庫一樣落盤 (watch-times
  // .json), 另外記一組「還欠伺服器」的 sn, 回到線上再補送.

  final Set<String> _pendingWatchTimes = <String>{};
  bool _watchTimesLoaded = false;
  Timer? _watchTimesWrite;

  Future<File> _watchTimesFile() async =>
      File('${(await _libraryDir()).path}/watch-times.json');

  /// 磁碟那份併回記憶體. 整支 app 只做一次 (換帳號時重來).
  Future<void> _loadCachedWatchTimes() async {
    if (_watchTimesLoaded) return;
    _watchTimesLoaded = true;
    Map<String, dynamic> raw;
    try {
      final file = await _watchTimesFile();
      if (!file.existsSync()) return;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return;
      raw = decoded.cast<String, dynamic>();
    } catch (_) {
      return; // 壞掉就當作沒有, 下一次寫入會蓋掉它
    }
    final merged = Map<String, WatchTime>.from(watchTimes);
    raw.forEach((sn, value) {
      if (value is! Map) return;
      final json = value.cast<String, dynamic>();
      if (json['dirty'] == true) _pendingWatchTimes.add(sn);
      final entry = WatchTime.fromJson(json);
      final mine = merged[sn];
      // 這一輪已經在看的那一集比檔案新, 別把它蓋回去
      if (mine == null || entry.timestamp >= mine.timestamp) merged[sn] = entry;
    });
    watchTimes = merged;
  }

  Future<void> _saveWatchTimes() async {
    _watchTimesWrite?.cancel();
    _watchTimesWrite = null;
    try {
      final payload = <String, dynamic>{};
      watchTimes.forEach((sn, value) {
        payload[sn] = {
          ...value.toJson(),
          if (_pendingWatchTimes.contains(sn)) 'dirty': true,
        };
      });
      await (await _watchTimesFile()).writeAsString(jsonEncode(payload));
    } catch (_) {
      // 寫不進去就算了, 下一次進度更新會再試一遍
    }
  }

  /// 進度每 10 秒就更新一次, 每次都寫檔太吵 —— 合併成一秒一次.
  void _scheduleWatchTimesSave() {
    _watchTimesWrite?.cancel();
    _watchTimesWrite =
        Timer(const Duration(seconds: 1), () => unawaited(_saveWatchTimes()));
  }

  /// 立刻落盤. 播放器被切到背景 / 關掉時走這條, 等不了 debounce.
  ///
  /// 排在後面那一次要取消掉: 內容都已經寫過了, 留著只是多寫一次, 而且
  /// 播放器關掉之後那個 timer 還醒著 —— widget test 會直接判它失敗.
  Future<void> flushWatchTimesToDisk() {
    _watchTimesWrite?.cancel();
    _watchTimesWrite = null;
    return _saveWatchTimes();
  }

  bool isWatchTimePending(String sn) => _pendingWatchTimes.contains(sn);

  bool get hasPendingWatchTimes => _pendingWatchTimes.isNotEmpty;

  /// 送出去失敗了 —— 把這一筆標回欠帳, 不用重寫整個 entry.
  void markWatchTimePending(String sn) {
    if (!watchTimes.containsKey(sn)) return;
    if (!_pendingWatchTimes.add(sn)) return;
    _scheduleWatchTimesSave();
  }

  /// 把離線 (或送出去失敗) 時記下的進度補給伺服器.
  Future<void> flushPendingWatchTimes() async {
    if (_pendingWatchTimes.isEmpty || !canSyncWatchTimes) return;
    final sent = <String>[];
    for (final sn in _pendingWatchTimes.toList()) {
      final value = watchTimes[sn];
      if (value == null) {
        sent.add(sn); // 已經被刪掉了, 這筆欠帳跟著銷掉
        continue;
      }
      try {
        await client.setWatchTime(sn, value.time,
            ended: value.ended,
            duration: value.duration > 0 ? value.duration : null);
        sent.add(sn);
      } catch (_) {
        // 這一筆還欠著, 下次再送 —— 但別因為一筆失敗就放掉後面的
      }
    }
    if (sent.isEmpty) return;
    _pendingWatchTimes.removeAll(sent);
    await _saveWatchTimes();
  }

  /// 進度是跟著帳號走的, 換人 (或登出) 就整份丟掉.
  Future<void> _clearWatchTimes() async {
    _watchTimesWrite?.cancel();
    _watchTimesWrite = null;
    watchTimes = const {};
    _pendingWatchTimes.clear();
    _watchTimesLoaded = false;
    try {
      final file = await _watchTimesFile();
      if (file.existsSync()) await file.delete();
    } catch (_) {
      // 刪不掉就算了, 下次登入時的合併頂多多幾筆別人的紀錄
    }
  }

  Future<void> refreshWatchTimes() async {
    // 本機那份永遠先擺上去 —— 離線時它就是全部, 不能像以前那樣清成空的
    await _loadCachedWatchTimes();
    // 伺服器沒在替我們存進度的話, 本機這份就是唯一的一份: 底下那段合併會把
    // 「伺服器上沒有」讀成「在別台裝置上刪掉了」, 而 user_control 關掉的伺服器
    // 對每一筆查詢都回空的 —— 於是每次重整都把整份進度清光.
    if (!canSyncWatchTimes) {
      notifyListeners();
      return;
    }
    Map<String, WatchTime> remote;
    try {
      remote = await client.allWatchTimes();
    } catch (_) {
      notifyListeners();
      return; // 抓不到就繼續用本機那份
    }
    final merged = Map<String, WatchTime>.from(watchTimes);
    remote.forEach((sn, value) {
      // 還欠伺服器的那幾筆一律以本機為準: 伺服器手上那份正是舊的
      if (_pendingWatchTimes.contains(sn)) return;
      final mine = merged[sn];
      if (mine == null || value.timestamp >= mine.timestamp) merged[sn] = value;
    });
    // 伺服器沒有、本機也不欠它的, 是在別台裝置上刪掉的紀錄
    merged.removeWhere(
        (sn, _) => !remote.containsKey(sn) && !_pendingWatchTimes.contains(sn));
    watchTimes = merged;
    unawaited(_saveWatchTimes());
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

  /// 記一筆進度.
  ///
  /// pending = 伺服器還沒收到這一筆 (離線, 或送出去失敗), 之後 flushPending
  /// WatchTimes() 要補送.
  ///
  /// notify = false 只給播放中每十秒那一筆用: 那時候畫面上只有播放頁, 而
  /// AppState 一通知, 壓在底下的首頁、片庫、紀錄五個分頁全部要重建一次 ——
  /// 看一集就是一百多次沒人看得到的重建. 離開播放頁時再用
  /// [watchTimesChanged] 補一次通知.
  void noteWatchTime(String sn, WatchTime value,
      {bool pending = false, bool notify = true}) {
    final next = Map<String, WatchTime>.from(watchTimes);
    next[sn] = value;
    watchTimes = next;
    if (pending) {
      _pendingWatchTimes.add(sn);
    } else {
      _pendingWatchTimes.remove(sn);
    }
    _scheduleWatchTimesSave();
    if (notify) notifyListeners();
  }

  /// 之前用 notify: false 記的進度, 現在讓其它頁面知道
  void watchTimesChanged() => notifyListeners();

  Future<void> forgetWatchTime(String sn) async {
    try {
      await client.deleteWatchTime(sn);
    } catch (_) {
      // 伺服器沒收到也先把畫面更新掉, 下次同步會補回來
    }
    final next = Map<String, WatchTime>.from(watchTimes)..remove(sn);
    watchTimes = next;
    _pendingWatchTimes.remove(sn);
    unawaited(_saveWatchTimes());
    notifyListeners();
  }

  // ------------------------------------------------------------------- 帳號

  Future<void> login(String username, String password) async {
    final token = await client.login(username, password);
    await prefs.setToken(token);
    // 進度是一個帳號一份, 換人登入別把上一個人的紀錄合併進來
    await _clearWatchTimes();
    await refreshAll();
  }

  Future<void> logout() async {
    await client.logout();
    await prefs.clearToken();
    currentUser = null;
    await _clearWatchTimes();
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
    list.sort(
        (a, b) => (int.tryParse(a.sn) ?? 0).compareTo(int.tryParse(b.sn) ?? 0));
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

  /// 每部作品最後看的是哪一集, 鍵是小寫的作品名.
  ///
  /// 片庫裡的集數直接認; 片庫以外的靠觀看紀錄頁存下來的 history-names
  /// (sn -> 作品名 / 集數), 所以線上看過、沒下載的作品在「所有動畫」也標得出來.
  Map<String, LastWatched> get lastWatchedByAnime {
    final names = prefs.readCachedJson('history-names');
    final result = <String, LastWatched>{};
    for (final entry in watchTimes.entries) {
      final video = videoOf(entry.key);
      String name;
      String episode;
      if (video != null) {
        name = video.displayName;
        episode = video.episode;
      } else if (names is Map && names[entry.key] is Map) {
        final remote = names[entry.key] as Map;
        name = '${remote['name'] ?? ''}';
        episode = '${remote['episode'] ?? ''}';
      } else {
        continue;
      }
      final key = name.trim().toLowerCase();
      if (key.isEmpty) continue;
      final mine = result[key];
      if (mine != null && mine.time.timestamp >= entry.value.timestamp) continue;
      result[key] = LastWatched(
          sn: entry.key, episode: episode, time: entry.value, video: video);
    }
    return result;
  }

  /// 首頁的「繼續觀看」—— 一部作品一格, 只放最後看的那一集.
  /// 最後那一集已經看完的作品就不列 (不能拿更早之前沒看完的某一集來頂替,
  /// 那只會把人帶回已經跳過的地方).
  List<VideoItem> get continueWatching {
    final rows = <LastWatched>[];
    for (final last in lastWatchedByAnime.values) {
      if (last.video == null) continue;
      if (last.time.ended) continue;
      if (last.time.time <= 0) continue;
      rows.add(last);
    }
    rows.sort((a, b) => b.time.timestamp.compareTo(a.time.timestamp));
    return rows.map((e) => e.video!).toList();
  }

  Future<void> addSeriesToSnList(String sn) async {
    await client.addSnToList(sn, mode: 'all');
  }

  /// 送出一個立即執行的手動任務 (單集下載 / 邊看邊下載)
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

/// 某部作品最後看的一集. video 只有在那一集在片庫裡時才有.
class LastWatched {
  const LastWatched(
      {required this.sn, required this.episode, required this.time, this.video});

  final String sn;
  final String episode;
  final WatchTime time;
  final VideoItem? video;
}
