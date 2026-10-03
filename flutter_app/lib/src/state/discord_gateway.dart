import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

const discordApplicationId = '1555902211140231211';

class DiscordPlayback {
  const DiscordPlayback(
      {required this.sn,
      required this.title,
      required this.episode,
      required this.position,
      required this.duration,
      required this.playing,
      this.rate = 1,
      this.image = ''});
  final String sn, title, episode, image;
  final double position, duration, rate;
  final bool playing;

  Map<String, dynamic> activity(DateTime now) {
    String trim(String s) => String.fromCharCodes(s.runes.take(128));
    final speed = rate.isFinite && rate > 0 ? rate : 1.0;
    final pos = position.isFinite ? max(0.0, position) : 0.0;
    final length = duration.isFinite ? max(0.0, duration) : 0.0;
    return {
      'name': 'aniGamerPlus',
      'application_id': discordApplicationId,
      'type': 3,
      'details': trim(title),
      'state': trim(playing ? episode : '$episode · 已暫停'),
      if (playing && length > pos)
        'timestamps': {
          'start': now.millisecondsSinceEpoch - (pos / speed * 1000).round(),
          'end': now.millisecondsSinceEpoch +
              ((length - pos) / speed * 1000).round(),
        },
      if (image.isNotEmpty)
        'assets': {'large_image': image, 'large_text': trim(title)},
    };
  }
}

/// A playback-only Gateway connection; errors never include credential payloads.
class DiscordGateway extends ChangeNotifier {
  DiscordGateway(
      {Future<WebSocket> Function(String)? connect,
      this.updateInterval = const Duration(seconds: 5),
      this.reconnectDelay = const Duration(seconds: 2)})
      : _connect = connect ?? WebSocket.connect;
  final Future<WebSocket> Function(String) _connect;
  final Duration updateInterval, reconnectDelay;
  WebSocket? _socket;
  Timer? _heartbeat, _retry, _hello, _flush, _idle;
  String _token = '', _session = '', _resumeUrl = '';
  int? _sequence;
  int _generation = 0, _failures = 0;
  bool _awaitingAck = false, _ready = false, _disposed = false;
  bool _opening = false;
  bool _sentOnce = false;
  bool invalidToken = false;
  String status = '尚未連線';
  DiscordPlayback? _playback, _sent;
  DateTime _sentAt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastWrite = DateTime.fromMillisecondsSinceEpoch(0);

  void _status(String text) {
    if (status == text || _disposed) return;
    status = text;
    notifyListeners();
  }

  void setToken(String token) {
    if (_token == token) return;
    disconnect();
    _token = token;
    invalidToken = false;
    _session = '';
    _resumeUrl = '';
    _sequence = null;
    if (_playback != null && token.isNotEmpty) unawaited(_open());
  }

  void update(DiscordPlayback value) {
    _idle?.cancel();
    _idle = null;
    _playback = value;
    if (_token.isEmpty || invalidToken) return;
    if (_socket == null && _retry == null) unawaited(_open());
    _queue();
  }

  void stopPlayback() {
    if (_playback == null && _idle != null) return;
    _playback = null;
    _queue();
    if (_socket == null && !_opening && _retry == null) return;
    _idle?.cancel();
    _idle = Timer(const Duration(seconds: 30), disconnect);
  }

  Future<void> _open() async {
    if (_disposed ||
        _opening ||
        _socket != null ||
        _token.isEmpty ||
        invalidToken ||
        _playback == null) {
      return;
    }
    _opening = true;
    final generation = _generation;
    _status('連線中');
    try {
      final pending = _connect(_resumeUrl.isEmpty
          ? 'wss://gateway.discord.gg/?v=10&encoding=json'
          : _resumeUrl);
      final socket =
          await pending.timeout(const Duration(seconds: 15), onTimeout: () {
        unawaited(pending.then((s) => s.close()).catchError((Object _) {}));
        throw TimeoutException('gateway');
      });
      if (generation != _generation || _disposed) {
        unawaited(socket.close());
        return;
      }
      _socket = socket;
      socket.listen((data) => _message(generation, data),
          onDone: () => _closed(generation, socket.closeCode),
          onError: (Object _) => _closed(generation, null),
          cancelOnError: true);
      _hello = Timer(const Duration(seconds: 15), () => _reconnect());
    } catch (_) {
      if (generation == _generation) _closed(generation, null);
    } finally {
      if (generation == _generation) _opening = false;
    }
  }

  void _send(int op, dynamic data) {
    try {
      _socket?.add(jsonEncode({'op': op, 'd': data}));
    } catch (_) {
      _reconnect();
    }
  }

  void _beat() {
    if (_awaitingAck) {
      _reconnect();
      return;
    }
    _awaitingAck = true;
    _send(1, _sequence);
  }

  void _identify() => _send(2, {
        'token': _token,
        'capabilities': 65,
        'compress': false,
        'properties': {
          'os': Platform.operatingSystem,
          'browser': 'Discord Client',
          'device': 'aniGamerPlus'
        },
      });

