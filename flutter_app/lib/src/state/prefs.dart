/// 本機偏好設定. 網頁版用 localStorage, 這裡是 SharedPreferences,
/// 鍵名刻意沿用同一組 (agp-*), 兩邊的行為才對得起來.
library;

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class Favourite {
  final String name;
  final String alias;
  final String sn;
  final int res;
  final String cover;
  final int added;

  Favourite({
    required this.name,
    this.alias = '',
    this.sn = '',
    this.res = 0,
    this.cover = '',
    int? added,
  }) : added = added ?? DateTime.now().millisecondsSinceEpoch;

  factory Favourite.fromJson(Map<String, dynamic> json) => Favourite(
        name: (json['name'] ?? '').toString(),
        alias: (json['alias'] ?? '').toString(),
        sn: (json['sn'] ?? '').toString(),
        res: json['res'] is int ? json['res'] as int : int.tryParse('${json['res']}') ?? 0,
        cover: (json['cover'] ?? '').toString(),
        added: json['added'] is int
            ? json['added'] as int
            : int.tryParse('${json['added']}') ?? 0,
      );

  Map<String, dynamic> toJson() => {
        'name': name,
        'alias': alias,
        'sn': sn,
        'res': res,
        'cover': cover,
        'added': added,
      };

  /// agp-shell.js 的 favSame(): 片庫名或站上名對到一個就算同一部
  bool matches(String? a, String? b) {
    final candidates = <String>{
      if (a != null && a.isNotEmpty) a,
      if (b != null && b.isNotEmpty) b,
    };
    return candidates.contains(name) || (alias.isNotEmpty && candidates.contains(alias));
  }
}

class Prefs {
  Prefs._(this._sp);

  final SharedPreferences _sp;
  static Prefs? _instance;

  static Prefs get instance {
    final value = _instance;
    if (value == null) {
      throw StateError('Prefs.load() 還沒跑完');
    }
    return value;
  }

  static Future<Prefs> load() async {
    _instance ??= Prefs._(await SharedPreferences.getInstance());
    return _instance!;
  }

  // ------------------------------------------------------------------ 伺服器

  static const _kServer = 'agp-server';
  static const _kToken = 'agp-token';
  static const _kServerHistory = 'agp-server-history';

  String get server => _sp.getString(_kServer) ?? '';
  Future<void> setServer(String value) async {
    await _sp.setString(_kServer, value);
    final history = serverHistory.toList()..remove(value);
    history.insert(0, value);
    await _sp.setStringList(_kServerHistory, history.take(8).toList());
  }

  List<String> get serverHistory => _sp.getStringList(_kServerHistory) ?? const [];

  String get token => _sp.getString(_kToken) ?? '';
  Future<void> setToken(String value) => _sp.setString(_kToken, value);
  Future<void> clearToken() => _sp.remove(_kToken);

  // -------------------------------------------------------------- 播放器偏好

  double get volume => _sp.getDouble('agp-volume') ?? 1.0;
  Future<void> setVolume(double value) => _sp.setDouble('agp-volume', value);

  double get brightness => _sp.getDouble('agp-brightness') ?? 1.0;
  Future<void> setBrightness(double value) => _sp.setDouble('agp-brightness', value);

  double get rate => _sp.getDouble('agp-rate') ?? 1.0;
  Future<void> setRate(double value) => _sp.setDouble('agp-rate', value);

  bool get danmakuOn => _sp.getBool('agp-danmaku') ?? true;
  Future<void> setDanmakuOn(bool value) => _sp.setBool('agp-danmaku', value);

  /// 100 / 75 / 50 / 25
  int get danmakuOpacity => _sp.getInt('agp-danmaku-opacity') ?? 100;
  Future<void> setDanmakuOpacity(int value) => _sp.setInt('agp-danmaku-opacity', value);

  /// 1 = 全畫面, 0.75 / 0.5 / 0.25
  double get danmakuArea => _sp.getDouble('agp-danmaku-area') ?? 1.0;
  Future<void> setDanmakuArea(double value) => _sp.setDouble('agp-danmaku-area', value);

  double get danmakuScale => _sp.getDouble('agp-danmaku-scale') ?? 1.0;
  Future<void> setDanmakuScale(double value) => _sp.setDouble('agp-danmaku-scale', value);

