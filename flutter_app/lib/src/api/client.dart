/// 對 aniGamerPlus+ 伺服器的所有請求都走這裡.
///
/// 這支 app 跟 ios/ 底下那層 WKWebView 外殼是同一種東西: 它不是第二個
/// 下載器, 巴哈那邊的解析、AES、ffmpeg 合併全部留在 Python 那側. 這裡只是
/// 把同一組 HTTP 端點改成原生畫面.
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'models.dart';

class ApiException implements Exception {
  final int statusCode;
  final String message;

  ApiException(this.statusCode, this.message);

  bool get needsLogin => statusCode == 401 || statusCode == 403;

  @override
  String toString() => message;
}

/// 一份存活到過期為止的答案. 同一次開機裡重複問同一件事的都走這裡.
class _Memo<T> {
  _Memo(this.value) : at = DateTime.now();

  final T value;
  final DateTime at;

  bool fresh(Duration ttl) => DateTime.now().difference(at) < ttl;
}

class AgpClient {
  AgpClient({required String baseUrl, this.token}) : _base = _normalize(baseUrl);

  String _base;
  String? token;

  final http.Client _http = http.Client();

  /// 劇集表跟可選畫質在一次觀看裡會被問很多次: 開播放頁一次, 換一集再一次,
  /// 觀看紀錄那一頁又一次. 內容幾乎不會在這段時間裡變, 伺服器端也已經在快取,
  /// 這裡再攔一層純粹是為了省掉來回的那段延遲.
  static const Duration _seriesTtl = Duration(minutes: 10);
  static const Duration _sourcesTtl = Duration(minutes: 5);

  final Map<String, _Memo<Map<String, dynamic>>> _seriesMemo = {};
  final Map<String, _Memo<List<int>>> _sourcesMemo = {};

  /// 換伺服器或換帳號之後手上這份就不算數了
  void clearMemo() {
    _seriesMemo.clear();
    _sourcesMemo.clear();
  }

  static String _normalize(String raw) {
    var text = raw.trim();
    if (text.isEmpty) return text;
    if (!text.startsWith('http://') && !text.startsWith('https://')) {
      text = 'http://$text';
    }
    while (text.endsWith('/')) {
      text = text.substring(0, text.length - 1);
    }
    return text;
  }

  String get baseUrl => _base;

  set baseUrl(String value) {
    _base = _normalize(value);
    clearMemo();
  }

  bool get hasServer => _base.isNotEmpty;

  Map<String, String> get authHeaders =>
      (token == null || token!.isEmpty) ? const {} : {'Cookie': 'token=$token'};

  Uri uri(String path, [Map<String, dynamic>? query]) {
    final clean = path.startsWith('/') ? path : '/$path';
    final parsed = Uri.parse('$_base$clean');
    if (query == null || query.isEmpty) return parsed;
    return parsed.replace(queryParameters: {
      for (final entry in query.entries)
        if (entry.value != null) entry.key: entry.value.toString(),
    });
  }

  // ---------------------------------------------------------------- 播放來源

  /// 完成檔. 支援 Range, 下載器也是打這一支.
  Uri videoUrl(String sn, {int? resolution}) => uri('/get_video.mp4', {
        'id': sn,
        if (resolution != null && resolution > 0) 'res': resolution,
      });

  /// 邊看邊下載: 還沒合併完的那一集是一份 EVENT playlist
  Uri hlsPlaylistUrl(String sn) => uri('/hls/playlist.m3u8', {'id': sn});

  /// 線上切換畫質: 伺服器現去動畫瘋要那個畫質的 HLS, 代理成一份 VOD playlist.
  /// 片庫裡一集只留一種畫質, 所以這是換畫質唯一的來源.
  Uri streamPlaylistUrl(String sn, int resolution) =>
      uri('/stream/playlist.m3u8', {'id': sn, 'res': resolution});

  /// 這一集在動畫瘋那邊還有哪些畫質. 由高到低.
  ///
  /// 失敗一律回空陣列而不是丟例外: 舊版伺服器根本沒有這條路由, 那種情況該退化成
  /// 「沒有畫質可選」, 不是在播放頁上彈一條錯誤.
  Future<List<int>> streamSources(String sn) async {
    final memo = _sourcesMemo[sn];
    if (memo != null && memo.fresh(_sourcesTtl)) return memo.value;
    try {
      final data = await _json('/stream/sources.json', {'id': sn});
      final raw = (data as Map)['resolutions'];
      if (raw is! List) return const [];
      final list = raw
          .map((value) => int.tryParse(value.toString()) ?? 0)
          .where((value) => value > 0)
          .toList();
      // 空陣列不留: 那通常是解析當下失敗, 不是這一集真的只有一種畫質
      if (list.isNotEmpty) _sourcesMemo[sn] = _Memo(list);
      return list;
    } catch (_) {
      return const [];
    }
  }

