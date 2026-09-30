/// 手機那一端: 找電視、配對、送按鍵.
///
/// 找電視有兩條路, 同時走:
///   * UDP 廣播 —— 快, 但 iOS 沒有 Apple 另外核發的權限就送不出廣播
///   * 把同一個 /24 網段的位址都敲一遍 /remote/info —— 慢一點, 但到哪裡都行
/// 都找不到的話 (電視在別的網段、固定埠被佔走), 還可以手動輸入電視上顯示的位址.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'remote_setup.dart';
import 'tv_remote_protocol.dart';

class TvDiscovery {
  TvDiscovery({
    this.port = kRemotePort,
    this.discoveryPort = kRemoteDiscoveryPort,
  });

  final int port;
  final int discoveryPort;

  /// 找到一台送一台, [timeout] 到了就結束. [probeHosts] / [broadcastTargets]
  /// 給測試指定; 平常從這支手機的網卡推出來.
  Stream<TvDevice> scan({
    Duration timeout = const Duration(seconds: 4),
    List<InternetAddress>? probeHosts,
    List<InternetAddress>? broadcastTargets,
  }) {
    final controller = StreamController<TvDevice>();
    final seen = <String>{};
    void found(TvDevice device) {
      if (controller.isClosed || !seen.add(device.id)) return;
      controller.add(device);
    }

    RawDatagramSocket? udp;
    final client = HttpClient()
      ..connectionTimeout = const Duration(milliseconds: 700);
    var stopped = false;
    Future<void> stop() async {
      if (stopped) return;
      stopped = true;
      udp?.close();
      client.close(force: true);
      if (!controller.isClosed) await controller.close();
    }

    Future<void> run() async {
      final locals = await _localAddresses();
      final targets = broadcastTargets ??
          [
            InternetAddress('255.255.255.255'),
            for (final local in locals) _subnetBroadcast(local),
          ];
      final hosts = probeHosts ??
          [
            for (final local in locals)
              for (var last = 1; last < 255; last++)
                if (last != local.rawAddress[3])
                  InternetAddress.fromRawAddress(
                      Uint8List.fromList([...local.rawAddress.take(3), last])),
          ];
      await Future.wait([
        _broadcast(targets, found, (socket) => udp = socket, () => stopped),
        _probeAll(client, hosts, found, () => stopped),
      ]);
    }

    controller.onCancel = stop;
    Timer(timeout, () => unawaited(stop()));
    // 掃完了也不提早收: 廣播的回音可能還在路上, 等 timeout
    unawaited(run().catchError((Object _) {}));
    return controller.stream;
  }

  /// 手動輸入位址: 問一下那台是不是電視、叫什麼名字
  Future<TvDevice> probe(TvDevice target) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
    try {
      final device = await _info(client, target.host, target.port)
          .timeout(const Duration(seconds: 5));
      if (device == null) {
        throw const RemoteSetupException('那個位址上沒有開著 aniGamerPlus 的電視。');
      }
      return device;
    } on RemoteSetupException {
      rethrow;
    } on SocketException {
      throw const RemoteSetupException(
          '連不上那個位址。確認電視開著 aniGamerPlus，而且跟手機在同一個網路。');
    } on TimeoutException {
      throw const RemoteSetupException('等不到電視回應。');
    } catch (_) {
      throw const RemoteSetupException('那個位址上沒有開著 aniGamerPlus 的電視。');
    } finally {
      client.close(force: true);
    }
  }

  static Future<List<InternetAddress>> _localAddresses() async {
    try {
      final interfaces = await NetworkInterface.list(
          type: InternetAddressType.IPv4, includeLoopback: false);
      return [
        for (final interface in interfaces)
          for (final address in interface.addresses)
            if (RemoteSetupServer.isPrivateAddress(address)) address,
      ];
    } catch (_) {
      return const [];
    }
  }

  /// 不知道子網路遮罩 (dart:io 不給), 照家用最常見的 /24 猜
  static InternetAddress _subnetBroadcast(InternetAddress local) =>
      InternetAddress.fromRawAddress(
          Uint8List.fromList([...local.rawAddress.take(3), 255]));

  Future<void> _broadcast(
    List<InternetAddress> targets,
    void Function(TvDevice) found,
    void Function(RawDatagramSocket) keep,
    bool Function() stopped,
  ) async {
    final RawDatagramSocket socket;
    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    } catch (_) {
      return;
    }
    if (stopped()) {
      socket.close();
      return;
    }
    keep(socket);
    socket.broadcastEnabled = true;
    socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      Datagram? datagram;
      while ((datagram = socket.receive()) != null) {
        final packet = datagram!;
        try {
          final message = jsonDecode(utf8.decode(packet.data));
          if (message is! Map || message['t'] != 'agp-tv') continue;
          final device =
              _device(message.cast<String, dynamic>(), packet.address.address);
          if (device != null) found(device);
        } catch (_) {}
      }
    }, onError: (Object _) {});
    final hello =
        utf8.encode(jsonEncode({'t': 'agp-discover', 'v': kRemoteProtocol}));
    // 送三次: UDP 會掉, 電視的 Wi-Fi 省電模式也可能漏收第一個
    for (var round = 0; round < 3 && !stopped(); round++) {
      for (final target in targets) {
        try {
          socket.send(hello, target, discoveryPort);
        } catch (_) {
          // iOS 沒有廣播權限就是這裡失敗
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 700));
    }
  }

  Future<void> _probeAll(
    HttpClient client,
    List<InternetAddress> hosts,
    void Function(TvDevice) found,
    bool Function() stopped,
  ) async {
    // 一次敲 48 台: 一整個 /24 大約兩三秒
    const batch = 48;
    for (var start = 0; start < hosts.length && !stopped(); start += batch) {
      final slice = hosts.skip(start).take(batch);
      await Future.wait([
        for (final host in slice)
          _info(client, host.address, port)
              .timeout(const Duration(milliseconds: 1500))
              .then((device) {
            if (device != null && !stopped()) found(device);
          }).catchError((Object _) {}),
      ]);
    }
  }

  static Future<TvDevice?> _info(
      HttpClient client, String host, int port) async {
    final request = await client.getUrl(
        Uri(scheme: 'http', host: host, port: port, path: '/remote/info'));
    final response = await request.close();
    if (response.statusCode != 200) {
      await response.drain<void>();
      return null;
    }
    // 只是一小段 JSON; 敲到別的服務回了一大包的話不要整包收下來
    final bytes = <int>[];
    await for (final chunk in response) {
      bytes.addAll(chunk);
      if (bytes.length > 8 * 1024) return null;
    }
    final message = jsonDecode(utf8.decode(bytes));
    if (message is! Map) return null;
    return _device(message.cast<String, dynamic>(), host);
  }

  static TvDevice? _device(Map<String, dynamic> message, String host) {
    if (message['app'] != 'aniGamerPlus') return null;
    final id = '${message['id'] ?? ''}';
    if (id.isEmpty) return null;
    final port = message['port'];
    return TvDevice(
      id: id,
      name: '${message['name'] ?? ''}'.trim().isEmpty
          ? host
          : '${message['name']}'.trim(),
      host: host,
      port: port is int && port > 0 ? port : kRemotePort,
    );
  }
}