  double get danmakuSpeed => _sp.getDouble('agp-danmaku-speed') ?? 1.0;
  Future<void> setDanmakuSpeed(double value) => _sp.setDouble('agp-danmaku-speed', value);

  /// contain / cover / fill
  String get aspect => _sp.getString('agp-aspect') ?? 'contain';
  Future<void> setAspect(String value) => _sp.setString('agp-aspect', value);

  bool get autoNext => _sp.getBool('agp-auto-next') ?? true;
  Future<void> setAutoNext(bool value) => _sp.setBool('agp-auto-next', value);

  /// 線上播放預設用幾 P. 跟 downloadResolution 分開存 —— 一個是「我在這支手機上
  /// 想看多清楚」, 另一個是「我要存多大一份到手機裡」, 常常不是同一個答案
  int get playbackResolution => _sp.getInt('agp-play-res') ?? 1080;
  Future<void> setPlaybackResolution(int value) => _sp.setInt('agp-play-res', value);

  // ------------------------------------------------------------------ 下載器

  /// 手機端要下幾 P
  String get downloadResolution => _sp.getString('agp-dl-res') ?? '1080';
  Future<void> setDownloadResolution(String value) => _sp.setString('agp-dl-res', value);

  bool get downloadDanmaku => _sp.getBool('agp-dl-danmu') ?? true;
  Future<void> setDownloadDanmaku(bool value) => _sp.setBool('agp-dl-danmu', value);

  bool get downloadWifiOnly => _sp.getBool('agp-dl-wifi') ?? false;
  Future<void> setDownloadWifiOnly(bool value) => _sp.setBool('agp-dl-wifi', value);

  int get downloadConcurrency => _sp.getInt('agp-dl-jobs') ?? 1;
  Future<void> setDownloadConcurrency(int value) => _sp.setInt('agp-dl-jobs', value);

  /// 線上播放要不要走本機的影片快取 (把檔頭留在手機上, 下次開快一點).
  ///
  /// 有開關是因為它擋在播放器跟伺服器中間: 萬一在某個網路環境下反而更糟,
  /// 關掉就直連, 不必等新版.
  bool get videoCache => _sp.getBool('agp-video-cache') ?? true;
  Future<void> setVideoCache(bool value) => _sp.setBool('agp-video-cache', value);

  // -------------------------------------------------------------------- 外觀

  /// system / dark / light
  String get themeMode => _sp.getString('agp-theme') ?? 'dark';
  Future<void> setThemeMode(String value) => _sp.setString('agp-theme', value);

  // -------------------------------------------------------------------- 收藏

  static const _kFavs = 'agp-favs';

  List<Favourite> get favourites {
    final raw = _sp.getString(_kFavs);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw);
      if (list is! List) return [];
      return list
          .whereType<Map>()
          .map((e) => Favourite.fromJson(e.cast<String, dynamic>()))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> saveFavourites(List<Favourite> favourites) =>
      _sp.setString(_kFavs, jsonEncode(favourites.map((f) => f.toJson()).toList()));

  bool isFavourite(String? name, [String? alias]) =>
      favourites.any((f) => f.matches(name, alias));

  Future<bool> toggleFavourite(Favourite entry) async {
    final list = favourites;
    final index = list.indexWhere((f) => f.matches(entry.name, entry.alias));
    if (index >= 0) {
      list.removeAt(index);
      await saveFavourites(list);
      return false;
    }
    list.insert(0, entry);
    await saveFavourites(list);
    return true;
  }

  // ------------------------------------------------- 離線時給首頁用的快取

  Future<void> cacheJson(String key, Object value) =>
      _sp.setString('agp-cache-$key', jsonEncode(value));

  dynamic readCachedJson(String key) {
    final raw = _sp.getString('agp-cache-$key');
    if (raw == null || raw.isEmpty) return null;
    try {
      return jsonDecode(raw);
    } catch (_) {
      return null;
    }
  }

  /// 只丟掉離線副本, 帳號、偏好與已下載的影片都不動
  Future<void> clearCache() async {
    final keys =
        _sp.getKeys().where((key) => key.startsWith('agp-cache-')).toList();
    for (final key in keys) {
      await _sp.remove(key);
    }
  }
}
