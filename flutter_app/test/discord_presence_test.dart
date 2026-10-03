import 'dart:convert';
import 'dart:io';

import 'package:agp_mobile/src/state/discord_crypto.dart';
import 'package:agp_mobile/src/api/client.dart';
import 'package:agp_mobile/src/state/discord_gateway.dart';
import 'package:agp_mobile/src/state/discord_presence.dart';
import 'package:agp_mobile/src/state/prefs.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 8));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('Timed out waiting for Gateway');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

class FakeGateway {
  late HttpServer server;
  final sockets = <WebSocket>[];
  final frames = <Map<String, dynamic>>[];
  final urls = <String>[];
  bool ack = true;
  final closing = <WebSocket>{};
  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      sockets.add(socket);
      socket.add(jsonEncode({
        'op': 10,
        'd': {'heartbeat_interval': 100}
      }));
      socket.listen((raw) {
        if (closing.contains(socket) || socket.readyState != WebSocket.open) {
          return;
        }
        final frame =
            (jsonDecode(raw as String) as Map).cast<String, dynamic>();
        frames.add(frame);
        if (frame['op'] == 1 && ack) socket.add(jsonEncode({'op': 11}));
        if (frame['op'] == 2) {
          socket.add(jsonEncode({
            'op': 0,
            's': 42,
            't': 'READY',
            'd': {
              'session_id': 'fake-session',
              'resume_gateway_url': 'wss://gateway.discord.gg'
            }
          }));
        }
        if (frame['op'] == 6) {
          socket.add(jsonEncode({'op': 0, 's': 43, 't': 'RESUMED', 'd': {}}));
        }
      });
    });
  }

  Future<WebSocket> connect(String url) {
    urls.add(url);
    return WebSocket.connect('ws://127.0.0.1:${server.port}/');
  }

  List<Map<String, dynamic>> get presences =>
      frames.where((f) => f['op'] == 3).toList();
  Future<void> close() async {
    closing.addAll(sockets);
    for (final socket in sockets) {
      await socket.close();
    }
    await server.close(force: true);
  }
}

class UnavailableStorage extends FlutterSecureStorage {
  @override
  Future<void> delete(
      {required String key,
      AppleOptions? iOptions,
      AndroidOptions? aOptions,
      LinuxOptions? lOptions,
      WindowsOptions? wOptions,
      WebOptions? webOptions,
      AppleOptions? mOptions}) async {
    throw StateError('storage temporarily unavailable');
  }
}

