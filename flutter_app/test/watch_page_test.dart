import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:video_player_pip/index.dart' show VideoPlayerPip;
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import 'package:wakelock_plus_platform_interface/wakelock_plus_platform_interface.dart';
import 'package:agp_mobile/src/api/models.dart';
import 'package:agp_mobile/src/api/client.dart';
import 'package:agp_mobile/src/pages/watch_page.dart';
import 'package:agp_mobile/src/danmaku/danmaku_overlay.dart';
import 'package:agp_mobile/src/state/app_state.dart';
import 'package:agp_mobile/src/state/downloads.dart';
import 'package:agp_mobile/src/theme.dart';
import 'package:agp_mobile/src/state/tv_remote_host.dart';
import 'package:agp_mobile/src/state/tv_remote_protocol.dart';
import 'package:agp_mobile/src/util/device.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/temp_dir.dart';
import 'support/ui_capture.dart';

class Paths extends PathProviderPlatform {
  Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
}

class Wake extends WakelockPlusPlatformInterface {
  @override
  Future<void> toggle({required bool enable}) async {}
}

class _NoActions implements TvRemoteActions {
  @override
  ({String server, String user}) get status => (server: '', user: '');
  @override
  void key(RemoteKey key) {}
  @override
  Future<String?> text(String value, {required bool submit}) async => null;
  @override
  Future<String?> play(String sn, {double? at, bool streaming = false}) async =>
      null;
  @override
  Future<String?> configure(String server, String token) async => null;
  @override
  void showPairing(PairingRequest request) {}
  @override
  void connected(String phoneName) {}
}

/// 電視上那一台遙控伺服器, 只記下播放頁跟它說了什麼
class RecordingHost extends TvRemoteHost {
  RecordingHost() : super(actions: _NoActions(), id: 'tv', name: 'tv');

  RemotePlayer? player;
  final published = <NowPlaying?>[];

  @override
  bool get hasClients => true;

  @override
  void attachPlayer(RemotePlayer player) => this.player = player;

  @override
  void detachPlayer(RemotePlayer player) {
    if (this.player == player) this.player = null;
  }

  @override
  void publish(NowPlaying? playing) => published.add(playing);
}

class DelayedPlayer extends VideoPlayerPlatform {
  // 一個 id 一條事件流, 跟真的平台一樣. 共用一條的話, 第二個 controller 建起來
  // 時第一個 (停在架上等使用者回來的那個) 會收到第二份 initialized, 撞上
  // video_player 內部的 '!initializingCompleter.isCompleted'.
  final Map<int, StreamController<VideoEvent>> streams = {};
  Duration actual = const Duration(seconds: 20);
  Duration duration = const Duration(seconds: 600);
  final seeks = <Duration>[];
  double volume = 1;
  bool playing = false;
  double speed = 1;
  int creations = 0;
  final sources = <VideoCreationOptions>[];
  final disposed = <int>[];
  Completer<void>? disposeBarrier;
  bool failInitialisation = false;
  Uint8List? frame;

  /// 跳轉之後回報「在緩衝」—— 真的播放器跳到沒載過的地方就是這樣
  bool bufferOnSeek = false;

  /// 第一個播放器的那一條. 多數測試只會有這一個.
  StreamController<VideoEvent> get events => _streamFor(1);

  /// 最新建起來的那一個播放器的那一條
  StreamController<VideoEvent> get latest => _streamFor(creations);

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
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    sources.add(options);
    creations++;
    return creations;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int id) {
    final stream = _streamFor(id);
    scheduleMicrotask(() {
      if (stream.isClosed) return;
      if (failInitialisation) {
        stream.addError(PlatformException(code: 'VideoError', message: 'fixture'));
        return;
      }
      stream.add(VideoEvent(
          eventType: VideoEventType.initialized,
          duration: duration,
          size: const Size(1920, 1080)));
    });
    return stream.stream;
  }

  @override
  Future<void> dispose(int id) async {
    final barrier = disposeBarrier;
    if (barrier != null) await barrier.future;
    disposed.add(id);
  }

  @override
  Future<void> pause(int id) async {
    playing = false;
  }

  @override
  Future<void> play(int id) async {
    playing = true;
  }

  @override
  Future<void> seekTo(int id, Duration position) async {
    seeks.add(position);
    if (bufferOnSeek) {
      _streamFor(id).add(VideoEvent(eventType: VideoEventType.bufferingStart));
    }
  }

  @override
  Future<Duration> getPosition(int id) async => actual;
  @override
  Future<void> setLooping(int id, bool looping) async {}
  @override
  Future<void> setMixWithOthers(bool value) async {}
  @override
  Future<void> setVolume(int id, double value) async {
    volume = value;
  }

  @override
  Future<void> setPlaybackSpeed(int id, double value) async {
    speed = value;
  }

  @override
  Widget buildView(int id) => frame == null
      ? const ColoredBox(color: Color(0xFF384054))
      : Image.memory(frame!, fit: BoxFit.cover);
}

/// 假的系統音量與螢幕亮度. 這兩個手勢的重點就是「有沒有真的打到系統那一層」,
/// 所以直接攔在 method channel 上, 把送過去的值收下來驗.
class DeviceLevels {
  double volume = 1;
  double brightness = 1;
  bool reset = false;

  static const _volumeChannel =
      MethodChannel('com.kurenai7968.volume_controller.method');
  static const _brightnessChannel =
      MethodChannel('github.com/aaassseee/screen_brightness');