  void _message(int generation, dynamic raw) {
    if (generation != _generation || raw is! String) return;
    try {
      final message = jsonDecode(raw);
      if (message is! Map) return;
      if (message['s'] is int) _sequence = message['s'];
      final d = message['d'];
      switch (message['op']) {
        case 10:
          _hello?.cancel();
          if (d is! Map || d['heartbeat_interval'] is! num) return;
          final ms = (d['heartbeat_interval'] as num).toInt();
          if (ms < 10 || ms > 300000) {
            _reconnect();
            return;
          }
          _heartbeat?.cancel();
          _awaitingAck = false;
          _heartbeat = Timer(Duration(milliseconds: Random().nextInt(ms)), () {
            _beat();
            _heartbeat =
                Timer.periodic(Duration(milliseconds: ms), (_) => _beat());
          });
          if (_session.isNotEmpty && _sequence != null) {
            _send(
                6, {'token': _token, 'session_id': _session, 'seq': _sequence});
          } else {
            _identify();
          }
          // READY/RESUMED is also bounded; a silent peer cannot strand playback.
          _hello = Timer(const Duration(seconds: 15), () => _reconnect());
        case 11:
          _awaitingAck = false;
        case 1:
          _send(1, _sequence);
        case 7:
          _reconnect(delay: const Duration(seconds: 1));
        case 9:
          if (d != true) {
            _session = '';
            _sequence = null;
            _resumeUrl = '';
          }
          _reconnect(delay: Duration(seconds: 1 + Random().nextInt(5)));
        case 0:
          if (message['t'] == 'READY' && d is Map) {
            _session = d['session_id'] is String ? d['session_id'] : '';
            final url = Uri.tryParse('${d['resume_gateway_url'] ?? ''}');
            if (url != null &&
                url.scheme == 'wss' &&
                (url.host == 'gateway.discord.gg' ||
                    url.host.endsWith('.discord.gg')) &&
                url.userInfo.isEmpty &&
                !url.hasPort) {
              _resumeUrl = url
                  .replace(path: '/', query: 'v=10&encoding=json')
                  .toString();
            }
            _connected();
          } else if (message['t'] == 'RESUMED') {
            _connected();
          }
      }
    } catch (_) {/* Ignore malformed frames without echoing them. */}
  }

  void _connected() {
    _hello?.cancel();
    _ready = true;
    _failures = 0;
    _sent = null;
    _sentOnce = false;
    _status('已連線');
    _queue();
  }

  bool _changed(DateTime now) {
    if (!_sentOnce) return true;
    final current = _playback, last = _sent;
    if (current == null || last == null) return current != last;
    final expected = last.position +
        (last.playing
            ? now.difference(_sentAt).inMilliseconds / 1000 * last.rate
            : 0);
    return current.sn != last.sn ||
        current.title != last.title ||
        current.episode != last.episode ||
        current.image != last.image ||
        current.playing != last.playing ||
        current.rate != last.rate ||
        (current.duration - last.duration).abs() > 1 ||
        (current.position - expected).abs() > 2;
  }

  void _queue() {
    if (!_ready || _flush != null || !_changed(DateTime.now())) return;
    final remaining = updateInterval - DateTime.now().difference(_lastWrite);
    _flush = Timer(remaining.isNegative ? Duration.zero : remaining, () {
      _flush = null;
      if (!_ready || !_changed(DateTime.now())) return;
      final now = DateTime.now();
      _send(3, {
        'activities': [if (_playback != null) _playback!.activity(now)],
        'afk': true,
        'since': null,
        'status': 'online'
      });
      _sent = _playback;
      _sentOnce = true;
      _sentAt = now;
      _lastWrite = now;
    });
  }

  void _closed(int generation, int? code) {
    if (generation != _generation || _disposed) return;
    if (code == 4004) {
      disconnect();
      invalidToken = true;
      _status('Discord 登入已失效，請重新登入');
      return;
    }
    if (code == 4007 || code == 4009) {
      _session = '';
      _sequence = null;
      _resumeUrl = '';
    }
    _reconnect();
  }

  void _reconnect({Duration? delay}) {
    disconnect(keepRetry: true);
    if (_disposed || _playback == null || _token.isEmpty || invalidToken) {
      return;
    }
    _status('等待重新連線');
    final backoff = delay ?? reconnectDelay * (1 << min(_failures++, 5));
    _retry = Timer(backoff, () {
      _retry = null;
      unawaited(_open());
    });
  }

  void disconnect({bool keepRetry = false}) {
    _generation++;
    _opening = false;
    _ready = false;
    _awaitingAck = false;
    _heartbeat?.cancel();
    _hello?.cancel();
    _flush?.cancel();
    _retry?.cancel();
    _heartbeat = null;
    _hello = null;
    _flush = null;
    _retry = null;
    if (!keepRetry) {
      _idle?.cancel();
      _idle = null;
      _status('待播放');
    }
    final socket = _socket;
    _socket = null;
    unawaited(socket?.close(1000));
    _sent = null;
  }

  @override
  void dispose() {
    _disposed = true;
    disconnect();
    _token = '';
    _playback = null;
    super.dispose();
  }
}
