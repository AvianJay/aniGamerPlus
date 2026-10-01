import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import 'package:wakelock_plus_platform_interface/wakelock_plus_platform_interface.dart';

import 'package:agp_mobile/src/api/client.dart';
import 'package:agp_mobile/src/pages/watch_page.dart';
import 'package:agp_mobile/src/state/app_state.dart';
import 'package:agp_mobile/src/state/cast.dart';
import 'package:agp_mobile/src/util/device.dart';

import 'support/temp_dir.dart';

/// 假的 Google Cast: 記下被叫了什麼, 電視那頭的回報由測試自己送.
class FakeCastBackend implements CastBackend {
  final _devices = StreamController<List<CastDevice>>.broadcast();
  final _sessions = StreamController<String?>.broadcast();
  final _statuses = StreamController<CastRemoteStatus?>.broadcast();
  final _positions = StreamController<double>.broadcast();

  bool initOk = true;
  int discoveryStarts = 0;
  int discoveryStops = 0;
  final loads = <({CastMedia media, double startAt, bool autoplay})>[];
  final calls = <String>[];

  void found(List<CastDevice> devices) => _devices.add(devices);
  void session(String? name) => _sessions.add(name);
  void status(CastPlayback playback, {double? duration, String? contentId}) =>
      _statuses.add(CastRemoteStatus(
          playback: playback, duration: duration, contentId: contentId));
  void position(double seconds) => _positions.add(seconds);

  @override
  Future<bool> initialise() async => initOk;
  @override
  Stream<List<CastDevice>> get devices => _devices.stream;
  @override
  Stream<String?> get sessions => _sessions.stream;
  @override
  Stream<CastRemoteStatus?> get statuses => _statuses.stream;
  @override
  Stream<double> get positions => _positions.stream;
  @override
  Future<void> startDiscovery() async => discoveryStarts++;
  @override
  Future<void> stopDiscovery() async => discoveryStops++;
  @override
  Future<bool> connect(CastDevice device) async {
    calls.add('connect:${device.id}');
    scheduleMicrotask(() => _sessions.add(device.name));
    return true;
  }

  @override
  Future<void> disconnect() async {
    calls.add('disconnect');
    _sessions.add(null);
  }

  @override
  Future<void> load(CastMedia media,
      {required double startAt,
      required bool autoplay,
      required double rate}) async {
    loads.add((media: media, startAt: startAt, autoplay: autoplay));
  }

  @override
  Future<void> play() async => calls.add('play');
  @override
  Future<void> pause() async => calls.add('pause');
  @override
  Future<void> seek(double seconds) async => calls.add('seek:$seconds');
  @override
  Future<void> setRate(double rate) async => calls.add('rate:$rate');

  Future<void> close() async {
    await _devices.close();
    await _sessions.close();
    await _statuses.close();
    await _positions.close();
  }
}

class Paths extends PathProviderPlatform {
  Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
  @override
  Future<String?> getTemporaryPath() async => path;
}

class Wake extends WakelockPlusPlatformInterface {
  @override
  Future<void> toggle({required bool enable}) async {}
}

/// 手機上的播放器. 投放中不該被建出來; 停止投放時才接回來.
class LocalPlayer extends VideoPlayerPlatform {
  final Map<int, StreamController<VideoEvent>> streams = {};
  final seeks = <Duration>[];
  bool playing = false;
  int creations = 0;

  StreamController<VideoEvent> _streamFor(int id) =>
      streams.putIfAbsent(id, () => StreamController<VideoEvent>.broadcast());

  Future<void> closeStreams() async {
    for (final stream in streams.values) {
      await stream.close();
    }
  }

  @override
  Future<void> init() async {}
  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async =>
      ++creations;
  @override
  Stream<VideoEvent> videoEventsFor(int id) {
    final stream = _streamFor(id);
    scheduleMicrotask(() {
      if (stream.isClosed) return;
      stream.add(VideoEvent(
          eventType: VideoEventType.initialized,
          duration: const Duration(seconds: 1400),
          size: const Size(1920, 1080)));
    });
    return stream.stream;
  }

  @override
  Future<void> dispose(int id) async {}
  @override
  Future<void> pause(int id) async => playing = false;
  @override
  Future<void> play(int id) async => playing = true;
  @override
  Future<void> seekTo(int id, Duration position) async => seeks.add(position);
  @override
  Future<Duration> getPosition(int id) async =>
      seeks.isEmpty ? Duration.zero : seeks.last;
  @override
  Future<void> setLooping(int id, bool looping) async {}
  @override
  Future<void> setMixWithOthers(bool value) async {}
  @override
  Future<void> setVolume(int id, double value) async {}
  @override
  Future<void> setPlaybackSpeed(int id, double value) async {}
  @override
  Widget buildView(int id) => const ColoredBox(color: Color(0xFF384054));
}