  void install(WidgetTester tester) {
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_volumeChannel, (call) async {
      switch (call.method) {
        case 'getVolume':
          return volume;
        case 'setVolume':
          volume = (call.arguments as Map)['volume'] as double;
          return null;
      }
      return null;
    });
    messenger.setMockMethodCallHandler(_brightnessChannel, (call) async {
      switch (call.method) {
        case 'getApplicationScreenBrightness':
          return brightness;
        case 'setApplicationScreenBrightness':
          brightness = (call.arguments as Map)['brightness'] as double;
          return null;
        case 'resetApplicationScreenBrightness':
          reset = true;
          return null;
      }
      return null;
    });
  }

  void remove(WidgetTester tester) {
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_volumeChannel, null);
    messenger.setMockMethodCallHandler(_brightnessChannel, null);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await loadCaptureFonts();
    final fonts = Platform.environment['AGP_FONT_DIR'];
    if (fonts != null) {
      for (final entry in {
        'Roboto': 'roboto-regular.ttf',
        'MaterialIcons': 'materialicons-regular.otf'
      }.entries) {
        final loader = FontLoader(entry.key)
          ..addFont(File('$fonts/${entry.value}')
              .readAsBytes()
              .then((bytes) => ByteData.sublistView(bytes)));
        await loader.load();
      }
    }
  });
  late Directory temp;
  late AppState state;
  late DelayedPlayer player;
  late DeviceLevels levels;
  setUp(() async {
    levels = DeviceLevels();
    temp = await Directory.systemTemp.createTemp('agp-player-test-');
    PathProviderPlatform.instance = Paths(temp.path);
    WakelockPlusPlatformInterface.instance = Wake();
    SharedPreferences.setMockInitialValues(
        {'agp-server': 'http://localhost:12345'});
    state = await AppState.boot();
    state.offline = true;
    state.downloads.concurrency = 0;
    await state.prefs.setDownloadAutoDeleteWatched(false);
    player = DelayedPlayer();
    VideoPlayerPlatform.instance = player;
  });
  tearDown(() async {
    // 播放頁離開時會把原生播放器停在架上等使用者回來, 連帶留一個 TTL Timer.
    // 那是正式行為, 但測試結束時不接受還有 Timer 掛著.
    disposeWarmPlayer();
    await player.closeStreams();
    await deleteTempDir(temp);
  });
  Future<void> open(WidgetTester tester,
      {Brightness mode = Brightness.dark, double scale = 1}) async {
    levels.install(tester);
    addTearDown(() => levels.remove(tester));
    await resizeViewport(tester, const Size(1000, 800));
    await tester.pumpWidget(RepaintBoundary(
        key: const ValueKey('capture'),
        child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: captureTheme(buildTheme(brightness: mode)),
            builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(scale)),
                child: child!),
            home: WatchPage(state: state, sn: '1'))));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  void seek(WidgetTester tester, double target) {
    final slider = tester.widget<Slider>(find.byType(Slider));
    slider.onChangeStart!(target);
    slider.onChanged!(target);
    slider.onChangeEnd!(target);
  }

  Future<List<File>> seedDownload(WidgetTester tester, String sn) async {
    // 使用短片，這些檔案生命週期測試不需要載入外部片頭資料。
    player.duration = const Duration(seconds: 120);
    final files = <File>[];
    await tester.runAsync(() async {
      final entry = await state.downloads.enqueue(
          VideoItem(sn: sn, animeName: '測試動畫', episode: sn, resolution: 1080),
          withDanmaku: false);
      entry.status = DownloadStatus.done;
      files.addAll([
        state.downloads.videoFile(entry),
        state.downloads.partFile(entry),
        state.downloads.danmakuFile(sn),
        state.downloads.thumbFile(sn),
      ]);
      for (final file in files) {
        await file.writeAsString('fixture');
      }
    });
    return files;
  }

  Future<void> settleIo(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 60; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 15)));
      await tester.pump(const Duration(milliseconds: 100));
      if (done()) return;
    }
    fail('等待播放器與下載檔案處理完成逾時');
  }

  Future<void> finishEpisode(WidgetTester tester) async {
    player.actual = player.duration;
    player.events.add(VideoEvent(
        eventType: VideoEventType.isPlayingStateUpdate, isPlaying: false));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    expect(state.watchTimeOf('1')?.ended, isTrue);
  }

  testWidgets('看完退出後，先釋放播放器再自動刪除手機影片與附屬檔案', (tester) async {
    await state.prefs.setDownloadAutoDeleteWatched(true);
    final files = await seedDownload(tester, '1');
    final other = await seedDownload(tester, '2');
    await open(tester);
    await settleIo(tester, () => player.playing);
    await finishEpisode(tester);
    expect(files.every((file) => file.existsSync()), isTrue);

    player.disposeBarrier = Completer<void>();
    await tester.pumpWidget(const SizedBox());
    expect(state.watchTimeOf('1')?.ended, isTrue);
    expect(files.every((file) => file.existsSync()), isTrue,
        reason: '原生播放器尚未釋放檔案');
    player.disposeBarrier!.complete();
    await settleIo(tester, () => files.every((file) => !file.existsSync()));
    expect(player.disposed, contains(1));
    expect(state.downloads.entryFor('1'), isNull);
    expect(state.watchTimeOf('1')?.ended, isTrue);
    expect(other.every((file) => file.existsSync()), isTrue);
  });

  for (final scenario in [
    (enabled: false, finished: true),
    (enabled: true, finished: false),
  ]) {
    testWidgets('保留手機影片：自動刪除=${scenario.enabled}，看完=${scenario.finished}',
        (tester) async {
      await state.prefs.setDownloadAutoDeleteWatched(scenario.enabled);
      final files = await seedDownload(tester, '1');
      await open(tester);
      await settleIo(tester, () => player.playing);
      if (scenario.finished) await finishEpisode(tester);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(state.watchTimeOf('1')?.ended, scenario.finished);
      expect(state.downloads.isDownloaded('1'), isTrue);
      expect(files.every((file) => file.existsSync()), isTrue);
    });
  }

  testWidgets('看完後切到下一集也會刪除上一集，保留下一集與看完紀錄', (tester) async {
    await state.prefs.setDownloadAutoDeleteWatched(true);
    final files = await seedDownload(tester, '1');
    final nextFiles = await seedDownload(tester, '2');
    state.client.seedSeriesJson('1', {
      'videoSn': '1',
      'title': '測試動畫',
      'groups': [
        {
          'name': '第一季',
          'episodes': [
            {'videoSn': '1', 'episode': '1', 'local': true},
            {'videoSn': '2', 'episode': '2', 'local': true},
          ],
        },
      ],
    });
    await open(tester);
    await settleIo(tester, () => player.playing);
    await finishEpisode(tester);
    player.actual = const Duration(seconds: 20);
    await tester.tap(find.byKey(const ValueKey('episode-2')));
    await settleIo(
        tester,
        () =>
            player.creations == 2 && files.every((file) => !file.existsSync()));
    expect(state.watchTimeOf('1')?.ended, isTrue);
    expect(state.downloads.entryFor('1'), isNull);
    expect(state.downloads.isDownloaded('2'), isTrue);
    expect(nextFiles.every((file) => file.existsSync()), isTrue);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('看完後跳回前段重看，不會在退出時刪除尚未重看完的影片', (tester) async {
    await state.prefs.setDownloadAutoDeleteWatched(true);
    final files = await seedDownload(tester, '1');
    await open(tester);
    await settleIo(tester, () => player.playing);
    await finishEpisode(tester);
    seek(tester, 30);
    player.actual = const Duration(seconds: 30);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(state.watchTimeOf('1')?.ended, isFalse);
    expect(state.downloads.isDownloaded('1'), isTrue);
    expect(files.every((file) => file.existsSync()), isTrue);
  });

  testWidgets('只有舊的看完紀錄，本次播放失敗時不會自動刪除影片', (tester) async {
    await state.prefs.setDownloadAutoDeleteWatched(true);
    final files = await seedDownload(tester, '1');
    state.watchTimes = {'1': WatchTime(ended: true, duration: 120)};
    player.failInitialisation = true;
    await open(tester);
    expect(player.playing, isFalse);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    expect(state.watchTimeOf('1')?.ended, isTrue);
    expect(state.downloads.isDownloaded('1'), isTrue);
    expect(files.every((file) => file.existsSync()), isTrue);
  });

  testWidgets(
      'skip intro stays compact above tablet, phone and fullscreen controls',
      (tester) async {
    http.Response reply(Object data) =>
        http.Response.bytes(utf8.encode(jsonEncode(data)), 200);
    final api = AgpClient(
      baseUrl: 'http://localhost:12345',
      httpClient: MockClient((request) async {
        switch (request.url.host) {
          case 'api.bgm.tv':
            return reply({
              'data': [
                {
                  'name': '転生王女と天才令嬢の魔法革命',
                  'name_cn': '转生公主与天才千金的魔法革命',
                  'date': '2023-01-04',
                }
              ]
            });
          case 'graphql.anilist.co':
            return reply({
              'data': {
                'Page': {
                  'media': [
                    {
                      'idMal': 52736,
                      'title': {'native': '転生王女と天才令嬢の魔法革命'},
                      'startDate': {'year': 2023},
                    }
                  ]
                }
              }
            });
          case 'api.aniskip.com':
            return reply({
              'found': true,
              'results': [
                {
                  'skipType': 'op',
                  'episodeLength': 1420,
                  'interval': {'startTime': 160.776, 'endTime': 250.776},
                }
              ]
            });
        }
        return http.Response('', 404);
      }),
    );
    addTearDown(api.close);
    state = (await tester.runAsync(() => AppState.boot(client: api)))!;
    state.offline = true;
    state.client.seedSeriesJson('1', {
      'videoSn': '1',
      'title': '轉生公主與天才千金的魔法革命',
      'seasonStart': '2023/01/04',
      'groups': [
        {
          'name': '',
          'episodes': [
            {'videoSn': '1', 'episode': '10', 'local': true},
          ],
        }
      ],
    });
    state.noteWatchTime('1', WatchTime(time: 162, duration: 1420),
        notify: false);
    player.duration = const Duration(seconds: 1420);
    player.actual = const Duration(seconds: 162);
    await open(tester);
    await resizeViewport(tester, const Size(1280, 882));
    for (var i = 0;
        i < 20 && find.byKey(const ValueKey('skip-intro')).evaluate().isEmpty;
        i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final skip = find.byKey(const ValueKey('skip-intro'));
    expect(skip, findsOneWidget);
    var bounds = tester.getRect(skip);
    var forward = tester.getRect(find.byTooltip('快轉 10 秒'));
    expect(bounds.width, lessThan(130));
    expect(bounds.height, lessThanOrEqualTo(40));
    expect(bounds.bottom, lessThan(forward.top - 12));

    await resizeViewport(tester, const Size(390, 844));
    await tester.pump(const Duration(milliseconds: 350));
    bounds = tester.getRect(skip);
    forward = tester.getRect(find.byTooltip('快轉 10 秒'));
    expect(bounds.bottom, lessThan(forward.top - 12));
    expect(bounds.top, greaterThanOrEqualTo(
        tester.getTopLeft(find.byKey(const ValueKey('player-surface'))).dy));

    await resizeViewport(tester, const Size(1280, 882));
    await tester.pump(const Duration(milliseconds: 350));

    await tester.tap(find.byTooltip('全螢幕'));
    await tester.pump(const Duration(milliseconds: 350));
    bounds = tester.getRect(skip);
    forward = tester.getRect(find.byTooltip('快轉 10 秒'));
    expect(bounds.bottom, lessThan(forward.top - 12));
    await tester.tap(skip);
    player.actual = const Duration(milliseconds: 250776);
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.byKey(const ValueKey('skip-intro')), findsNothing);
    expect(player.seeks.last.inMilliseconds, 250776);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'old native positions cannot undo a pending seek; latest drag wins',
      (tester) async {
    await open(tester);
    seek(tester, 300);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(seconds: 2));
    expect(tester.widget<Slider>(find.byType(Slider)).value, 300);
    expect(player.playing, false);
    seek(tester, 420);
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump(const Duration(milliseconds: 150));
    expect(tester.widget<Slider>(find.byType(Slider)).value, 420);
    expect(player.seeks.last.inSeconds, 420);
    player.actual = const Duration(seconds: 420);
    await tester.pump(const Duration(milliseconds: 150));
    expect(player.playing, true);
    expect(state.watchTimeOf('1')?.time, 420);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });
  testWidgets('visible controls allow vertical brightness and volume gestures',
      (tester) async {
    await open(tester);
    final surface = find
        .byType(ColoredBox)
        .evaluate()
        .where((e) => (e.widget as ColoredBox).color == const Color(0xFF384054))
        .first;
    final box = surface.renderObject! as RenderBox;
    // 往下滑 = 調暗 / 調小, 而且要真的打到系統那一層去
    await tester.dragFrom(
        box.localToGlobal(Offset(box.size.width * .2, box.size.height * .4)),
        const Offset(0, 60));
    await tester.pump();
    expect(levels.brightness, lessThan(1));
    await tester.dragFrom(
        box.localToGlobal(Offset(box.size.width * .8, box.size.height * .4)),
        const Offset(0, 60));
    await tester.pump();
    expect(levels.volume, lessThan(1));
    // 播放器自己的音量一律開滿, 衰減交給系統, 免得兩層乘起來
    expect(player.volume, 1);
    await tester.tap(find.text('1.0x'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('0.25x'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });
  testWidgets('dragging shows the selected frame without seeking until release',
      (tester) async {
    const channel = MethodChannel('plugins.justsoft.xyz/video_thumbnail');
    final times = <int>[];
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawRect(const Rect.fromLTWH(0, 0, 320, 180),
        Paint()..color = const Color(0xFF225566));
    canvas.drawCircle(
        const Offset(248, 45), 24, Paint()..color = const Color(0xFFFFC96B));
    final mountain = Path()
      ..moveTo(0, 180)
      ..lineTo(115, 38)
      ..lineTo(250, 180)
      ..close();
    canvas.drawPath(mountain, Paint()..color = const Color(0xFF67A898));
    final picture = recorder.endRecording();
    await tester.runAsync(() async {
      final raster = await picture.toImage(320, 180);
      final bytes = await raster.toByteData(format: ui.ImageByteFormat.png);
      player.frame = bytes!.buffer.asUint8List();
      raster.dispose();
    });
    picture.dispose();
    final frameFile = Platform.environment['AGP_FRAME_FILE'];
    if (frameFile != null) {
      player.frame = await tester.runAsync(() => File(frameFile).readAsBytes());
    }
    state.client.seedSeriesJson('1', {
      'animeSn': 'a1',
      'videoSn': '1',
      'title': 'BLEACH 死神 千年血戰篇',
      'content': '黑崎一護與同伴們迎向新的戰鬥。',
      'groups': [
        {
          'name': '',
          'episodes': [
            for (var i = 1; i <= 12; i++)
              {'videoSn': '$i', 'episode': '$i', 'local': true},
          ]
        }
      ],
    });
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel,
        (call) async {
      times.add(call.arguments['timeMs'] as int);
      return player.frame;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    await open(tester);
    await resizeViewport(tester, const Size(390, 844));
    await tester.pump();
    final slider = tester.widget<Slider>(find.byType(Slider));
    slider.onChangeStart!(254);
    slider.onChanged!(254);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();
    expect(times, [254000]);
    expect(player.seeks, isEmpty);
    expect(player.playing, true);
    expect(find.text('04:14'), findsOneWidget);
    expect(find.byKey(const ValueKey('seek-preview')), findsOneWidget);
    final preview = tester.getRect(find.byKey(const ValueKey('seek-preview')));
    final track = tester.getRect(find.byKey(const ValueKey('player-timeline')));
    expect(preview.bottom, lessThanOrEqualTo(track.top));
    expect(preview.left, greaterThanOrEqualTo(0));
    expect(preview.right, lessThanOrEqualTo(390));
    expect(tester.takeException(), isNull);
    if (Platform.environment['AGP_PLAYER_CAPTURE'] == '1') {
      for (final target in [
        ('player-preview-phone', const Size(390, 844)),
        ('player-preview-landscape', const Size(1000, 650)),
        ('player-preview-fullscreen', const Size(1280, 720)),
      ]) {
        if (target.$1.endsWith('fullscreen')) {
          await tester.tap(find.byTooltip('全螢幕'));
        }
        await resizeViewport(tester, target.$2);
        await tester.pump(const Duration(milliseconds: 300));
        if (target.$1.endsWith('fullscreen')) {
          final timeline = tester.widget<Slider>(find.byType(Slider));
          timeline.onChangeStart!(254);
          timeline.onChanged!(254);
          await tester.pump(const Duration(milliseconds: 200));
        }
        await settleImages(tester);
        final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(const ValueKey('capture')));
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 2);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File('../.agpwork/${target.$1}.png')
              .writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
    }
    player.actual = const Duration(seconds: 254);
    tester.widget<Slider>(find.byType(Slider)).onChangeEnd!(254);
    await tester.pump(const Duration(milliseconds: 300));
    expect(player.seeks.last.inSeconds, 254);
    expect(find.byKey(const ValueKey('seek-preview')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'phone and landscape controls fit and pending seek can be disposed',
      (tester) async {
    await open(tester);
    await resizeViewport(tester, const Size(390, 844));
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('全螢幕'));
    await resizeViewport(tester, const Size(1000, 650));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
    if (Platform.environment['AGP_PLAYER_CAPTURE'] == '1') {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const ValueKey('capture')));
      await tester.runAsync(() async {
        final image = await boundary.toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('../.agpwork/player-controls.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }
    seek(tester, 550);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
  });
  Offset middle(WidgetTester tester) {
    final element = find.byType(ColoredBox).evaluate().firstWhere(
        (e) => (e.widget as ColoredBox).color == const Color(0xFF384054));
    final box = element.renderObject! as RenderBox;
    return box.localToGlobal(box.size.center(Offset.zero));
  }

  testWidgets('center double tap toggles playback without seeking',
      (tester) async {
    await open(tester);
    final center = middle(tester);
    await tester.tapAt(center);
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tapAt(center);
    await tester.pump(const Duration(milliseconds: 300));
    expect(player.playing, false);
    expect(player.seeks, isEmpty);
    await tester.tapAt(center);
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tapAt(center);
    await tester.pump(const Duration(milliseconds: 300));
    expect(player.playing, true);
    expect(player.seeks, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('boost label persists until release and restores original speed',
      (tester) async {
    await open(tester);
    final gesture = await tester.startGesture(middle(tester));
    await tester.pump(const Duration(milliseconds: 600));
    expect(player.speed, 2);
    expect(find.text('2x 倍速中'), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
    expect(find.text('2x 倍速中'), findsOneWidget);
    await gesture.up();
    await tester.pump();
    expect(player.speed, 1);
    expect(find.text('2x 倍速中'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('background resume preserves the controller and never seeks',
      (tester) async {
    await open(tester);
    final count = player.creations;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(player.playing, false);
    await tester.pump(const Duration(seconds: 20));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(player.playing, true);
    expect(player.creations, count);
    expect(player.seeks, isEmpty);
    // An intentional pause must remain paused after another background round trip.
    await tester.tapAt(middle(tester));
    await tester.pump(const Duration(milliseconds: 70));
    await tester.tapAt(middle(tester));
    await tester.pump(const Duration(milliseconds: 300));
    expect(player.playing, false);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(player.playing, false);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
      'tablet layout uses available width; fit is fullscreen only with large targets',
      (tester) async {
    await open(tester);
    await resizeViewport(tester, const Size(1280, 882));
    await tester.pump();
    if (Platform.environment['AGP_PLAYER_CAPTURE'] == '1') {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const ValueKey('capture')));
      await tester.runAsync(() async {
        final image = await boundary.toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('../.agpwork/player-tablet.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }
    expect(find.byTooltip('畫面比例'), findsNothing);
    final settings = find.byTooltip('設定');
    expect(tester.getSize(settings).width, greaterThanOrEqualTo(48));
    expect(tester.getSize(settings).height, greaterThanOrEqualTo(48));
    await tester.tap(find.byTooltip('全螢幕'));
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.byTooltip('畫面比例'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('離開全螢幕'));
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.byTooltip('畫面比例'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
      'reference player keeps controls below the picture center and synopsis collapsed',
      (tester) async {
    final frameFile = Platform.environment['AGP_FRAME_FILE'];
    if (frameFile != null) {
      player.frame = await tester.runAsync(() => File(frameFile).readAsBytes());
    }
    state.client.seedSeriesJson('1', {
      'animeSn': 'a1',
      'videoSn': '1',
      'title': 'BLEACH 死神 千年血戰篇',
      'seasonStart': '2022 / 10',
      'director': '田口智久',
      'publisher': '木棉花',
      'score': 4.9,
      'popular': '1250000',
      'tags': ['動作', '奇幻', '冒險'],
      'content': List.filled(20, '黑崎一護與同伴們迎向新的戰鬥。').join(),
      'groups': [
        {
          'name': '',
          'episodes': [
            for (var i = 1; i <= 12; i++)
              {'videoSn': '$i', 'episode': '$i', 'local': true},
          ]
        }
      ],
    });
    await open(tester, mode: Brightness.light);
    await resizeViewport(tester, const Size(1280, 882));
    await tester.pump();
    expect(find.byKey(const ValueKey('series-synopsis')), findsNothing);
    expect(tester.getSize(find.byKey(const ValueKey('series-info'))).height,
        lessThan(340));
    final timeline =
        tester.getRect(find.byKey(const ValueKey('player-timeline')));
    final play = tester.getRect(find.byTooltip('暫停'));
    expect(play.center.dx, greaterThan(timeline.center.dx));
    expect(play.bottom, lessThanOrEqualTo(timeline.top));
    expect(timeline.top - play.bottom, lessThan(20));
    expect(find.text('1.0x'), findsOneWidget);
    expect(find.byTooltip('選集'), findsOneWidget);
    expect(tester.getCenter(find.byTooltip('快轉 10 秒')).dx,
        greaterThan(tester.getCenter(find.byTooltip('倒退 10 秒')).dx));
    if (Platform.environment['AGP_PLAYER_CAPTURE'] == '1') {
      var fullscreen = false;
      for (final target in [
        ('player-reference-tablet', const Size(1280, 882)),
        ('player-reference-phone-small', const Size(320, 568)),
        ('player-reference-phone', const Size(390, 844)),
        ('player-reference-phone-large', const Size(430, 932)),
        ('player-reference-phone-landscape', const Size(844, 390)),
        ('player-reference-phone-fullscreen', const Size(844, 390)),
        ('player-reference-fullscreen', const Size(1280, 720)),
      ]) {
        final nextFullscreen = target.$1.endsWith('fullscreen');
        if (nextFullscreen != fullscreen) {
          await tester.tap(find.byTooltip(fullscreen ? '離開全螢幕' : '全螢幕'));
          fullscreen = nextFullscreen;
        }
        await resizeViewport(tester, target.$2);
        await tester.pump(const Duration(milliseconds: 300));
        await settleImages(tester);
        await tester.runAsync(() async {
          final raster = await tester
              .renderObject<RenderRepaintBoundary>(
                  find.byKey(const ValueKey('capture')))
              .toImage();
          final bytes = await raster.toByteData(format: ui.ImageByteFormat.png);
          await File('../.agpwork/${target.$1}.png')
              .writeAsBytes(bytes!.buffer.asUint8List());
          raster.dispose();
        });
      }
      await tester.tap(find.byTooltip('離開全螢幕'));
      await resizeViewport(tester, const Size(1280, 882));
      await tester.pump(const Duration(milliseconds: 350));
    }
    await tester.tap(find.text('查看更多'));
    await tester.pump();
    expect(find.byKey(const ValueKey('series-synopsis')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
      'phone tools leave the picture clear and episode tabs preserve playback',
      (tester) async {
    state.client.seedSeriesJson('1', {
      'videoSn': '1',
      'title': '手機播放測試',
      'content': '作品的劇情簡介。',
      'groups': [
        {
          'name': '',
          'episodes': [
            for (var i = 1; i <= 12; i++)
              {'videoSn': '$i', 'episode': '$i', 'local': true},
          ],
        },
      ],
    });
    await open(tester, mode: Brightness.light);
    tester.view.padding = const FakeViewPadding(top: 44, bottom: 34);
    addTearDown(tester.view.resetPadding);
    for (final size in [
      const Size(320, 568),
      const Size(390, 844),
      const Size(430, 932),
    ]) {
      await resizeViewport(tester, size);
      await tester.pump();
      final surface =
          tester.getRect(find.byKey(const ValueKey('player-surface')));
      final tools =
          tester.getRect(find.byKey(const ValueKey('mobile-player-tools')));
      final play = tester.getRect(find.byTooltip('暫停'));
      expect(surface.width / surface.height, closeTo(16 / 9, .01));
      expect(tools.top, greaterThanOrEqualTo(surface.bottom));
      expect(play.center.dy, greaterThan(surface.top + surface.height * .6));
      expect(play.width, greaterThanOrEqualTo(48));
      expect(find.byTooltip('設定').hitTestable(), findsOneWidget);
      expect(find.byTooltip('全螢幕').hitTestable(), findsOneWidget);
      expect(find.byKey(const ValueKey('episode-2')).hitTestable(),
          findsOneWidget);
      expect(find.byKey(const ValueKey('series-info')), findsNothing);
      expect(tester.takeException(), isNull);
    }
    for (final size in [const Size(568, 320), const Size(844, 390)]) {
      await resizeViewport(tester, size);
      await tester.pump();
      final surface =
          tester.getRect(find.byKey(const ValueKey('player-surface')));
      final episode = tester.getRect(find.byKey(const ValueKey('episode-2')));
      expect(surface.width, greaterThan(size.width / 2));
      expect(episode.left, greaterThanOrEqualTo(surface.right));
      expect(episode.width, greaterThanOrEqualTo(48));
      expect(find.byKey(const ValueKey('episode-2')).hitTestable(),
          findsOneWidget);
      expect(tester.takeException(), isNull);
    }
    await resizeViewport(tester, const Size(390, 844));
    await tester.pump();
    await tester.tap(find.text('簡介'));
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.byKey(const ValueKey('series-synopsis')), findsOneWidget);
    expect(find.byKey(const ValueKey('episode-2')), findsNothing);
    expect(player.creations, 1);
    expect(player.playing, isTrue);
    await tester.tap(find.byTooltip('全螢幕'));
    await resizeViewport(tester, const Size(844, 390));
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.byKey(const ValueKey('mobile-player-tools')), findsNothing);
    expect(find.byTooltip('離開全螢幕').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('離開全螢幕'));
    await resizeViewport(tester, const Size(390, 844));
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.byKey(const ValueKey('series-synopsis')), findsOneWidget);
    await tester.tap(find.text('選集'));
    await tester.pump(const Duration(milliseconds: 350));
    expect(
        find.byKey(const ValueKey('episode-2')).hitTestable(), findsOneWidget);
    await tester.tap(find.byTooltip('暫停'));
    await tester.pump(const Duration(milliseconds: 350));
    expect(player.playing, isFalse);
    expect(player.creations, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  for (final mode in [Brightness.light, Brightness.dark]) {
    testWidgets('small phone supports large text and menus in ${mode.name}',
        (tester) async {
      await state.prefs.setRate(1);
      addTearDown(() => state.prefs.setRate(1));
      state.client.seedSeriesJson('1', {
        'videoSn': '1',
        'title': 'BLEACH 死神 千年血戰篇',
        'groups': [
          {
            'name': '',
            'episodes': [
              for (var i = 1; i <= 12; i++)
                {'videoSn': '$i', 'episode': '$i', 'local': true},
            ],
          },
        ],
      });
      final frameFile = Platform.environment['AGP_FRAME_FILE'];
      if (frameFile != null) {
        player.frame =
            await tester.runAsync(() => File(frameFile).readAsBytes());
      }
      await open(tester, mode: mode, scale: 1.8);
      await resizeViewport(tester, const Size(320, 640));
      await tester.pump();
      expect(find.byTooltip('設定').hitTestable(), findsOneWidget);
      expect(find.byTooltip('全螢幕').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      if (Platform.environment['AGP_PLAYER_CAPTURE'] == '1') {
        await settleImages(tester);
        await tester.runAsync(() async {
          final raster = await tester
              .renderObject<RenderRepaintBoundary>(
                  find.byKey(const ValueKey('capture')))
              .toImage();
          final bytes = await raster.toByteData(format: ui.ImageByteFormat.png);
          await File('../.agpwork/player-large-text-${mode.name}.png')
              .writeAsBytes(bytes!.buffer.asUint8List());
          raster.dispose();
        });
      }
      await tester.tap(find.byTooltip('1.0x'));
      await tester.pump(const Duration(milliseconds: 350));
      await tester.ensureVisible(find.text('1.5x'));
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.text('1.5x').hitTestable(), findsOneWidget);
      await tester.tap(find.text('1.5x'));
      await tester.pump(const Duration(milliseconds: 350));
      expect(player.speed, 1.5);
      await tester.tap(find.byTooltip('設定'));
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.text('播放設定'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
  testWidgets(
      'a full season is visible below the player without scrolling on tablets',
      (tester) async {
    state.client.seedSeriesJson('1', {
      'videoSn': '1',
      'title': '平板選集',
      'groups': [
        {
          'name': '第一季',
          'episodes': [
            for (var i = 1; i <= 13; i++)
              {'videoSn': '$i', 'episode': '$i', 'local': true},
          ]
        }
      ],
    });
    await open(tester, mode: Brightness.light);
    tester.view.padding = const FakeViewPadding(top: 24, bottom: 20);
    addTearDown(tester.view.resetPadding);
    for (final size in [
      const Size(1280, 720),
      const Size(1024, 600),
      const Size(1000, 650)
    ]) {
      await resizeViewport(tester, size);
      await tester.pump();
      final last = find.byKey(const ValueKey('episode-13'));
      expect(last, findsOneWidget);
      expect(tester.getRect(last).bottom, lessThanOrEqualTo(size.height - 20));
      expect(last.hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('reopening the same episode reuses the parked native player',
      (tester) async {
    // 從觀看紀錄退出去再點回同一集: 原生播放器還停在架上, 不該再 initialize
    // 一次 —— 重開一次要把檔頭整個重新要一遍, 那就是回來時空等的那幾秒.
    await open(tester);
    expect(player.creations, 1);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();

    await tester.pumpWidget(RepaintBoundary(
        child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: ThemeData(fontFamily: 'Roboto'),
            home: WatchPage(state: state, sn: '1'))));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(player.creations, 1);
    expect(find.byType(Slider), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
      'inline controls stay compact and only fullscreen pays the bottom safe area',
      (tester) async {
    await open(tester);
    tester.view.padding = const FakeViewPadding(top: 24, bottom: 34);
    addTearDown(tester.view.resetPadding);
    await resizeViewport(tester, const Size(1280, 882));
    await tester.pump();
    Rect surface() =>
        tester.getRect(find.byKey(const ValueKey('player-surface')));
    final button = tester.getRect(find.byTooltip('全螢幕'));
    expect(surface().bottom - button.bottom, closeTo(4, 1));
    expect(button.size.height, greaterThanOrEqualTo(48));
    final timeline =
        tester.getRect(find.byKey(const ValueKey('player-timeline')));
    expect(surface().bottom - timeline.center.dy, lessThanOrEqualTo(70));
    await tester.tap(find.byTooltip('全螢幕'));
    await tester.pump(const Duration(milliseconds: 350));
    expect(surface().bottom - tester.getRect(find.byTooltip('離開全螢幕')).bottom,
        closeTo(4 + 34 / tester.view.devicePixelRatio, 1));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'danmaku stays on the video without a list below the episode grid',
      (tester) async {
    await tester.runAsync(() async {
      final ass = await File('../tests/fixtures/sample.ass').readAsString();
      await state.downloads.writeCachedDanmaku('1', ass);
      expect(await state.downloads.readCachedDanmaku('1'), isNotNull);
    });
    await open(tester);
    for (var i = 0;
        i < 10 && find.byType(DanmakuOverlay).evaluate().isEmpty;
        i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    expect(find.byType(DanmakuOverlay), findsOneWidget);
    expect(tester.widget<DanmakuOverlay>(find.byType(DanmakuOverlay)).comments,
        isNotEmpty);
    expect(tester.widget<DanmakuOverlay>(find.byType(DanmakuOverlay)).lowPower,
        isFalse);
    expect(find.text('彈幕'), findsNothing);
    expect(find.textContaining('這一集沒有彈幕'), findsNothing);
    await tester.tap(find.byTooltip('關閉彈幕'));
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.byType(DanmakuOverlay), findsNothing);
    await tester.tap(find.byTooltip('開啟彈幕'));
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.byType(DanmakuOverlay), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('彈幕很多的集數: 在背景解析, 一條都不少', (tester) async {
    // 熱門的集數彈幕上萬行. 大到這個程度的檔改在背景 isolate 解析, 不在開播
    // 那一刻卡住畫面 —— 但解析出來的結果要跟原本一模一樣.
    const lines = 4000;
    final ass = StringBuffer('[Script Info]\nScriptType: v4.00+\n\n[Events]\n');
    for (var i = 0; i < lines; i++) {
      final seconds = (i * 0.3).toStringAsFixed(2).padLeft(5, '0');
      ass.writeln('Dialogue: 0,0:00:$seconds,0:00:59.00,Roll,,0,0,0,,'
          r'{\move(1920,50,-200,50)\1c&H4CFFFFFF}第 '
          '$i 條彈幕');
    }
    expect(ass.length, greaterThan(kDanmakuParseInline),
        reason: '測試資料要大到會走背景解析那一條');
    await tester.runAsync(
        () => state.downloads.writeCachedDanmaku('1', ass.toString()));

    await open(tester);
    for (var i = 0;
        i < 100 && find.byType(DanmakuOverlay).evaluate().isEmpty;
        i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    final overlay = tester.widget<DanmakuOverlay>(find.byType(DanmakuOverlay));
    expect(overlay.comments.length, lines);
    expect(overlay.comments.first.text, '第 0 條彈幕');
    expect(overlay.comments.last.start, closeTo((lines - 1) * 0.3, 0.01));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a different episode cannot adopt the parked player',
      (tester) async {
    await open(tester);
    expect(player.creations, 1);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();

    await tester.pumpWidget(RepaintBoundary(
        child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: ThemeData(fontFamily: 'Roboto'),
            home: WatchPage(state: state, sn: '2'))));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(player.creations, 2);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('fullscreen toggle keeps the rightmost slot in both modes',
      (tester) async {
    // 進出全螢幕會多一顆「畫面比例」出來. 它要是插在全螢幕鍵右邊, 整排就往
    // 左挪一格, 使用者照原來的位置按下去按到的是畫面比例 —— 動畫瘋不會這樣,
    // 這裡把「最右邊永遠是全螢幕」釘住.
    await open(tester);
    await resizeViewport(tester, const Size(1280, 882));
    await tester.pump();
    double x(String tooltip) => tester.getCenter(find.byTooltip(tooltip)).dx;
    expect(x('全螢幕'), greaterThan(x('設定')));
    await tester.tap(find.byTooltip('全螢幕'));
    await tester.pump(const Duration(milliseconds: 350));
    expect(x('離開全螢幕'), greaterThan(x('畫面比例')));
    expect(x('畫面比例'), greaterThan(x('設定')));
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('在已下載的邊緣卡住不算整集看完', (tester) async {
    await open(tester);

    // 走到片尾再卡住. ExoPlayer 重新緩衝時 isPlaying 會變 false, 位置又停在
    // duration 上 —— 跟「播完了」長得一模一樣. 邊看邊下載的 playlist 沒有
    // ENDLIST, duration 只算到目前產出的那一段, 所以網路一慢, 看到一半就會
    // 被判定成整集看完: 進度歸零, 而且自動跳下一集.
    player.actual = const Duration(seconds: 600);
    player.events.add(VideoEvent(eventType: VideoEventType.bufferingStart));
    player.events.add(VideoEvent(
        eventType: VideoEventType.isPlayingStateUpdate, isPlaying: false));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    expect(state.watchTimeOf('1')?.ended, isNot(true), reason: '還在緩衝就被當成看完了');

    // 但真的播完了還是要認得出來
    player.events.add(VideoEvent(eventType: VideoEventType.bufferingEnd));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    expect(state.watchTimeOf('1')?.ended, isTrue,
        reason: '緩衝完了, 位置也在片尾 —— 這次是真的看完了');

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });
  // 在 120Hz 的 iPad 上, 只要有一個 ticker 在跑, 整個畫面 (連影片) 每秒就要
  // 重新合成一百二十次. 以前播放頁一打開就掛著一個永遠不停的 ticker, 暫停著
  // 一張靜止的畫面也照樣在燒電.
  testWidgets('沒有東西在動的時候, 播放頁不再每一幀重新合成', (tester) async {
    await open(tester);
    expect(player.playing, isTrue);
    await tester.pump(const Duration(seconds: 2));
    expect(tester.binding.hasScheduledFrame, isFalse,
        reason: '在播但沒有彈幕: 影片的畫面是原生那一層在送, 這一層不必每一幀重畫');

    await tester.tap(find.byTooltip('暫停'));
    await tester.pump(const Duration(milliseconds: 350));
    expect(player.playing, isFalse);
    // 按鈕的水波紋動畫跑完
    await tester.pump(const Duration(seconds: 2));
    expect(tester.binding.hasScheduledFrame, isFalse,
        reason: '暫停著一張靜止的畫面, 卻還在每一幀重畫');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('有彈幕的時候, 暫停下來彈幕層也跟著停', (tester) async {
    await tester.runAsync(() async {
      final ass = await File('../tests/fixtures/sample.ass').readAsString();
      await state.downloads.writeCachedDanmaku('1', ass);
    });
    await open(tester);
    for (var i = 0;
        i < 10 && find.byType(DanmakuOverlay).evaluate().isEmpty;
        i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    expect(find.byType(DanmakuOverlay), findsOneWidget);

    await tester.tap(find.byTooltip('暫停'));
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump(const Duration(seconds: 2));
    expect(tester.binding.hasScheduledFrame, isFalse,
        reason: '暫停了, 彈幕層的 ticker 還在空轉');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('續播: 跳到上次的位置就按播放, 不先等緩衝完', (tester) async {
    // 從觀看紀錄接著看: 開起來先跳到上次的位置. 那裡還沒載過, 播放器一定在
    // 緩衝 —— 以前還要再等「緩衝完」(最多 1.2 秒) 才肯按播放, 每一次續播的
    // 開頭都白白多等那一段.
    state.noteWatchTime(
        '1', WatchTime(time: 300, duration: 600, timestamp: 1));
    player.actual = const Duration(seconds: 300);
    player.bufferOnSeek = true;
    await open(tester);
    expect(player.seeks.last.inSeconds, 300);
    expect(player.playing, isTrue, reason: '位置已經到了, 卻還在等緩衝完才按播放');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });

  // 「1 B/s 然後就永遠卡住, 只能把 app 關掉重開」. 原生播放器等的那條連線
  // 死了, 它自己不會放棄 —— 播放頁要替使用者做他本來會做的事.
  testWidgets('卡在緩衝出不來: 先原地重新要, 再不行就把播放器重開', (tester) async {
    await open(tester);
    expect(player.playing, isTrue);
    final creations = player.creations;
    player.events.add(VideoEvent(eventType: VideoEventType.bufferingStart));

    await tester.pump(const Duration(seconds: 10));
    expect(player.seeks, isEmpty, reason: '才卡十秒, 還不該出手 (可能只是慢)');

    // 這一條量不到速度 (沒走本機快取), 分不出慢跟死, 所以等半分鐘
    await tester.pump(const Duration(seconds: 22));
    expect(player.seeks, isNotEmpty, reason: '卡了半分鐘還在乾等');
    expect(player.seeks.last.inSeconds, 20, reason: '要在原地重新要, 不是跳走');
    expect(player.creations, creations, reason: '第一步只是原地重新要');

    // 原地重新要也沒用 (事件裡一直沒有 bufferingEnd): 整個重開
    await tester.pump(const Duration(seconds: 30));
    expect(player.creations, creations + 1, reason: '卡了一分鐘還是沒重開播放器');
    // 重開之後從同一個位置接著播
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(player.seeks.last.inSeconds, 20);
    expect(player.playing, isTrue);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('緩衝一下就好了的話什麼都不做', (tester) async {
    await open(tester);
    final creations = player.creations;
    player.events.add(VideoEvent(eventType: VideoEventType.bufferingStart));
    await tester.pump(const Duration(seconds: 20));
    player.events.add(VideoEvent(eventType: VideoEventType.bufferingEnd));
    await tester.pump(const Duration(seconds: 1));
    // 之後又卡, 要重新計時, 不是接著上一次的算
    player.events.add(VideoEvent(eventType: VideoEventType.bufferingStart));
    await tester.pump(const Duration(seconds: 20));
    expect(player.seeks, isEmpty);
    expect(player.creations, creations);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('播到一半原生播放器報錯: 從同一個位置自己重開, 一直壞才放棄',
      (tester) async {
    await open(tester);
    final creations = player.creations;

    Future<void> fail() async {
      player.latest.addError(
          PlatformException(code: 'VideoError', message: '連線中斷'));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    await fail();
    expect(player.creations, creations + 1, reason: '報錯之後畫面就停在那裡');
    expect(player.seeks.last.inSeconds, 20, reason: '重開之後沒有回到原來的位置');
    expect(find.textContaining('播放中斷:'), findsNothing);

    await fail();
    expect(player.creations, creations + 2);

    // 一分鐘內第三次: 這個片源多半真的壞了, 不要無限重開下去
    await fail();
    expect(player.creations, creations + 2);
    expect(find.textContaining('播放中斷:'), findsOneWidget);
    expect(find.text('重試'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('播放中記進度不驚動整個 app, 離開時才通知', (tester) async {
    // AppState 一通知, 壓在播放頁底下的五個分頁全部要重建一次. 播放中每十秒
    // 記一次進度, 看一集就是一百多次沒人看得到的重建.
    var notified = 0;
    void count() => notified++;
    state.addListener(count);
    addTearDown(() => state.removeListener(count));

    await open(tester);
    await tester.pump(const Duration(seconds: 1));
    expect(state.watchTimeOf('1'), isNotNull, reason: '進度還是要記下來');
    expect(notified, 0, reason: '播放中的例行進度把整個 app 叫起來重建');

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(notified, greaterThan(0), reason: '離開播放頁之後, 觀看紀錄要看得到最新進度');
  });

  testWidgets('看幾秒就退出去, 這一集也要留下進度', (tester) async {
    // 「更新觀看時間感覺不容易觸發」就是這一條: 以前本機那份跟伺服器那份綁在同
    // 一個十秒閘上, 而且 dispose 只落盤、不記位置 —— 開一集看八秒退出去, 這一集
    // 等於完全沒看過, 首頁的繼續觀看當然是空的.
    await open(tester);
    await tester.pump(const Duration(milliseconds: 100));
    player.actual = const Duration(seconds: 8);
    // 讓播放器回報一次新位置, 但遠不到十秒
    player.events.add(VideoEvent(
        eventType: VideoEventType.isPlayingStateUpdate, isPlaying: true));
    await tester.pump(const Duration(milliseconds: 200));

    await tester.pumpWidget(const SizedBox());
    await tester.pump();

    final saved = state.watchTimeOf('1');
    expect(saved, isNotNull, reason: '離開時一定要留下一筆');
    expect(saved!.time, greaterThanOrEqualTo(3),
        reason: '最後那幾秒不該因為十秒閘而消失');
  });

  testWidgets('每一集自己算自己的十秒窗, 換集不會吃掉新一集的開頭', (tester) async {
    // 上一集留下的時間戳如果跟著過來, 新的一集要等舊窗口過完才會記第一筆 ——
    // 一集開頭那幾秒就是這樣不見的.
    state.client.seedSeriesJson('1', {
      'videoSn': '1',
      'title': '換集進度測試',
      'groups': [
        {
          'name': '',
          'episodes': [
            {'videoSn': '1', 'episode': '1', 'local': true},
            {'videoSn': '2', 'episode': '2', 'local': true},
          ],
        },
      ],
    });
    await open(tester);
    await tester.pump(const Duration(seconds: 1));
    expect(state.watchTimeOf('1'), isNotNull);

    await tester.tap(find.byKey(const ValueKey('episode-2')));
    await settleIo(tester, () => state.watchTimeOf('2') != null);

    // 舊行為: 上一集那個時間戳還在, 新的一集要等窗口過完才會記第一筆, 所以這裡
    // 會是 null. 這一筆存不存在就是「換集有沒有歸零」的分界.
    expect(state.watchTimeOf('2'), isNotNull, reason: '換集之後新的一集也要立刻開始記進度');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('跳轉到一半播放器壞掉: 一樣自己重開, 而且落在要去的位置', (tester) async {
    // 播放器報錯的那一刻剛好在跳轉: 當下不能處理 (跳轉還沒放手), 而壞掉的
    // 播放器不會再通知第二次 —— 跳轉那邊收尾時不接手的話, 就永遠停在那裡
    await open(tester);
    final creations = player.creations;
    seek(tester, 300); // 播放器一直回報 20 秒, 所以這個跳轉會一直掛著
    await tester.pump(const Duration(milliseconds: 150));
    player.actual = const Duration(seconds: 300);
    player.latest
        .addError(PlatformException(code: 'VideoError', message: '連線中斷'));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(player.creations, creations + 1, reason: '跳轉中壞掉之後沒有重開');
    expect(player.seeks.last.inSeconds, 300, reason: '重開之後沒有落在要去的位置');
    expect(player.playing, isTrue, reason: '跳轉前在播, 重開之後也要接著播');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('開始播之後再緩衝就只留速度, 不再把轉圈壓在畫面中央', (tester) async {
    levels.install(tester);
    addTearDown(() => levels.remove(tester));
    await resizeViewport(tester, const Size(1000, 800));
    await tester.pumpWidget(MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(fontFamily: 'Roboto'),
        home: WatchPage(state: state, sn: '1')));

    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(player.playing, true, reason: '這個測試的前提是它已經播出畫面了');

    // 播到一半又卡住: 使用者眼前已經有一張停住的畫面, 別再擋掉它
    player.events.add(VideoEvent(eventType: VideoEventType.bufferingStart));
    await tester.pump(const Duration(milliseconds: 150));
    expect(find.text('緩衝中…'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);

    // 緩衝完就整個收掉
    player.events.add(VideoEvent(eventType: VideoEventType.bufferingEnd));
    await tester.pump(const Duration(milliseconds: 150));
    expect(find.text('緩衝中…'), findsNothing);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });

  group('子母畫面', () {
    const channel = MethodChannel('video_player_pip');
    late List<Map<Object?, Object?>> updates;
    late bool nativeInPip;
    late bool pipSupported;

    setUp(() {
      pipSupported = VideoPlayerPip.supported;
      VideoPlayerPip.supported = true;
      updates = [];
      nativeInPip = false;
    });
    tearDown(() => VideoPlayerPip.supported = pipSupported);

    void installNative(WidgetTester tester) {
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'updatePip':
            updates.add(call.arguments as Map<Object?, Object?>);
            return true;
          case 'isInPipMode':
            return nativeInPip;
          case 'isPipSupported':
            return true;
        }
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    }

    /// 原生那邊送上來的事件 (進出子母畫面、視窗裡的按鈕)
    Future<void> fromNative(
        WidgetTester tester, String method, Object? arguments) async {
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
          channel.name,
          const StandardMethodCodec()
              .encodeMethodCall(MethodCall(method, arguments)),
          (_) {});
    }

    Future<void> togglePlay(WidgetTester tester) async {
      final center = middle(tester);
      await tester.tapAt(center);
      await tester.pump(const Duration(milliseconds: 80));
      await tester.tapAt(center);
      await tester.pump(const Duration(milliseconds: 300));
    }

    testWidgets('播放中掛上自動子母畫面, 暫停就拆掉, 離開播放頁全部收掉',
        (tester) async {
      installNative(tester);
      await open(tester);
      expect(player.playing, isTrue);
      final armed = updates.last;
      expect(armed['autoEnter'], isTrue);
      expect(armed['playing'], isTrue);
      expect(armed['playerId'], 1);
      expect(armed['width'], 1920);
      expect(armed['height'], 1080);
      expect(armed['rect'], isA<List<Object?>>(),
          reason: 'Android 要拿影片的位置做進出動畫');

      await togglePlay(tester);
      expect(player.playing, isFalse);
      expect(updates.last['autoEnter'], isFalse);
      expect(updates.last['playing'], isFalse,
          reason: '子母畫面視窗裡要改畫播放鍵');

      await tester.pumpWidget(const SizedBox());
      expect(updates.last['autoEnter'], isFalse);
      expect(updates.last['playerId'], isNull);
    });

    testWidgets('回到桌面時自動子母畫面開起來: 影片不暫停', (tester) async {
      installNative(tester);
      await open(tester);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(player.playing, isTrue, reason: 'iOS 一暫停就不會自動開了');

      await fromNative(tester, 'pipModeChanged', {'isInPipMode': true});
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump(const Duration(seconds: 3));
      expect(player.playing, isTrue);

      // 從子母畫面點回 App
      await fromNative(tester, 'pipModeChanged', {'isInPipMode': false});
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump(const Duration(seconds: 1));
      expect(player.playing, isTrue);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('事件比切到背景晚到也認得: 問一次原生是不是已經在子母畫面裡',
        (tester) async {
      installNative(tester);
      await open(tester);
      nativeInPip = true;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump(const Duration(seconds: 2));
      expect(player.playing, isTrue);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('自動子母畫面沒開起來 (控制中心、來電): 等一下照常暫停',
        (tester) async {
      installNative(tester);
      await open(tester);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump(const Duration(milliseconds: 100));
      expect(player.playing, isTrue);
      await tester.pump(const Duration(seconds: 1));
      expect(player.playing, isFalse);

      // 回來的時候照舊接著播
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump(const Duration(milliseconds: 100));
      expect(player.playing, isTrue);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('子母畫面被關掉: 停下來, 回到 App 也不自己播', (tester) async {
      installNative(tester);
      await open(tester);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await fromNative(tester, 'pipModeChanged', {'isInPipMode': true});
      await tester.pump(const Duration(seconds: 1));
      expect(player.playing, isTrue);

      await fromNative(tester, 'pipModeChanged', {'isInPipMode': false});
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump(const Duration(seconds: 1));
      expect(player.playing, isFalse);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump(const Duration(seconds: 1));
      expect(player.playing, isFalse);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('Android 子母畫面視窗裡的按鈕: 暫停、播放、倒退、快轉', (tester) async {
      installNative(tester);
      await open(tester);
      await fromNative(tester, 'pipModeChanged', {'isInPipMode': true});
      await tester.pump(const Duration(milliseconds: 100));

      await fromNative(tester, 'pipAction', {'action': 'pause'});
      await tester.pump(const Duration(milliseconds: 100));
      expect(player.playing, isFalse);
      expect(updates.last['playing'], isFalse);

      await fromNative(tester, 'pipAction', {'action': 'play'});
      await tester.pump(const Duration(milliseconds: 100));
      expect(player.playing, isTrue);
      expect(updates.last['playing'], isTrue);

      final before = player.seeks.length;
      await fromNative(tester, 'pipAction', {'action': 'forward'});
      await tester.pump(const Duration(milliseconds: 300));
      expect(player.seeks.length, before + 1);
      expect(player.seeks.last.inSeconds, greaterThanOrEqualTo(29));
      player.actual = player.seeks.last;
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('設定裡關掉自動子母畫面: 不掛, 切到背景馬上暫停', (tester) async {
      await state.prefs.setPipAuto(false);
      installNative(tester);
      await open(tester);
      expect(updates, isNotEmpty);
      expect(updates.every((call) => call['autoEnter'] == false), isTrue);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(player.playing, isFalse);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('電視遙控器', () {
    setUp(() => Device.tv = true);
    tearDown(() => Device.tv = false);

    for (final offline in [false, true]) {
      testWidgets('電視不用 PlatformView 合成影片 (offline=$offline)', (tester) async {
        expect(state.prefs.pipEnabled, isTrue,
            reason: '重現預設開啟 PiP 時舊電視走到昂貴合成路徑');
        if (offline) await seedDownload(tester, '1');
        await open(tester);
        expect(player.sources, isNotEmpty);
        expect(player.sources.last.dataSource.sourceType,
            offline ? DataSourceType.file : DataSourceType.network);
        expect(player.sources.last.viewType, VideoViewType.textureView);
        await tester.pumpWidget(const SizedBox());
      });
    }

    testWidgets('電視播放自動使用低負載彈幕', (tester) async {
      await tester.runAsync(() async {
        final ass = await File('../tests/fixtures/sample.ass').readAsString();
        await state.downloads.writeCachedDanmaku('1', ass);
      });
      await open(tester);
      for (var i = 0;
          i < 10 && find.byType(DanmakuOverlay).evaluate().isEmpty;
          i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump();
      }
      final overlay = tester.widget<DanmakuOverlay>(find.byType(DanmakuOverlay));
      expect(overlay.comments, isNotEmpty);
      expect(overlay.lowPower, isTrue);
      await tester.pumpWidget(const SizedBox());
    });

    String? focused() => FocusManager.instance.primaryFocus?.debugLabel;

    double controlsOpacity(WidgetTester tester) => tester
        .widget<AnimatedOpacity>(find.byKey(const ValueKey('player-controls')))
        .opacity;

    testWidgets('電視控制列收起後不訂閱時鐘, 按 OK 立即重建並可操作設定', (tester) async {
      await open(tester);
      expect(find.byType(Slider), findsOneWidget);
      await tester.pump(kControlsIdle + const Duration(seconds: 1));
      expect(find.byType(Slider), findsNothing);
      expect(controlsOpacity(tester), 0);
      for (var i = 0; i < 10; i++) {
        player.actual += const Duration(milliseconds: 100);
        await tester.pump(const Duration(milliseconds: 100));
        expect(tester.binding.hasScheduledFrame, isFalse,
            reason: '隱藏的播放控制列不該每次進度回報都要求幀');
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.select, platform: 'android');
      await tester.pump();
      expect(find.byType(Slider), findsOneWidget);
      expect(controlsOpacity(tester), 1);
      await tester.tap(find.byTooltip('設定'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('播放設定'), findsOneWidget);
      expect(find.byKey(const ValueKey('player-timeline')), findsNothing,
          reason: '設定選單蓋住控制列時不該繼續更新底下的進度條');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('上下導覽反覆回到播放鍵, 不會誤改進度', (tester) async {
      await open(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(focused(), 'player-play');
      for (var i = 0; i < 8; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump();
        expect(focused(), 'player-timeline');
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        await tester.pump();
        expect(focused(), 'player-play');
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump();
        expect(focused(), isNot('player-timeline'));
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        await tester.pump();
        expect(focused(), 'player-play', reason: '下方設定列往上要能選到暫停');
      }
      expect(player.seeks, isEmpty);
      await tester.sendKeyEvent(LogicalKeyboardKey.select, platform: 'android');
      await tester.pump();
      expect(player.playing, isFalse, reason: '最後選到的要是暫停按鈕');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('控制列隱藏後按上, 重建完成仍選到播放鍵', (tester) async {
      await open(tester);
      await tester.pump(kControlsIdle + const Duration(seconds: 1));
      expect(focused(), 'player-surface');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      await tester.pump();
      expect(focused(), 'player-play');
      expect(player.seeks, isEmpty);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('進度條按 OK 才調整, 確認一次只跳轉一次', (tester) async {
      await open(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(focused(), 'player-timeline');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(player.seeks, isEmpty);
      expect(focused(), 'player-play');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.select, platform: 'android');
      await tester.pump();
      expect(find.text('左右調整 · OK 確認 · 返回取消'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(player.seeks, isEmpty, reason: '尚未确认不可送 seek');
      await tester.sendKeyEvent(LogicalKeyboardKey.select, platform: 'android');
      await tester.pump(const Duration(milliseconds: 150));
      expect(player.seeks, hasLength(1));
      expect(player.seeks.single.inSeconds, inInclusiveRange(29, 32));
      expect(focused(), 'player-play');
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('暫停時返回取消進度調整, 不離開播放頁也不跳轉', (tester) async {
      await open(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.select, platform: 'android');
      await tester.pump();
      expect(player.playing, isFalse);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.select, platform: 'android');
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(focused(), 'player-play');
      expect(controlsOpacity(tester), 1);
      expect(player.seeks, isEmpty);
      expect(find.byType(WatchPage), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('播放設定可開啟藍牙配對與影音同步系統設定', (tester) async {
      final calls = <String>[];
      const channel = MethodChannel('agp/device');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel,
          (call) async {
        calls.add(call.method);
        return true;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null));
      await open(tester);
      Future<void> guide() async {
        await tester.tap(find.byTooltip('設定'));
        await tester.pump(const Duration(milliseconds: 300));
        await tester.tap(find.text('藍牙音訊／擴大機'));
        await tester.pumpAndSettle();
        expect(find.textContaining('Onkyo TX-NR6100'), findsOneWidget);
      }

      await guide();
      await tester.tap(find.text('藍牙配對'));
      await tester.pumpAndSettle();
      expect(calls, ['bluetoothSettings']);
      await guide();
      await tester.tap(find.text('影音同步設定'));
      await tester.pumpAndSettle();
      expect(calls, ['bluetoothSettings', 'audioSettings']);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('一進來就是全螢幕、焦點在播放區: 左右跳轉, OK 暫停並把焦點交給播放鍵', (tester) async {
      await open(tester);
      // 電視沒有「離開全螢幕」可言
      expect(find.byTooltip('全螢幕'), findsNothing);
      expect(find.byTooltip('離開全螢幕'), findsNothing);
      expect(find.byTooltip('畫面比例'), findsOneWidget);
      expect(focused(), 'player-surface');
      expect(player.playing, true);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump(const Duration(milliseconds: 150));
      expect(player.seeks, hasLength(1));
      expect(player.seeks.single.inSeconds, inInclusiveRange(28, 33));
      expect(find.text('快進 10 秒'), findsOneWidget);
      // 原生播放器跟上了, 跳轉才算結束
      player.actual = player.seeks.single;
      await tester.pump(const Duration(milliseconds: 300));
      expect(player.playing, true);

      await tester.sendKeyEvent(LogicalKeyboardKey.select, platform: 'android');
      await tester.pump(const Duration(milliseconds: 300));
      expect(player.playing, false);
      expect(focused(), 'player-play');

      // 焦點在控制列上的時候, 左右是在按鈕之間移動, 不是跳轉
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump(const Duration(milliseconds: 300));
      expect(player.seeks, hasLength(1));
      expect(focused(), isNot('player-play'));

      // 遙控器上的播放鍵不管焦點在哪都算
      await tester.sendKeyEvent(LogicalKeyboardKey.mediaPlayPause,
          platform: 'android');
      await tester.pump(const Duration(milliseconds: 300));
      expect(player.playing, true);

      // 控制列自己收起來之後焦點回到播放區, 左右又是跳轉
      await tester.pump(kControlsIdle + const Duration(seconds: 1));
      expect(controlsOpacity(tester), 0);
      expect(focused(), 'player-surface');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump(const Duration(milliseconds: 150));
      expect(player.seeks, hasLength(2));

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('手機遙控: 播放頁把進度報給手機, 手機拖進度條叫得動', (tester) async {
      final host = RecordingHost();
      TvRemoteHost.current = host;
      addTearDown(() {
        TvRemoteHost.current = null;
        host.dispose();
      });
      await open(tester);
      expect(host.player, isNotNull);
      await tester.pump(const Duration(seconds: 1));
      final now = host.published.whereType<NowPlaying>().last;
      expect(now.sn, '1');
      expect(now.playing, true);
      expect(now.duration, 600);

      host.player!.seekTo(300);
      await tester.pump(const Duration(milliseconds: 150));
      expect(player.seeks.single.inSeconds, 300);

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
      expect(host.player, isNull, reason: '關掉播放頁要跟遙控伺服器說一聲');
    });

    testWidgets('手機丟過來的集數從手機看到的那一秒開始', (tester) async {
      levels.install(tester);
      addTearDown(() => levels.remove(tester));
      await resizeViewport(tester, const Size(960, 540));
      await tester.pumpWidget(MaterialApp(
          theme: buildTheme(brightness: Brightness.dark, tv: true),
          home: WatchPage(state: state, sn: '1', startAt: 125)));
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(player.seeks, isNotEmpty);
      expect(player.seeks.first.inSeconds, 125);

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('返回鍵: 播放中先收控制列, 再按一次才離開', (tester) async {
      levels.install(tester);
      addTearDown(() => levels.remove(tester));
      await resizeViewport(tester, const Size(960, 540));
      await tester.pumpWidget(MaterialApp(
          theme: buildTheme(brightness: Brightness.dark, tv: true),
          home: const Scaffold(body: Text('home'))));
      unawaited(tester.state<NavigatorState>(find.byType(Navigator)).push(
          MaterialPageRoute<void>(
              builder: (_) => WatchPage(state: state, sn: '1'))));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(player.playing, true);
      expect(controlsOpacity(tester), 1);

      await tester.binding.handlePopRoute();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(WatchPage), findsOneWidget);
      expect(controlsOpacity(tester), 0);

      await tester.binding.handlePopRoute();
      // 退場動畫跑完之後, 下一個 frame 才把整頁拿掉
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      expect(find.byType(WatchPage), findsNothing);
      expect(find.text('home'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
    });
  });
}