  Uri thumbnailUrl(String sn) => uri('/thumbnail.jpg', {'id': sn});

  Uri danmuUrl(String sn) => uri('/get_danmu.ass', {'id': sn});

  // -------------------------------------------------------------------- 基礎

  Future<http.Response> _get(String path, [Map<String, dynamic>? query]) async {
    final response = await _http.get(uri(path, query), headers: authHeaders);
    return response;
  }

  Never _fail(http.Response response) {
    var message = '伺服器回應 ${response.statusCode}';
    try {
      final body = jsonDecode(response.body);
      if (body is Map && body['error'] != null) message = body['error'].toString();
      if (body is Map && body['message'] != null) message = body['message'].toString();
    } catch (_) {
      // 不是 JSON, 用預設訊息就好
    }
    throw ApiException(response.statusCode, message);
  }

  Future<dynamic> _json(String path, [Map<String, dynamic>? query]) async {
    final response = await _get(path, query);
    if (response.statusCode >= 400) _fail(response);
    if (response.bodyBytes.isEmpty) return null;
    return jsonDecode(utf8.decode(response.bodyBytes));
  }

  Future<dynamic> _postJson(String path, Object body) async {
    final response = await _http.post(
      uri(path),
      headers: {
        ...authHeaders,
        'Content-Type': 'application/json; charset=utf-8',
      },
      body: jsonEncode(body),
    );
    if (response.statusCode >= 400) _fail(response);
    if (response.bodyBytes.isEmpty) return null;
    try {
      return jsonDecode(utf8.decode(response.bodyBytes));
    } catch (_) {
      return utf8.decode(response.bodyBytes);
    }
  }

  // ------------------------------------------------------------------ 伺服器

  Future<ServerInfo> serverInfo() async {
    final data = await _json('/get_server_info');
    return ServerInfo.fromJson((data as Map).cast<String, dynamic>());
  }

  // -------------------------------------------------------------------- 片庫

  Future<List<VideoItem>> videoList() async {
    final data = await _json('/video_list.json');
    return parseVideoList(data);
  }

  static List<VideoItem> parseVideoList(dynamic data) {
    if (data is! Map) return const [];
    final videos = (data['videos'] as List?) ?? [];
    return videos
        .whereType<Map>()
        .map((e) => VideoItem.fromJson(e.cast<String, dynamic>()))
        .toList();
  }

  /// 片庫加上 ETag 條件請求.
  ///
  /// 這是開機時最重的一筆: 四千集的片庫是 2.7 MB 的 JSON. 伺服器現在會給
  /// ETag, 所以沒有新集數時這一趟就只是一個 304 —— 手上那份原封不動繼續用,
  /// 不必再傳一次, 也不必再解析一次.
  ///
  /// 回傳的 body 為 null 表示「沒變, 用你手上那份」.
  Future<({String? body, String etag, bool notModified})> videoListIfChanged(
      String? etag) async {
    final response = await _http.get(
      uri('/video_list.json'),
      headers: {
        ...authHeaders,
        if (etag != null && etag.isNotEmpty) 'If-None-Match': etag,
      },
    );
    if (response.statusCode == 304) {
      return (body: null, etag: etag ?? '', notModified: true);
    }
    if (response.statusCode >= 400) _fail(response);
    return (
      body: utf8.decode(response.bodyBytes),
      etag: response.headers['etag'] ?? '',
      notModified: false,
    );
  }

  Future<SeriesInfo> series(String videoSn) async =>
      SeriesInfo.fromJson(await seriesJson(videoSn));

  /// 原始的那份 JSON. 呼叫端要拿去落盤存起來時用這個 —— SeriesInfo 沒有
  /// toJson(), 而且存原樣的話伺服器將來多回幾個欄位也不必改這裡.
  Future<Map<String, dynamic>> seriesJson(String videoSn) async {
    final memo = _seriesMemo[videoSn];
    if (memo != null && memo.fresh(_seriesTtl)) return memo.value;
    final data = await _json('/watch/series.json', {'id': videoSn});
    final map = (data as Map).cast<String, dynamic>();
    _seriesMemo[videoSn] = _Memo(map);
    return map;
  }