enum TvRemotePhase {
  idle,
  connecting,

  /// 電視上顯示了配對碼, 等使用者輸入
  pairing,
  connected,

  /// 連不上、被拒絕、斷線. [TvRemoteClient.message] 說原因
  failed,
}

class TvRemoteClient extends ChangeNotifier {
  TvRemoteClient({
    required this.phoneId,
    required this.phoneName,
    List<TvDevice> saved = const [],
    this.onSavedChanged,
  }) : _saved = List.of(saved);

  final String phoneId;
  final String phoneName;

  /// 記得的電視清單變了, 要落盤
  final Future<void> Function(List<TvDevice> tvs)? onSavedChanged;

  List<TvDevice> _saved;

  /// 連過的電視, 最近的在前面
  List<TvDevice> get saved => List.unmodifiable(_saved);

  TvRemotePhase phase = TvRemotePhase.idle;
  TvDevice? device;
  String message = '';
  int pinAttemptsLeft = 3;

  /// 電視現在連的伺服器、登入的帳號
  String tvServer = '';
  String tvUser = '';

  /// 電視上在播什麼. [playingAt] 是收到的那一刻, 在播的話位置自己往前推
  NowPlaying? playing;
  DateTime playingAt = DateTime.now();

  final StreamController<String> _notices = StreamController.broadcast();

  /// 要在手機上跳出來的一句話 (電視的回覆、斷線原因)
  Stream<String> get notices => _notices.stream;

  WebSocket? _socket;
  int _generation = 0;
  bool _disposed = false;

  bool get connected => phase == TvRemotePhase.connected;

