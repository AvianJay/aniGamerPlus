/// 電視那一端: 在區網上等手機連進來遙控.
///
/// 這一層只管連線、配對跟轉送. 真正要動畫面的事 (按鍵、開播放頁、跳對話框)
/// 交給 [TvRemoteActions], 在 app 裡是 pages/tv_remote_actions.dart —— 這樣
/// 測試不必開畫面也驗得到整條協定.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'tv_remote_protocol.dart';

abstract class TvRemoteActions {
  /// 電視現在連的伺服器、登入的帳號 (沒有就是空字串)
  ({String server, String user}) get status;

  void key(RemoteKey key);

  /// 以下三個: 回 null 表示成功, 否則是要顯示在手機上的原因
  Future<String?> text(String value, {required bool submit});
  Future<String?> play(String sn, {double? at, bool streaming = false});
  Future<String?> configure(String server, String token);

  /// 在電視上把配對碼秀出來. [PairingRequest.finished] 變成 true 時自己收掉
  void showPairing(PairingRequest request);

  /// 認得的手機連上來了
  void connected(String phoneName);
}

/// 電視上的播放頁掛上來的: 手機拖進度條時要叫它
abstract class RemotePlayer {
  void seekTo(double seconds);
}

class PairingRequest {
  PairingRequest(this.phoneName, this.pin, void Function() reject)
      : _reject = reject;

  final String phoneName;
  final String pin;
  final void Function() _reject;

  /// 配對結束了 (成功、拒絕、逾時、手機斷線), 顯示配對碼的畫面該收掉
  final ValueNotifier<bool> finished = ValueNotifier<bool>(false);

  /// 電視上按了「拒絕」
  void reject() => _reject();
}

class _Session {
  _Session(this.socket);

  final WebSocket socket;
  String id = '';
  String name = '';
  int failures = 0;
  Timer? helloTimer;

  /// 配對過、認得了才有
  PairedPhone? phone;
}

class TvRemoteHost extends ChangeNotifier {
  TvRemoteHost({
    required this.actions,
    required this.id,
    required this.name,
    List<PairedPhone> paired = const [],
    this.onPairedChanged,
    this.port = kRemotePort,
    this.discoveryPort = kRemoteDiscoveryPort,
    this.pairingCooldown = const Duration(seconds: 30),
    Random? random,
  })  : _paired = List.of(paired),
        _random = random ?? Random.secure();

  /// 電視上正開著的那一台 (設定裡關掉就是 null). 播放頁靠它把進度報給手機
  static TvRemoteHost? current;

  final TvRemoteActions actions;
  final String id;
  final String name;

  /// 配對清單變了, 要落盤
  final Future<void> Function(List<PairedPhone> phones)? onPairedChanged;

  final int port;
  final int discoveryPort;

  /// 配對碼錯太多次之後, 這段時間內不再接受新的配對. 不然同一個人可以一直重連、
  /// 每次換一組新的配對碼猜, 四位數很快就猜中了
  final Duration pairingCooldown;
  DateTime _pairingBlockedUntil = DateTime.fromMillisecondsSinceEpoch(0);

  final Random _random;

  List<PairedPhone> _paired;
  List<PairedPhone> get paired => List.unmodifiable(_paired);

  HttpServer? _server;
  RawDatagramSocket? _udp;
  final Set<_Session> _sessions = {};
  _Session? _pairingSession;
  PairingRequest? _pairing;
  Timer? _pairingTimer;
  bool _disposed = false;

  /// 實際開在哪個埠. 固定的那個被佔走時是系統隨便給的一個
  int boundPort = 0;

  /// 廣播那一個實際開在哪個埠 (沒開成就是 0)
  int get discoveryBoundPort => _udp?.port ?? 0;
  bool get running => _server != null;

  RemotePlayer? _player;
  NowPlaying? _playing;
  NowPlaying? _sent;
  ({String server, String user})? _sentStatus;
  DateTime _sentAt = DateTime.fromMillisecondsSinceEpoch(0);

  static const Duration _pairingTimeout = Duration(minutes: 2);
  static const Duration _helloTimeout = Duration(seconds: 10);
  static const int _maxPinAttempts = 3;
  static const int _maxSessions = 8;
  static const int _maxMessage = 16 * 1024;