  /// 手上這份還新的話直接給, 不新就回 null. 讓畫面先畫得出來, 網路慢的時候
  /// 使用者看到的是上次那份劇集表, 不是一片空白.
  Map<String, dynamic>? seriesJsonCached(String videoSn) {
    final memo = _seriesMemo[videoSn];
    return (memo != null && memo.fresh(_seriesTtl)) ? memo.value : null;
  }

  /// 從落盤的快取把記憶體這一層補回來 (app 剛開起來時)
  void seedSeriesJson(String videoSn, Map<String, dynamic> json) {
    _seriesMemo.putIfAbsent(videoSn, () => _Memo(json));
  }

  Future<Map<String, dynamic>> animeInfo(String videoSn) async {
    final data = await _json('/anime_info', {'id': videoSn});
    return (data as Map).cast<String, dynamic>();
  }

  Future<String> danmakuAss(String sn) async {
    final response = await _get('/get_danmu.ass', {'id': sn});
    if (response.statusCode >= 400) return '';
    return utf8.decode(response.bodyBytes, allowMalformed: true);
  }

  // -------------------------------------------------------------------- 片單

  Future<CatalogIndex> catalogIndex() async =>
      CatalogIndex.fromJson(await catalogIndexJson());

  Future<Map<String, dynamic>> catalogIndexJson() async {
    final data = await _json('/catalog/index.json');
    return (data as Map).cast<String, dynamic>();
  }

  Future<CatalogPage> catalogAll({String query = '', int page = 1}) async {
    final data = await _json('/catalog/all.json', {
      if (query.isNotEmpty) 'q': query,
      'page': page,
    });
    return CatalogPage.fromJson((data as Map).cast<String, dynamic>());
  }

  Future<SeriesInfo> catalogAnime(String animeSn) async {
    final data = await _json('/catalog/anime.json', {'sn': animeSn});
    return SeriesInfo.fromJson((data as Map).cast<String, dynamic>());
  }

  // -------------------------------------------------------------- 觀看進度

  Future<Map<String, WatchTime>> allWatchTimes() async {
    final data = await _json('/watch/time', {'type': 'get'});
    if (data is! Map) return {};
    final result = <String, WatchTime>{};
    data.forEach((key, value) {
      if (value is Map) {
        result[key.toString()] = WatchTime.fromJson(value.cast<String, dynamic>());
      }
    });
    return result;
  }

  Future<WatchTime> watchTime(String sn) async {
    final data = await _json('/watch/time', {'type': 'get', 'sn': sn});
    if (data is! Map) return WatchTime();
    return WatchTime.fromJson(data.cast<String, dynamic>());
  }

  Future<void> setWatchTime(String sn, int seconds,
      {bool ended = false, int? duration}) async {
    await _postJson('/watch/time', {
      'type': 'set',
      'sn': sn,
      'time': seconds,
      'ended': ended,
      if (duration != null && duration > 0) 'duration': duration,
    });
  }

  Future<void> deleteWatchTime(String sn) async {
    await _postJson('/watch/time', {'type': 'del', 'sn': sn});
  }

  // ----------------------------------------------------------------- 邊看邊下

  Future<HlsStatus> hlsStatus(String sn) async {
    final data = await _json('/hls/status.json', {'id': sn});
    if (data is! Map) return HlsStatus();
    return HlsStatus.fromJson(data.cast<String, dynamic>());
  }

  // -------------------------------------------------------------------- 帳號

  /// 回傳 token; 密碼錯的話丟 ApiException.
  ///
  /// /login 成功是一個帶 Set-Cookie 的 302, 失敗是導回 ./login?error=1 ——
  /// 所以要自己攔重導向, 從標頭裡把 token 撿出來.
  Future<String> login(String username, String password) async {
    final request = http.Request('POST', uri('/login'))
      ..followRedirects = false
      ..headers['Content-Type'] = 'application/x-www-form-urlencoded; charset=utf-8'
      ..bodyFields = {'username': username, 'password': password};

    final streamed = await _http.send(request);
    final body = await streamed.stream.bytesToString();

    final cookie = _tokenFromSetCookie(streamed.headers);
    if (cookie != null && cookie.isNotEmpty) {
      token = cookie;
      return cookie;
    }

    final location = streamed.headers['location'] ?? '';
    if (location.contains('error=1')) {
      throw ApiException(401, '帳號或密碼錯誤');
    }
    if (body.contains('alert(')) {
      throw ApiException(400, '伺服器拒絕了這次登入');
    }
    throw ApiException(streamed.statusCode, '登入失敗 (${streamed.statusCode})');
  }