  double get position {
    final now = playing;
    if (now == null) return 0;
    if (!now.playing) return now.position;
    final elapsed = DateTime.now().difference(playingAt).inMilliseconds / 1000;
    final moved = now.position + elapsed;
    return now.duration > 0 ? moved.clamp(0, now.duration).toDouble() : moved;
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  Future<void> connect(TvDevice target) async {
    _drop();
    final generation = ++_generation;
    // 認得這台的話拿之前配對的 token
    final known = _find(target);
    device = known != null
        ? target.copyWith(
            token: target.token.isEmpty ? known.token : null,
            id: target.id.isEmpty ? known.id : null)
        : target;
    phase = TvRemotePhase.connecting;
    message = '';
    playing = null;
    pinAttemptsLeft = 3;
    _changed();
    try {
      final pending =
          WebSocket.connect('ws://${device!.host}:${device!.port}/remote/ws');
      final socket =
          await pending.timeout(const Duration(seconds: 6), onTimeout: () {
        // 逾時之後才連上的那一條也要關掉, 不然就一直掛在那裡
        unawaited(
            pending.then((late) => late.close()).catchError((Object _) {}));
        throw TimeoutException('connect');
      });
      if (generation != _generation) {
        unawaited(socket.close());
        return;
      }
      _socket = socket;
      socket.pingInterval = const Duration(seconds: 5);
      socket.listen(
        (data) => _onMessage(generation, data),
        onDone: () => _onClosed(generation),
        onError: (Object _) => _onClosed(generation),
        cancelOnError: true,
      );
      _send({
        't': 'hello',
        'v': kRemoteProtocol,
        'id': phoneId,
        'name': phoneName,
        'token': device!.token,
      });
    } catch (_) {
      if (generation != _generation) return;
      phase = TvRemotePhase.failed;
      message = '連不上「${target.name}」。確認電視開著 aniGamerPlus，而且跟手機在同一個網路。';
      _changed();
    }
  }

  void submitPin(String pin) => _send({'t': 'pair', 'pin': pin.trim()});

  /// 自己按了中斷
  void disconnect() {
    _drop();
    _generation++;
    phase = TvRemotePhase.idle;
    message = '';
    playing = null;
    _changed();
  }

  void _drop() {
    final socket = _socket;
    _socket = null;
    if (socket != null) unawaited(socket.close());
  }

  Future<void> forget(TvDevice tv) async {
    _saved = [
      for (final known in _saved)
        if (!known.same(tv)) known
    ];
    if (device != null && device!.same(tv)) disconnect();
    await onSavedChanged?.call(saved);
    _changed();
  }

  // ------------------------------------------------------------------ 指令

  void key(RemoteKey key) => _send({'t': 'key', 'k': key.name});

  void text(String value, {bool submit = false}) =>
      _send({'t': 'text', 'value': value, 'submit': submit});

  void play(String sn, {double? at, bool streaming = false}) => _send({
        't': 'play',
        'sn': sn,
        if (at != null && at > 1) 'at': at,
        if (streaming) 'streaming': true,
      });

  void seek(double to) {
    final now = playing;
    if (now != null) {
      // 先在手機上跳過去, 不然進度條會彈回舊的位置等電視回報
      playing = NowPlaying(
        sn: now.sn,
        title: now.title,
        episode: now.episode,
        position: to,
        duration: now.duration,
        playing: now.playing,
      );
      playingAt = DateTime.now();
      _changed();
    }
    _send({'t': 'seek', 'to': to});
  }

  void configure(String server, String token) =>
      _send({'t': 'config', 'server': server, 'token': token});

  void _send(Map<String, dynamic> message) {
    try {
      _socket?.add(jsonEncode(message));
    } catch (_) {}
  }

  // ------------------------------------------------------------------ 回覆

  void _onMessage(int generation, dynamic data) {
    if (generation != _generation || data is! String) return;
    final Map<String, dynamic> message;
    try {
      final decoded = jsonDecode(data);
      if (decoded is! Map) return;
      message = decoded.cast<String, dynamic>();
    } catch (_) {
      return;
    }
    switch (message['t']) {
      case 'welcome':
        device = device!.copyWith(
          id: '${message['id'] ?? device!.id}',
          name: '${message['name'] ?? ''}'.isEmpty
              ? device!.name
              : '${message['name']}',
        );
        tvServer = '${message['server'] ?? ''}';
        tvUser = '${message['user'] ?? ''}';
        phase = TvRemotePhase.connected;
        this.message = '';
        unawaited(_remember(device!));
        _changed();
      case 'pair-required':
        phase = TvRemotePhase.pairing;
        _changed();
      case 'paired':
        device = device!.copyWith(token: '${message['token'] ?? ''}');
      case 'pair-failed':
        final left = message['left'];
        pinAttemptsLeft = left is int ? left : pinAttemptsLeft - 1;
        this.message = '配對碼不對，還可以再試 $pinAttemptsLeft 次。';
        _changed();
      case 'state':
        final raw = message['playing'];
        playing = raw is Map
            ? NowPlaying.fromJson(raw.cast<String, dynamic>())
            : null;
        playingAt = DateTime.now();
        tvServer = '${message['server'] ?? ''}';
        tvUser = '${message['user'] ?? ''}';
        _changed();
      case 'notice':
        final text = '${message['message'] ?? ''}';
        if (text.isNotEmpty) _notices.add(text);
      case 'error':
        this.message = '${message['message'] ?? ''}';
        phase = TvRemotePhase.failed;
        _changed();
    }
  }

  void _onClosed(int generation) {
    if (generation != _generation) return;
    _socket = null;
    if (phase != TvRemotePhase.failed) {
      final wasConnected = phase == TvRemotePhase.connected;
      phase = TvRemotePhase.failed;
      message = wasConnected ? '跟電視的連線中斷了。' : '電視把連線關掉了。';
      if (wasConnected) _notices.add(message);
    }
    playing = null;
    _changed();
  }

  TvDevice? _find(TvDevice target) {
    for (final known in _saved) {
      if (known.same(target)) return known;
    }
    return null;
  }

  Future<void> _remember(TvDevice tv) async {
    _saved = [
      tv,
      for (final known in _saved)
        if (!known.same(tv) &&
            !(known.host == tv.host && known.port == tv.port))
          known,
    ].take(8).toList();
    await onSavedChanged?.call(saved);
  }

  @override
  void dispose() {
    _disposed = true;
    _drop();
    _generation++;
    unawaited(_notices.close());
    super.dispose();
  }
}