  /// 已經連上、認得的手機
  List<String> get connectedPhones => [
        for (final session in _sessions)
          if (session.phone != null) session.phone!.name,
      ];

  bool get hasClients => _sessions.any((session) => session.phone != null);

  Map<String, dynamic> get _info => {
        'app': 'aniGamerPlus',
        'v': kRemoteProtocol,
        'id': id,
        'name': name,
        'port': boundPort,
      };

  // ------------------------------------------------------------------ 開關

  Future<void> start() async {
    if (_server != null) return;
    HttpServer server;
    try {
      server = await HttpServer.bind(InternetAddress.anyIPv4, port);
    } on SocketException {
      // 固定的埠被佔走了: 隨便開一個. 廣播跟手動輸入照樣找得到, 只是掃不到
      server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    }
    _server = server;
    boundPort = server.port;
    server.listen(
      (request) => unawaited(_handle(request)),
      onError: (Object _) {},
    );
    try {
      final udp = await RawDatagramSocket.bind(
          InternetAddress.anyIPv4, discoveryPort,
          reuseAddress: true);
      _udp = udp;
      udp.listen(
        (event) {
          if (event == RawSocketEvent.read) _answerDiscovery(udp);
        },
        onError: (Object _) {},
      );
    } catch (_) {
      // 沒有廣播也還能掃描跟手動輸入
    }
    _changed();
  }