  static String? _tokenFromSetCookie(Map<String, String> headers) {
    // http 套件把多個 Set-Cookie 併成一條字串, 逐段掃比切逗號可靠
    final raw = headers['set-cookie'] ?? headers['Set-Cookie'];
    if (raw == null) return null;
    final match = RegExp(r'(?:^|[,;\s])token=([^;,\s]+)').firstMatch(raw);
    return match?.group(1);
  }

  static const Map<String, String> registerErrors = {
    '1': '這個帳號已經有人用了',
    '2': '兩次輸入的密碼不一致',
    '3': '請把欄位都填滿',
    '4': '帳號只能用 3-20 個英數字或底線',
    '5': '密碼只能用 6-64 個英數字或底線',
  };

  Future<void> register(String username, String pw1, String pw2) async {
    final request = http.Request('POST', uri('/register'))
      ..followRedirects = false
      ..headers['Content-Type'] = 'application/x-www-form-urlencoded; charset=utf-8'
      ..bodyFields = {'username': username, 'pw1': pw1, 'pw2': pw2};

    final streamed = await _http.send(request);
    final body = await streamed.stream.bytesToString();
    final location = streamed.headers['location'] ?? '';

    // 成功是導到 ./login?error=3 (「註冊成功, 請登入」)
    if (location.contains('login')) return;

    final code = RegExp(r'error=(\d)').firstMatch(location)?.group(1);
    if (code != null && registerErrors.containsKey(code)) {
      throw ApiException(400, registerErrors[code]!);
    }
    if (body.contains('註冊功能未啟用')) {
      throw ApiException(403, '這台伺服器沒有開放註冊');
    }
    throw ApiException(streamed.statusCode, '註冊失敗');
  }

  Future<CurrentUser?> currentUser() async {
    if (token == null || token!.isEmpty) return null;
    try {
      final data = await _postJson('/userinfo', {'action': 'get'});
      if (data is Map && data['status'].toString() == '200') {
        return CurrentUser.fromJson(data.cast<String, dynamic>());
      }
    } on ApiException {
      return null;
    }
    return null;
  }

  Future<String> changePassword(String oldPw, String newPw1, String newPw2) async {
    final data = await _postJson('/userinfo', {
      'action': 'changepassword',
      'original_password': oldPw,
      'new_password1': newPw1,
      'new_password2': newPw2,
    });
    final map = (data as Map).cast<String, dynamic>();
    if (map['status'].toString() != '200') {
      throw ApiException(403, map['message']?.toString() ?? '修改失敗');
    }
    return map['message']?.toString() ?? '密碼修改成功!';
  }

  Future<void> logout() async {
    try {
      await _get('/logout');
    } catch (_) {
      // 伺服器連不上也要能在本機登出
    }
    token = null;
    clearMemo();
  }

  // ---------------------------------------------------------------- 用戶管理

  Future<List<ManagedUser>> users() async {
    final response = await _get('/usermanage', {'format': 'json'});
    if (response.statusCode >= 400) _fail(response);
    final body = utf8.decode(response.bodyBytes, allowMalformed: true);

    try {
      final data = jsonDecode(body);
      if (data is Map) {
        return ((data['users'] as List?) ?? [])
            .whereType<Map>()
            .map((e) => ManagedUser.fromJson(e.cast<String, dynamic>()))
            .toList();
      }
    } catch (_) {
      // 不是 JSON, 那就是還沒更新的伺服器丟回來的整頁 HTML —— 往下撈
    }

    // token 過期的話伺服器回的是 302, http 套件預設會自己跟著走, 最後停在
    // 登入頁而且是 200. 那一頁沒有 userlist 這張表, 拿來跟「真的沒有用戶」
    // 分開 —— 不然畫面會說「還沒有任何用戶」, 但其實是沒登入。
    if (!body.contains('id="userlist"')) {
      throw ApiException(401, '需要管理員權限，請重新登入。');
    }
    return _usersFromHtml(body);
  }

  /// format=json 是這份 repo 才有的, 伺服器沒跟著更新的話 /usermanage 回的
  /// 還是整頁 usermanage.html. 那張表每一列長這樣:
  ///
  ///     <tr data-username="alice">
  ///       <td class="font-weight-bold">alice</td>
  ///       <td><select ...><option value="user" selected>user</option>
  ///           <option value="admin" >admin</option></select></td>
  ///       <td>12</td>
  ///
  /// 撈這三格畫面就夠用了. 帳號限英數字底線, 不會有跳脫字元要還原.
  static final RegExp _userRow = RegExp(
    r'<tr[^>]*\sdata-username="([^"]*)"[^>]*>(.*?)</tr>',
    dotAll: true,
    caseSensitive: false,
  );

