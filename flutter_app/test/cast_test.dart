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

import 'package:cast_keepalive/cast_keepalive.dart';

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
  TestWidgetsFlutterBinding.ensureInitialized();
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

  group('連線暫時掉了', () {
    Future<(FakeCastBackend, CastController)> start(WidgetTester tester) async {
      final backend = FakeCastBackend();
      final cast = CastController(backend: backend);
      addTearDown(() async {
        cast.dispose();
        await backend.close();
      });
      await cast.warmUp();
      backend.session('tv');
      await tester.pump();
      await cast.load(_media, startAt: 0);
      backend.status(CastPlayback.playing, duration: 1400);
      await tester.pump();
      return (backend, cast);
    }

    testWidgets('一下子就接回來: 不算停止投放, 電視上那一集還認得', (tester) async {
      final (backend, cast) = await start(tester);
      var notified = 0;
      cast.addListener(() => notified++);

      backend.session(null);
      await tester.pump(const Duration(seconds: 2));
      expect(cast.connected, isTrue);
      expect(cast.reconnecting, isTrue);
      expect(cast.media, isNotNull);

      backend.session('tv');
      await tester.pump();
      expect(cast.reconnecting, isFalse);
      expect(cast.media?.sn, '1');
      expect(cast.playback, CastPlayback.playing);
      expect(notified, 2, reason: '掉線、接回來各通知一次');
      await tester.pump(CastController.kSessionGrace);
      expect(cast.connected, isTrue);
    });

    testWidgets('一直沒回來: 寬限期過了才放掉', (tester) async {
      final (backend, cast) = await start(tester);
      backend.session(null);
      await tester.pump(
          CastController.kSessionGrace - const Duration(seconds: 1));
      expect(cast.connected, isTrue);
      await tester.pump(const Duration(seconds: 2));
      expect(cast.connected, isFalse);
      expect(cast.reconnecting, isFalse);
      expect(cast.media, isNull);
    });

    testWidgets('在背景時不下定論 (iOS 會把 App 整個停下來), 回到前景才開始算',
        (tester) async {
      final (backend, cast) = await start(tester);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      backend.session(null);
      await tester.pump(const Duration(minutes: 30));
      expect(cast.connected, isTrue);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump(
          CastController.kSessionGrace - const Duration(seconds: 1));
      expect(cast.connected, isTrue, reason: 'SDK 這時候才正要把 session 接回來');
      await tester.pump(const Duration(seconds: 2));
      expect(cast.connected, isFalse);
    });

    testWidgets('自己按停止投放: 不等寬限期', (tester) async {
      final (_, cast) = await start(tester);
      await cast.disconnect();
      await tester.pump();
      expect(cast.connected, isFalse);
      expect(cast.media, isNull);
    });
  });

  group('播放頁', () {
    late Directory temp;
    late AppState state;
    late LocalPlayer player;
    late FakeCastBackend backend;
    late bool keepAliveSupported;
    final requests = <Uri>[];
    final holds = <bool>[];
    const keepAlive = MethodChannel('agp/cast_keepalive');

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
      holds.clear();
      keepAliveSupported = CastKeepAlive.supported;
      CastKeepAlive.supported = true;
      messenger.setMockMethodCallHandler(keepAlive, (call) async {
        if (call.method == 'hold') holds.add(call.arguments == true);
        return null;
      });
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
      CastKeepAlive.supported = keepAliveSupported;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(keepAlive, null);
      disposeWarmPlayer();
      state.cast.dispose();
      await backend.close();
      await player.closeStreams();
      await deleteTempDir(temp);
    });

    Future<void> boot(WidgetTester tester,
        {bool connected = true, bool twoEpisodes = false}) async {
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
                  },
                  if (twoEpisodes)
                    {
                      'sn': '2',
                      'title': '測試動畫[4]',
                      'anime_name': '測試動畫',
                      'episode': '4',
                      'resolution': 1080,
                    },
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
      await tester.pump(const Duration(seconds: 1));
      expect(find.byKey(const ValueKey('chromecast-panel')), findsOneWidget,
          reason: '可能只是暫時掉線, 先等一下');
      await tester.pump(CastController.kSessionGrace);
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

    /// 換集時會把進度寫進磁碟: 真的 I/O 在假時鐘裡不會自己完成, 得讓它跑一下
    Future<void> settle(WidgetTester tester, bool Function() done) async {
      for (var i = 0; i < 60; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 15)));
        await tester.pump(const Duration(milliseconds: 100));
        if (done()) return;
      }
      fail('等不到下一集交給電視');
    }

    void toBackground(WidgetTester tester) {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    }

    void toForeground(WidgetTester tester) {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    }

    testWidgets('投放中切到背景: 電視播完直接接下一集, App 一直撐在背景',
        (tester) async {
      await boot(tester, twoEpisodes: true);
      await open(tester);
      backend.status(CastPlayback.playing, duration: 1400);
      backend.position(1390);
      await tester.pump(const Duration(milliseconds: 100));
      expect(holds, isEmpty, reason: '在前景不必撐');

      toBackground(tester);
      await tester.pump();
      expect(holds, [true]);

      backend.status(CastPlayback.ended);
      await settle(tester, () => backend.loads.length == 2);
      expect(backend.loads, hasLength(2), reason: '背景裡沒人看倒數, 不必等八秒');
      final next = backend.loads.last;
      expect(next.media.sn, '2');
      expect(next.media.url.queryParameters['ct'], 'T-2');
      expect(next.autoplay, isTrue);
      expect(player.creations, 0, reason: '還是交給電視, 手機上不開播放器');
      expect(state.watchTimeOf('1')?.ended, isTrue);
      expect(holds, [true], reason: '下一集還要接著看, 不能放手');

      toForeground(tester);
      await tester.pump();
      expect(holds, [true, false]);
      expect(find.byKey(const ValueKey('chromecast-panel')), findsOneWidget);
      await leave(tester);
    });

    testWidgets('投放中在前景播完: 照舊倒數八秒才接下一集', (tester) async {
      await boot(tester, twoEpisodes: true);
      await open(tester);
      backend.status(CastPlayback.playing, duration: 1400);
      backend.position(1390);
      await tester.pump(const Duration(milliseconds: 100));

      backend.status(CastPlayback.ended);
      await tester.pump(const Duration(seconds: 2));
      expect(backend.loads, hasLength(1));
      await tester.pump(const Duration(seconds: 7));
      await settle(tester, () => backend.loads.length == 2);
      expect(backend.loads, hasLength(2));
      expect(backend.loads.last.media.sn, '2');
      expect(holds, isEmpty);
      await leave(tester);
    });

    testWidgets('投放中切到背景, 電視暫停了也還撐著; 最後一集播完就放手',
        (tester) async {
      await boot(tester);
      await open(tester);
      backend.status(CastPlayback.playing, duration: 1400);
      await tester.pump(const Duration(milliseconds: 100));
      toBackground(tester);
      await tester.pump();
      backend.status(CastPlayback.paused, duration: 1400);
      await tester.pump(const Duration(milliseconds: 100));
      expect(holds, [true]);

      backend.status(CastPlayback.ended);
      await tester.pump(const Duration(milliseconds: 100));
      expect(holds, [true, false], reason: '沒有下一集, 這一頁沒事可做了');
      toForeground(tester);
      await tester.pump();
      await leave(tester);
    });

    testWidgets('連線暫時掉了 (iOS 退到背景時 SDK 會先暫停 session): 不切回手機, 回來也不重新載入',
        (tester) async {
      await boot(tester);
      await open(tester);
      backend.status(CastPlayback.playing, duration: 1400);
      backend.position(300);
      await tester.pump(const Duration(milliseconds: 100));

      toBackground(tester);
      backend.session(null);
      await tester.pump(const Duration(minutes: 1));
      expect(player.creations, 0);
      expect(find.byKey(const ValueKey('chromecast-panel')), findsOneWidget);

      toForeground(tester);
      await tester.pump(const Duration(seconds: 2));
      backend.session('客廳電視');
      backend.status(CastPlayback.playing, duration: 1400);
      backend.position(362);
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(backend.loads, hasLength(1), reason: '電視上那一集照樣播, 不重新交一次');
      expect(player.creations, 0);
      expect(find.byKey(const ValueKey('chromecast-panel')), findsOneWidget);
      expect(tester.widget<Slider>(find.byType(Slider)).value, 362);
      await tester.pump(CastController.kSessionGrace);
      expect(find.byKey(const ValueKey('chromecast-panel')), findsOneWidget);
      await leave(tester);
    });
  });
}
