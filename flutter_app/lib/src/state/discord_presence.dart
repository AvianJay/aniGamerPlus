import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import '../api/client.dart';
import 'discord_crypto.dart';
import 'discord_gateway.dart';
import 'prefs.dart';
import 'tv_remote_client.dart';

class DiscordPresence extends ChangeNotifier {
  DiscordPresence(this.prefs,
      {FlutterSecureStorage? storage,
      DiscordGateway? gateway,
      http.Client? httpClient})
      : _storage = storage ??
            const FlutterSecureStorage(
                iOptions: IOSOptions(
                    accessibility:
                        KeychainAccessibility.first_unlock_this_device)),
        gateway = gateway ?? DiscordGateway(),
        _http = httpClient ?? http.Client() {
    this.gateway.addListener(_changed);
  }
  final Prefs prefs;
  final FlutterSecureStorage _storage;
  final DiscordGateway gateway;
  final http.Client _http;
  String _scope = '', _account = '', _token = '';
  String name = '';
  bool _disposed = false;
  int _generation = 0;
  final Map<String, String> _images = {};
  final Set<String> _imagePending = {};
  bool get linked => _token.isNotEmpty;
  bool get enabled => prefs.discordPresence;
  String get status => gateway.invalidToken
      ? gateway.status
      : !linked
          ? '尚未登入 Discord'
          : !enabled
              ? '已登入，動態已關閉'
              : gateway.status;

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  String get _storageKey =>
      'agp-discord-${sha256.convert(utf8.encode(_scope))}';

  Future<void> useAccount(String server, String username) async {
    final account = username.toLowerCase();
    final scope = '$server\n$account';
    if (_scope == scope) return;
    final generation = ++_generation;
    _scope = scope;
    _account = account;
    _token = '';
    name = '';
    _images.clear();
    _imagePending.clear();
    gateway.setToken('');
    await prefs.setDiscordAccount(account);
    try {
      final raw = await _storage.read(key: _storageKey);
      if (generation != _generation || _disposed) return;
      if (raw != null) {
        final data = jsonDecode(raw);
        if (data is Map && data['token'] is String && data['name'] is String) {
          _token = data['token'];
          name = data['name'];
        }
      }
    } catch (_) {
      /* Locked/unavailable secure storage leaves the feature off. */
    }
    if (generation != _generation || _disposed) return;
    gateway.setToken(enabled ? _token : '');
    _changed();
  }

  /// Validate only the explicitly signed-in account; never log HTTP bodies.
  Future<void> link(String token) async {
    token = token.trim();
    if (token.isEmpty || token.length > 2000 || token.contains(RegExp(r'\s'))) {
      throw ApiException(400, 'Discord 登入資料無效');
    }
    final generation = _generation;
    try {
      final response = await _request('/users/@me', token);
      if (response.statusCode != 200) {
        throw ApiException(response.statusCode, 'Discord 登入失敗，請重新登入');
      }
      final data = jsonDecode(response.body);
      final display = '${data['global_name'] ?? data['username'] ?? 'Discord'}';
      if (generation != _generation) throw ApiException(409, '帳號已變更，請重試');
      await _save(token, String.fromCharCodes(display.runes.take(100)));
    } on ApiException {
      rethrow;
    } catch (_) {
      throw ApiException(503, '無法連上 Discord，請稍後再試');
    }
  }

  Future<void> _save(String token, String display) async {
    final generation = _generation;
    await _storage.write(
        key: _storageKey, value: jsonEncode({'token': token, 'name': display}));
    if (generation != _generation || _disposed) return;
    _token = token;
    name = display;
    _images.clear();
    gateway.setToken(enabled ? token : '');
    _changed();
  }

  Future<http.Response> _request(String path, String token,
      {Object? body}) async {
    final request = http.Request(body == null ? 'GET' : 'POST',
        Uri.parse('https://discord.com/api/v10$path'))
      ..followRedirects = false
      ..headers['Authorization'] = token;
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    return (() async => http.Response.fromStream(await _http.send(request)))()
        .timeout(const Duration(seconds: 15));
  }