  /// 沒選到的那個 option 是 `value="admin" >`, 中間不會有 selected
  static final RegExp _adminSelected = RegExp(
    r'<option[^>]*value="admin"[^>]*\bselected\b',
    caseSensitive: false,
  );

  /// 只有觀看紀錄那格是沒有屬性的純數字 td
  static final RegExp _plainNumberCell = RegExp(r'<td>\s*(\d+)\s*</td>');

  static List<ManagedUser> _usersFromHtml(String html) {
    final users = <ManagedUser>[];
    for (final match in _userRow.allMatches(html)) {
      final username = (match.group(1) ?? '').trim();
      if (username.isEmpty) continue;
      final row = match.group(2) ?? '';
      users.add(ManagedUser(
        username: username,
        role: _adminSelected.hasMatch(row) ? 'admin' : 'user',
        videoTimes:
            int.tryParse(_plainNumberCell.firstMatch(row)?.group(1) ?? '') ?? 0,
      ));
    }
    return users;
  }

  Future<String> manageUser(String action,
      {required String username, String? password, String? role}) async {
    final data = await _postJson('/usermanage', {
      'action': action,
      'username': username,
      if (password != null && password.isNotEmpty) 'password': password,
      if (role != null && role.isNotEmpty) 'role': role,
    });
    final map = (data as Map).cast<String, dynamic>();
    if (map['status'].toString() != '200') {
      throw ApiException(400, map['message']?.toString() ?? '操作失敗');
    }
    return map['message']?.toString() ?? 'OK';
  }

  // -------------------------------------------------------------------- 管理

  Future<Map<String, dynamic>> config() async {
    final data = await _json('/data/config.json');
    return (data as Map).cast<String, dynamic>();
  }

  Future<void> uploadConfig(Map<String, dynamic> config) async {
    await _postJson('/uploadConfig', config);
  }

  Future<String> snList() async {
    final response = await _get('/data/sn_list');
    if (response.statusCode >= 400) _fail(response);
    return utf8.decode(response.bodyBytes, allowMalformed: true);
  }

  Future<void> saveSnList(String text) async {
    final response = await _http.post(
      uri('/sn_list'),
      headers: {
        ...authHeaders,
        'Content-Type': 'text/plain; charset=utf-8',
      },
      body: utf8.encode(text),
    );
    if (response.statusCode >= 400) _fail(response);
  }

  /// 手動任務. 首頁的「邊看邊下載」也是打這一支, 只是 mode 固定 single.
  Future<void> manualTask({
    required String sn,
    String resolution = '1080',
    String mode = 'single',
    int thread = 1,
    bool classify = true,
    bool danmu = true,
    bool? autoUpdateDanmu,
    bool? m3u8,
  }) async {
    await _postJson('/manualTask', {
      'sn': sn,
      'resolution': resolution,
      'mode': mode,
      'thread': thread,
      'classify': classify,
      'danmu': danmu,
      if (autoUpdateDanmu != null) 'auto_update_danmu': autoUpdateDanmu,
      if (m3u8 != null) 'm3u8': m3u8,
    });
  }

  Future<void> checkNow() async {
    final response = await _get('/checknow');
    if (response.statusCode >= 400) _fail(response);
  }

  Future<Map<String, dynamic>> consoleCommand(String command) async {
    final data = await _postJson('/console/command', {'command': command});
    if (data is Map) return data.cast<String, dynamic>();
    return {'success': false, 'message': data?.toString() ?? ''};
  }

  Uri tasksProgressUrl() {
    final base = Uri.parse(_base);
    return base.replace(
      scheme: base.scheme == 'https' ? 'wss' : 'ws',
      path: '/data/tasks_progress',
    );
  }

  /// 任務監控的 WebSocket.
  ///
  /// 一定要走 IO 版: 伺服器開了帳號系統的話, /data/tasks_progress 會去讀
  /// cookie 裡的 token, 不是管理員就直接 close. 跨平台的
  /// WebSocketChannel.connect 不收 headers, 帶不了 cookie, 連上就被踢掉,
  /// 畫面永遠停在「連線中斷, 正在重連」。
  WebSocketChannel connectTasksProgress() => IOWebSocketChannel.connect(
        tasksProgressUrl(),
        headers: authHeaders,
      );

  void close() => _http.close();
}