  Future<void> stop() async {
    _endPairing();
    for (final session in _sessions.toList()) {
      session.helloTimer?.cancel();
      unawaited(session.socket.close());
    }
    _sessions.clear();
    _udp?.close();
    _udp = null;
    final server = _server;
    _server = null;
    await server?.close(force: true);
    _changed();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(stop());
    super.dispose();
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  // ------------------------------------------------------------------ 播放頁

  void attachPlayer(RemotePlayer player) => _player = player;

  void detachPlayer(RemotePlayer player) {
    if (_player != player) return;
    _player = null;
    publish(null);
  }

  /// 播放頁一秒報兩次. 沒有手機連著就什麼都不送; 在播的時候手機會自己往前推
  /// 時間, 這裡只在對不上、或狀態變了才送一次.
  void publish(NowPlaying? playing) {
    _playing = playing;
    if (!hasClients) return;
    final last = _sent;
    final now = DateTime.now();
    final bool changed;
    if (playing == null || last == null) {
      changed = playing != last;
    } else {
      final elapsed = now.difference(_sentAt).inMilliseconds / 1000;
      final expected = last.playing ? last.position + elapsed : last.position;
      changed = playing.sn != last.sn ||
          playing.playing != last.playing ||
          playing.title != last.title ||
          playing.episode != last.episode ||
          (playing.duration - last.duration).abs() > 1 ||
          (playing.position - expected).abs() > 1.5 ||
          elapsed > 5;
    }
    if (changed) _broadcastState();
  }

  /// 伺服器 / 帳號可能換了. AppState 一動就會叫, 沒換就不送
  void statusChanged() {
    if (hasClients && actions.status != _sentStatus) _broadcastState();
  }

  /// 在電視上把一支手機移出配對清單. 正連著的話一起斷掉
  Future<void> forget(String phoneId) async {
    _paired = [
      for (final phone in _paired)
        if (phone.id != phoneId) phone
    ];
    await onPairedChanged?.call(paired);
    for (final session in _sessions.toList()) {
      if (session.phone?.id == phoneId) {
        _fail(session, '電視上已經把這支手機移除了。');
      }
    }
    _changed();
  }

  // ------------------------------------------------------------------ 連線

  Future<void> _handle(HttpRequest request) async {
    try {
      // 瀏覽器發的一律不收: 網頁可以對任何位址開 WebSocket, 手機上隨便一個
      // 網頁都能來敲門. App 自己連的不會帶 Origin
      if (request.headers.value('origin') != null) {
        request.response.statusCode = HttpStatus.forbidden;
        await request.response.close();
        return;
      }
      switch (request.uri.path) {
        case '/remote/info':
          request.response
            ..headers.contentType = ContentType.json
            ..write(jsonEncode(_info));
          await request.response.close();
        case '/remote/ws' when WebSocketTransformer.isUpgradeRequest(request):
          if (_sessions.length >= _maxSessions) {
            request.response.statusCode = HttpStatus.serviceUnavailable;
            await request.response.close();
            return;
          }
          _open(await WebSocketTransformer.upgrade(request));
        default:
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
      }
    } catch (_) {
      // 對方中途斷了之類的
    }
  }

  void _open(WebSocket socket) {
    final session = _Session(socket);
    _sessions.add(session);
    socket.pingInterval = const Duration(seconds: 10);
    // 一直不說 hello 的連線不留
    session.helloTimer = Timer(_helloTimeout, () {
      if (session.phone == null && session != _pairingSession) {
        unawaited(socket.close());
      }
    });
    socket.listen(
      (data) => unawaited(_onMessage(session, data)),
      onDone: () => _closed(session),
      onError: (Object _) => _closed(session),
      cancelOnError: true,
    );
  }

  void _closed(_Session session) {
    session.helloTimer?.cancel();
    if (!_sessions.remove(session)) return;
    if (session == _pairingSession) _endPairing();
    _changed();
  }

  void _send(_Session session, Map<String, dynamic> message) {
    try {
      session.socket.add(jsonEncode(message));
    } catch (_) {}
  }

  void _notice(_Session session, String? message) {
    if (message == null || message.isEmpty) return;
    _send(session, {'t': 'notice', 'message': message});
  }

  /// 說明原因, 然後斷線
  void _fail(_Session session, String message) {
    _send(session, {'t': 'error', 'message': message});
    session.helloTimer?.cancel();
    unawaited(session.socket.close());
    _closed(session);
  }

  Future<void> _onMessage(_Session session, dynamic data) async {
    if (data is! String || data.length > _maxMessage) return;
    final Map<String, dynamic> message;
    try {
      final decoded = jsonDecode(data);
      if (decoded is! Map) return;
      message = decoded.cast<String, dynamic>();
    } catch (_) {
      return;
    }
    final type = message['t'];

    // 還不認得的手機: 只能打招呼跟配對
    if (session.phone == null) {
      switch (type) {
        case 'hello':
          _hello(session, message);
        case 'pair':
          await _pair(session, message);
        default:
          _fail(session, '這支手機還沒跟電視配對。');
      }
      return;
    }

    switch (type) {
      case 'key':
        final key = RemoteKey.parse(message['k']);
        if (key != null) actions.key(key);
      case 'text':
        final value = '${message['value'] ?? ''}';
        if (value.length > 500) return;
        _notice(session,
            await actions.text(value, submit: message['submit'] == true));
      case 'play':
        final sn = '${message['sn'] ?? ''}';
        if (!RegExp(r'^\d{1,12}$').hasMatch(sn)) {
          _notice(session, '看不懂要播哪一集。');
          return;
        }
        final at = message['at'];
        _notice(
            session,
            await actions.play(sn,
                at: at is num && at > 0 ? at.toDouble() : null,
                streaming: message['streaming'] == true));
      case 'seek':
        final to = message['to'];
        if (to is! num || to < 0) return;
        final player = _player;
        if (player == null) {
          _notice(session, '電視上沒有在播放。');
          return;
        }
        player.seekTo(to.toDouble());
      case 'config':
        final server = '${message['server'] ?? ''}'.trim();
        final token = '${message['token'] ?? ''}';
        if (server.isEmpty || server.length > 300 || token.length > 300) {
          _notice(session, '伺服器位址不對。');
          return;
        }
        final error = await actions.configure(server, token);
        _notice(session, error ?? '電視已經換上 $server。');
    }
  }

  // ------------------------------------------------------------------ 配對

  void _hello(_Session session, Map<String, dynamic> message) {
    final phoneId = '${message['id'] ?? ''}';
    final phoneName = '${message['name'] ?? ''}'
        .replaceAll(RegExp(r'[\u0000-\u001f]'), '')
        .trim();
    final token = '${message['token'] ?? ''}';
    if (phoneId.isEmpty || phoneId.length > 64) {
      _fail(session, '這支手機沒有報上身分。');
      return;
    }
    session.id = phoneId;
    session.name = phoneName.isEmpty
        ? '手機'
        : phoneName.substring(0, min(phoneName.length, 40));

    for (final phone in _paired) {
      if (phone.id == phoneId && token.isNotEmpty && phone.token == token) {
        _authorize(session, phone);
        return;
      }
    }

    if (_pairing != null) {
      _fail(session, '電視上正在跟另一支手機配對，等一下再試。');
      return;
    }
    if (DateTime.now().isBefore(_pairingBlockedUntil)) {
      _fail(session, '剛剛配對碼錯太多次了，等半分鐘再試。');
      return;
    }
    final pin = _random.nextInt(10000).toString().padLeft(4, '0');
    final request = PairingRequest(session.name, pin, () {
      final pairing = _pairingSession;
      _endPairing();
      if (pairing != null) _fail(pairing, '電視上拒絕了這次配對。');
    });
    session.helloTimer?.cancel();
    _pairing = request;
    _pairingSession = session;
    _pairingTimer = Timer(_pairingTimeout, () {
      final pairing = _pairingSession;
      _endPairing();
      if (pairing != null) _fail(pairing, '配對逾時了，請重新連線。');
    });
    _send(session, {'t': 'pair-required'});
    actions.showPairing(request);
    _changed();
  }

  Future<void> _pair(_Session session, Map<String, dynamic> message) async {
    final request = _pairing;
    if (request == null || session != _pairingSession) {
      _fail(session, '電視沒有在等這支手機配對。');
      return;
    }
    final pin = '${message['pin'] ?? ''}'.trim();
    if (pin != request.pin) {
      session.failures++;
      final left = _maxPinAttempts - session.failures;
      if (left <= 0) {
        _endPairing();
        _pairingBlockedUntil = DateTime.now().add(pairingCooldown);
        _fail(session, '配對碼錯太多次了，請重新連線。');
        return;
      }
      _send(session, {'t': 'pair-failed', 'left': left});
      return;
    }
    final phone = PairedPhone(
      id: session.id,
      name: session.name,
      token: base64Url
          .encode(List<int>.generate(32, (_) => _random.nextInt(256)))
          .replaceAll('=', ''),
      added: DateTime.now().millisecondsSinceEpoch,
    );
    // 同一支手機重新配對: 舊的 token 作廢
    _paired = [
      for (final known in _paired)
        if (known.id != phone.id) known,
      phone,
    ];
    _endPairing();
    await onPairedChanged?.call(paired);
    _send(session, {'t': 'paired', 'token': phone.token});
    _authorize(session, phone);
  }

  void _authorize(_Session session, PairedPhone phone) {
    session.helloTimer?.cancel();
    session.phone = phone;
    final status = actions.status;
    _send(session, {
      't': 'welcome',
      'v': kRemoteProtocol,
      'id': id,
      'name': name,
      'server': status.server,
      'user': status.user,
    });
    _send(session, _state());
    actions.connected(phone.name);
    _changed();
  }

  void _endPairing() {
    _pairingTimer?.cancel();
    _pairingTimer = null;
    final request = _pairing;
    _pairing = null;
    _pairingSession = null;
    request?.finished.value = true;
    _changed();
  }

  // ------------------------------------------------------------------ 狀態

  Map<String, dynamic> _state() {
    final status = actions.status;
    _sentStatus = status;
    return {
      't': 'state',
      'playing': _playing?.toJson(),
      'server': status.server,
      'user': status.user,
    };
  }

  void _broadcastState() {
    final message = _state();
    for (final session in _sessions) {
      if (session.phone != null) _send(session, message);
    }
    _sent = _playing;
    _sentAt = DateTime.now();
  }

  // ------------------------------------------------------------------ 廣播

  void _answerDiscovery(RawDatagramSocket udp) {
    Datagram? datagram;
    while ((datagram = udp.receive()) != null) {
      final packet = datagram!;
      if (packet.data.length > 512) continue;
      try {
        final message = jsonDecode(utf8.decode(packet.data));
        if (message is! Map || message['t'] != 'agp-discover') continue;
        udp.send(utf8.encode(jsonEncode({'t': 'agp-tv', ..._info})),
            packet.address, packet.port);
      } catch (_) {
        // 不是我們的封包
      }
    }
  }
}