final _url = Uri.parse('http://server/get_video.mp4?id=1&ct=T');
final _media = CastMedia(
  sn: '1',
  source: 'mp4:1080',
  url: _url,
  contentType: 'video/mp4',
  title: '測試',
);

void main() {
  late bool supported;
  setUp(() {
    supported = CastController.supported;
    CastController.supported = true;
    Device.tv = false;
  });
  tearDown(() => CastController.supported = supported);

  group('CastController', () {
    late FakeCastBackend backend;
    late CastController cast;
    setUp(() {
      backend = FakeCastBackend();
      cast = CastController(backend: backend);
    });
    tearDown(() async {
      cast.dispose();
      await backend.close();
    });

    test('SDK 起不來 (沒有 Google Play 服務) 就整個藏起來', () async {
      backend.initOk = false;
      expect(await cast.warmUp(), isFalse);
      expect(cast.available, isFalse);
    });

    test('電視上沒有投放這回事', () async {
      Device.tv = true;
      expect(await cast.warmUp(), isFalse);
      expect(cast.available, isFalse);
      Device.tv = false;
    });

    test('連線要等裝置真的連上才算', () async {
      await cast.warmUp();
      const tv = CastDevice(id: 'a', name: '客廳電視');
      final ok = await cast.connect(tv);
      expect(ok, isTrue);
      expect(cast.connected, isTrue);
      expect(cast.deviceName, '客廳電視');
      expect(cast.connecting, isNull);
    });

    test('找裝置: 播放頁跟面板各開各關, 最後一個關掉才真的停', () async {
      cast.startDiscovery();
      cast.startDiscovery();
      await pumpEventQueue();
      expect(backend.discoveryStarts, 1);
      cast.stopDiscovery();
      await pumpEventQueue();
      expect(backend.discoveryStops, 0);
      cast.stopDiscovery();
      await pumpEventQueue();
      expect(backend.discoveryStops, 1);
    });

    test('換集那一瞬間, 上一集的「播完了」不算數', () async {
      await cast.warmUp();
      backend.session('tv');
      await pumpEventQueue();
      await cast.load(_media, startAt: 0);
      expect(cast.playback, CastPlayback.loading);

      backend.status(CastPlayback.ended);
      await pumpEventQueue();
      expect(cast.playback, CastPlayback.loading,
          reason: '還沒看到這一集開始動之前的 ended 是上一集的');

      backend.status(CastPlayback.playing, duration: 1400);
      await pumpEventQueue();
      expect(cast.playback, CastPlayback.playing);
      expect(cast.duration, 1400);

      backend.status(CastPlayback.ended);
      await pumpEventQueue();
      expect(cast.playback, CastPlayback.ended);
    });

    test('講的是別支片的狀態一律不理', () async {
      await cast.warmUp();
      backend.session('tv');
      await pumpEventQueue();
      await cast.load(_media, startAt: 0);
      backend.status(CastPlayback.playing,
          contentId: 'http://server/get_video.mp4?id=2');
      await pumpEventQueue();
      expect(cast.playback, CastPlayback.loading);
      backend.status(CastPlayback.playing, contentId: _url.toString());
      await pumpEventQueue();
      expect(cast.playback, CastPlayback.playing);
    });

    test('斷線就把電視上那一集忘掉', () async {
      await cast.warmUp();
      backend.session('tv');
      await pumpEventQueue();
      await cast.load(_media, startAt: 30);
      expect(cast.position.value, 30);
      await cast.disconnect();
      await pumpEventQueue();
      expect(cast.connected, isFalse);
      expect(cast.media, isNull);
      expect(backend.calls, contains('disconnect'));
    });
  });

  group('播放頁', () {
    late Directory temp;
    late AppState state;
    late LocalPlayer player;
    late FakeCastBackend backend;
    final requests = <Uri>[];

    // AppState.boot() 會開 connectivity_plus 的事件流; 測試裡沒有那個外掛
    const connectivity = [
      MethodChannel('dev.fluttercommunity.plus/connectivity'),
      MethodChannel('dev.fluttercommunity.plus/connectivity_status'),
    ];

    setUp(() async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      for (final channel in connectivity) {
        messenger.setMockMethodCallHandler(channel, (call) async {
          return call.method == 'check' ? ['wifi'] : null;
        });
      }
      requests.clear();
      temp = await Directory.systemTemp.createTemp('agp-cast-test-');
      PathProviderPlatform.instance = Paths(temp.path);
      WakelockPlusPlatformInterface.instance = Wake();
      SharedPreferences.setMockInitialValues({
        'agp-server': 'http://localhost:12345',
        // 本機快取會起一台真的 HttpServer, widget test 裡不要它
        'agp-video-cache': false,
      });
      player = LocalPlayer();
      VideoPlayerPlatform.instance = player;
      backend = FakeCastBackend();
    });

    tearDown(() async {
      disposeWarmPlayer();
      state.cast.dispose();
      await backend.close();
      await player.closeStreams();
      await deleteTempDir(temp);
    });

    Future<void> boot(WidgetTester tester, {bool connected = true}) async {
      http.Response reply(Object data) =>
          http.Response.bytes(utf8.encode(jsonEncode(data)), 200);
      final api = AgpClient(
        baseUrl: 'http://localhost:12345',
        httpClient: MockClient((request) async {
          requests.add(request.url);
          switch (request.url.path) {
            case '/cast/ticket':
              return reply({'ticket': 'T-${request.url.queryParameters['id']}'});
            case '/video_list.json':
              return reply({
                'videos': [
                  {
                    'sn': '1',
                    'title': '測試動畫[3]',
                    'anime_name': '測試動畫',
                    'episode': '3',
                    'resolution': 1080,
                  }
                ]
              });
          }
          return http.Response('', 404);
        }),
      );
      addTearDown(api.close);
      state = (await tester.runAsync(() async {
        final booted = await AppState.boot(client: api);
        booted.offline = false;
        await booted.refreshLibrary();
        return booted;
      }))!;
      // 這一段不能放進 runAsync: 投放的事件流在哪個 zone 訂閱, 之後的回報
      // (連線、狀態、位置) 就在哪個 zone 跑, 那樣就不歸假時鐘管了
      state.cast = CastController(backend: backend);
      if (connected) {
        await state.cast.warmUp();
        await state.cast.connect(const CastDevice(id: 'tv', name: '客廳電視'));
      }
    }

    Future<void> open(WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
          MaterialApp(home: WatchPage(state: state, sn: '1')));
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    Future<void> leave(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
    }

    testWidgets('連著 Chromecast 時開播放頁: 這一集交給電視, 網址帶著投放票',
        (tester) async {
      await boot(tester);
      await open(tester);

      expect(backend.loads, hasLength(1));
      final load = backend.loads.single;
      expect(load.media.url.path, '/get_video.mp4');
      expect(load.media.url.queryParameters['ct'], 'T-1');
      expect(load.media.url.queryParameters['res'], '1080');
      expect(load.media.contentType, 'video/mp4');
      expect(load.autoplay, isTrue);
      expect(player.creations, 0, reason: '投放中手機上不開播放器');
      expect(find.byKey(const ValueKey('chromecast-panel')), findsOneWidget);
      expect(find.textContaining('客廳電視'), findsWidgets);
      await leave(tester);
    });

    testWidgets('投放中: 播放鍵、時間軸都在叫電視, 進度跟著電視走', (tester) async {
      await boot(tester);
      await open(tester);

      backend.status(CastPlayback.playing, duration: 1400);
      backend.position(42);
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.widget<Slider>(find.byType(Slider)).value, 42);
      expect(state.watchTimeOf('1')?.time, 42, reason: '投放中進度照記');

      // 播放區有雙擊手勢, 單擊要等雙擊的判定時間過了才算數
      await tester.tap(find.byTooltip('暫停'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(backend.calls, contains('pause'));

      final slider = tester.widget<Slider>(find.byType(Slider));
      slider.onChangeStart!(300);
      slider.onChanged!(300);
      slider.onChangeEnd!(300);
      await tester.pump(const Duration(milliseconds: 100));
      expect(backend.calls, contains('seek:300.0'));
      expect(player.creations, 0);
      await leave(tester);
    });

    testWidgets('停止投放: 從電視停下的地方在手機上暫停著接回來', (tester) async {
      await boot(tester);
      await open(tester);
      backend.status(CastPlayback.playing, duration: 1400);
      backend.position(512);
      await tester.pump(const Duration(milliseconds: 100));

      backend.session(null);
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byKey(const ValueKey('chromecast-panel')), findsNothing);
      expect(player.creations, 1);
      expect(player.seeks.last.inSeconds, 512);
      expect(player.playing, isFalse);
      await leave(tester);
    });

    testWidgets('投放中退出去再回到同一集: 直接接手, 不重新載入', (tester) async {
      await boot(tester);
      await open(tester);
      backend.status(CastPlayback.playing, duration: 1400);
      backend.position(90);
      await tester.pump(const Duration(milliseconds: 100));
      await leave(tester);

      await open(tester);
      expect(backend.loads, hasLength(1));
      expect(tester.widget<Slider>(find.byType(Slider)).value, 90);
      await leave(tester);
    });

    testWidgets('投放鈕只在附近找得到 Chromecast 時出現', (tester) async {
      await boot(tester, connected: false);
      await open(tester);
      expect(find.byTooltip('投放到電視'), findsNothing);

      backend.found(const [CastDevice(id: 'tv', name: '客廳電視')]);
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byTooltip('投放到電視'), findsOneWidget);

      await tester.tap(find.byTooltip('投放到電視'));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      await tester.tap(find.text('客廳電視'));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(backend.calls, contains('connect:tv'));
      expect(backend.loads, hasLength(1), reason: '一連上就把這一集交出去');
      expect(find.byKey(const ValueKey('chromecast-panel')), findsOneWidget);
      await leave(tester);
    });
  });
}