  Future<void> setEnabled(bool value) async {
    await prefs.setDiscordPresence(value);
    gateway.setToken(value ? _token : '');
    _changed();
  }

  Future<void> sync(AgpClient client, String password) async {
    if (!linked || _account.isEmpty) {
      throw ApiException(400, '請先登入伺服器與 Discord');
    }
    final generation = _generation;
    final token = _token;
    final probe = AgpClient(baseUrl: client.baseUrl);
    try {
      // Verify it is the server password before creating an unrecoverable blob.
      final session = await probe.login(_account, password);
      if (session != client.token) {
        throw ApiException(403, '請使用目前伺服器帳號的密碼');
      }
    } finally {
      probe.close();
    }
    final envelope = await DiscordCipher.encrypt(token, password, _account);
    if (generation != _generation || _disposed) {
      throw ApiException(409, '帳號已變更，請重試');
    }
    await client.saveDiscordCredentials(envelope);
  }

  Future<bool> unlock(AgpClient client, String password) async {
    if (_account.isEmpty) return false;
    final generation = _generation;
    final envelope = await client.discordCredentials();
    if (envelope == null) return false;
    String token;
    try {
      token = await DiscordCipher.decrypt(envelope, password, _account);
    } catch (_) {
      throw ApiException(403, '無法解鎖 Discord 資料，請確認伺服器密碼');
    }
    if (generation != _generation) throw ApiException(409, '帳號已變更，請重試');
    await link(token);
    return true;
  }

  Future<void> forget(
      {AgpClient? client, bool remote = false, bool bestEffort = false}) async {
    if (remote && client != null) await client.deleteDiscordCredentials();
    ++_generation;
    gateway.setToken('');
    _token = '';
    name = '';
    _images.clear();
    _imagePending.clear();
    _changed();
    try {
      await _storage.delete(key: _storageKey);
    } catch (_) {
      if (!bestEffort) rethrow;
    }
  }

  Future<void> shareWithTv(TvRemoteClient remote) async {
    if (!linked) throw ApiException(400, '請先登入 Discord');
    await remote.shareDiscord(_token, name);
  }

  Future<String?> acceptFromPhone(String token, String display) async {
    try {
      await link(token);
      await setEnabled(true);
      return null;
    } catch (_) {
      return 'Discord 登入失敗，請在手機重新登入後再傳送。';
    }
  }

  void update(
      {required String sn,
      required String title,
      required String episode,
      required double position,
      required double duration,
      required bool playing,
      double rate = 1,
      String cover = ''}) {
    if (!enabled || !linked) return;
    if (cover.isNotEmpty &&
        !_images.containsKey(cover) &&
        _imagePending.add(cover)) {
      unawaited(_resolveImage(cover));
    }
    gateway.update(DiscordPlayback(
        sn: sn,
        title: title,
        episode: episode,
        position: position,
        duration: duration,
        playing: playing,
        rate: rate,
        image: _images[cover] ?? ''));
  }

  Future<void> _resolveImage(String url) async {
    final generation = _generation;
    var image = '';
    try {
      final uri = Uri.tryParse(url);
      if (uri == null || uri.scheme != 'https' || uri.userInfo.isNotEmpty) {
        return;
      }
      final response = await _request(
          '/applications/$discordApplicationId/external-assets', _token,
          body: {
            'urls': [url]
          });
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data is List && data.isNotEmpty && data.first is Map) {
          final path = data.first['external_asset_path'];
          if (path is String && path.startsWith('external/')) {
            image = 'mp:$path';
          }
        }
      }
    } catch (_) {
      /* Artwork failures must never interrupt playback. */
    } finally {
      if (generation == _generation && !_disposed) {
        _images[url] = image;
        _imagePending.remove(url);
      }
    }
  }

  void stopPlayback() => gateway.stopPlayback();

  @override
  void dispose() {
    _disposed = true;
    ++_generation;
    _token = '';
    gateway.removeListener(_changed);
    gateway.dispose();
    _http.close();
    super.dispose();
  }
}