DiscordPlayback playback({bool playing = true, double position = 120}) =>
    DiscordPlayback(
        sn: '123',
        title: '測試動畫',
        episode: '第 2 集',
        position: position,
        duration: 1440,
        playing: playing);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // Match the existing loopback suites: the binding's 400-response HTTP mock
  // must not intercept the real local auth server used by this integration test.
  HttpOverrides.global = null;

  test('password ciphertext authenticates password, account and tampering',
      () async {
    final envelope = await DiscordCipher.encrypt(
        'fake-discord-credential', 'password123', 'alice');
    expect(jsonEncode(envelope), isNot(contains('fake-discord-credential')));
    expect(await DiscordCipher.decrypt(envelope, 'password123', 'alice'),
        'fake-discord-credential');
    await expectLater(
        DiscordCipher.decrypt(envelope, 'wrong-password', 'alice'),
        throwsA(anything));
    await expectLater(DiscordCipher.decrypt(envelope, 'password123', 'bob'),
        throwsA(anything));
    await expectLater(
        DiscordCipher.decrypt(
            {...envelope, 'iterations': 1}, 'password123', 'alice'),
        throwsFormatException);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('TV credentials use ephemeral encryption and connection binding',
      () async {
    final receiver = await DiscordTransfer.create();
    final envelope = await DiscordTransfer.seal(
        'fake-tv-credential',
        'Test user',
        receiver.publicKey,
        receiver.challenge,
        'tv:phone:pair-secret');
    expect(jsonEncode(envelope), isNot(contains('fake-tv-credential')));
    expect(await receiver.open(envelope, 'tv:phone:pair-secret'),
        (token: 'fake-tv-credential', name: 'Test user'));
    await expectLater(
        receiver.open(envelope, 'tv:other:pair-secret'), throwsA(anything));
    final other = await DiscordTransfer.create();
    await expectLater(
        other.open(envelope, 'tv:phone:pair-secret'), throwsA(anything));
  });

  test(
      'credentials survive restart only for the same server and user, logout erases them',
      () async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    final prefs = await Prefs.load();
    final presence =
        DiscordPresence(prefs, httpClient: MockClient((request) async {
      expect(request.url.host, 'discord.com');
      expect(request.followRedirects, isFalse);
      expect(request.url.path, '/api/v10/users/@me');
      return http.Response(jsonEncode({'username': 'Test user'}), 200);
    }));
    addTearDown(presence.dispose);
    await presence.useAccount('https://server-a', 'alice');
    await presence.link('fake-credential');
    expect(presence.linked, isTrue);
    expect(presence.enabled, isFalse);
    await presence.useAccount('https://server-a', 'bob');
    expect(presence.linked, isFalse);
    await presence.useAccount('https://server-b', 'alice');
    expect(presence.linked, isFalse);
    await presence.useAccount('https://server-a', 'alice');
    expect(presence.linked, isTrue);
    await presence.forget();
    await presence.useAccount('https://server-a', 'bob');
    await presence.useAccount('https://server-a', 'alice');
    expect(presence.linked, isFalse);
  });

  test(
      'server sync sends only ciphertext and unlock restores a signed-in account',
      () async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    final prefs = await Prefs.load();
    Map<String, dynamic>? saved;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final raw = await utf8.decoder.bind(request).join();
      if (request.uri.path == '/login') {
        final form = Uri.splitQueryString(raw);
        if (form['username'] == 'alice' && form['password'] == 'password123') {
          request.response.statusCode = 302;
          request.response.headers.set('location', '/watch');
          request.response.cookies.add(Cookie('token', 'fake-server-session'));
        } else {
          request.response.statusCode = 302;
          request.response.headers.set('location', '/login?error=1');
        }
      } else {
        expect(request.uri.path, '/user/discord');
        expect(request.headers.value('cookie'), 'token=fake-server-session');
        request.response.headers.contentType = ContentType.json;
        if (request.method == 'PUT') {
          expect(raw, isNot(contains('fake-discord-credential')));
          expect(raw, isNot(contains('password123')));
          saved = (jsonDecode(raw) as Map).cast<String, dynamic>();
          request.response.write(jsonEncode({'status': '200'}));
        } else if (request.method == 'DELETE') {
          saved = null;
          request.response.write(jsonEncode({'status': '200'}));
        } else {
          request.response.write(jsonEncode({'credentials': saved}));
        }
      }
      await request.response.close();
    });
    final base = 'http://127.0.0.1:${server.port}';
    final client = AgpClient(baseUrl: base, token: 'fake-server-session');
    final presence = DiscordPresence(prefs,
        httpClient: MockClient((request) async =>
            http.Response(jsonEncode({'username': 'Test user'}), 200)));
    addTearDown(() async {
      presence.dispose();
      client.close();
      await server.close(force: true);
    });
    await presence.useAccount(base, 'alice');
    await presence.link('fake-discord-credential');
    await expectLater(
        presence.sync(client, 'wrong-password'), throwsA(isA<ApiException>()));
    expect(saved, isNull);
    await presence.sync(client, 'password123');
    expect(saved, isNotNull);
    await presence.forget();
    expect(presence.linked, isFalse);
    expect(await presence.unlock(client, 'password123'), isTrue);
    expect(presence.linked, isTrue);
    await presence.forget(client: client, remote: true);
    expect(saved, isNull);
    expect(presence.linked, isFalse);
  });

  test(
      'server logout can clear active credentials when secure storage is unavailable',
      () async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    final presence = DiscordPresence(await Prefs.load(),
        storage: UnavailableStorage(),
        httpClient: MockClient(
            (_) async => http.Response('{"username":"Test user"}', 200)));
    addTearDown(presence.dispose);
    await presence.useAccount('https://server', 'alice');
    await presence.link('fake-credential');
    expect(presence.linked, isTrue);
    await presence.forget(bestEffort: true);
    expect(presence.linked, isFalse);
    await expectLater(presence.forget(), throwsStateError);
  });

  group('Gateway', () {
    late FakeGateway fake;
    late DiscordGateway gateway;
    setUp(() async {
      fake = FakeGateway();
      await fake.start();
      gateway = DiscordGateway(
          connect: fake.connect,
          updateInterval: const Duration(milliseconds: 30),
          reconnectDelay: const Duration(milliseconds: 10));
      gateway.setToken('fake-credential');
    });
    tearDown(() async {
      gateway.dispose();
      await fake.close();
    });

    test('watching payload, integer heartbeat, pause, seek, and clear',
        () async {
      gateway.update(playback());
      await until(() => fake.presences.isNotEmpty);
      final activity = fake.presences.first['d']['activities'][0] as Map;
      expect(activity['application_id'], discordApplicationId);
      expect(activity['type'], 3);
      expect(activity['details'], '測試動畫');
      expect(activity['timestamps']['end'],
          greaterThan(activity['timestamps']['start']));
      expect(fake.presences.first['d']['afk'], isTrue);
      await until(() => fake.frames.any((f) => f['op'] == 1));
      expect(fake.frames.firstWhere((f) => f['op'] == 1)['d'], 42);
      gateway.update(playback(playing: false));
      await until(() => fake.presences.length == 2);
      expect(
          fake.presences.last['d']['activities'][0]['state'], contains('已暫停'));
      expect(fake.presences.last['d']['activities'][0],
          isNot(contains('timestamps')));
      gateway.update(playback(position: 800));
      await until(() => fake.presences.length == 3);
      gateway.stopPlayback();
      await until(() => fake.presences.last['d']['activities'].isEmpty);
    });

    test('coalesces rapid updates and retains the latest playback state',
        () async {
      gateway.update(playback());
      await until(() => fake.presences.isNotEmpty);
      for (var n = 0; n < 20; n++) {
        gateway.update(playback(playing: false, position: n.toDouble()));
      }
      await until(() => fake.presences.length == 2);
      expect(
          fake.presences.last['d']['activities'][0]['state'], contains('已暫停'));
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(fake.presences, hasLength(2));
    });

    test('server reconnect resumes the session and republishes presence',
        () async {
      gateway.update(playback());
      await until(() => fake.presences.isNotEmpty);
      fake.sockets.last.add(jsonEncode({'op': 7}));
      await until(() => fake.frames.any((f) => f['op'] == 6));
      final resume = fake.frames.firstWhere((f) => f['op'] == 6)['d'];
      expect(resume['seq'], 42);
      expect(resume['session_id'], 'fake-session');
      await until(() => fake.presences.length == 2);
    });

    test('non-resumable invalid session identifies anew instead of resuming',
        () async {
      gateway.update(playback());
      await until(() => fake.presences.isNotEmpty);
      fake.sockets.last.add(jsonEncode({'op': 9, 'd': false}));
      await until(
          () => fake.frames.where((frame) => frame['op'] == 2).length == 2);
      expect(fake.frames.where((frame) => frame['op'] == 6), isEmpty);
      await until(() => fake.presences.length == 2);
    });

    test('missing heartbeat ACK reconnects; invalid credential stops retries',
        () async {
      gateway.update(playback());
      await until(() => fake.presences.isNotEmpty);
      fake.ack = false;
      await until(() => fake.sockets.length > 1);
      fake.ack = true;
      fake.closing.add(fake.sockets.last);
      await fake.sockets.last.close(4004);
      await until(() => gateway.invalidToken);
      final connections = fake.urls.length;
      gateway.update(playback());
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(fake.urls, hasLength(connections));
    });
  });
}
