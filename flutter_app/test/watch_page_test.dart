import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import 'package:wakelock_plus_platform_interface/wakelock_plus_platform_interface.dart';
import 'package:agp_mobile/src/api/models.dart';
import 'package:agp_mobile/src/pages/watch_page.dart';
import 'package:agp_mobile/src/danmaku/danmaku_overlay.dart';
import 'package:agp_mobile/src/state/app_state.dart';
import 'package:agp_mobile/src/theme.dart';

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

class DelayedPlayer extends VideoPlayerPlatform {
  // 一個 id 一條事件流, 跟真的平台一樣. 共用一條的話, 第二個 controller 建起來
  // 時第一個 (停在架上等使用者回來的那個) 會收到第二份 initialized, 撞上
  // video_player 內部的 '!initializingCompleter.isCompleted'.
  final Map<int, StreamController<VideoEvent>> streams = {};
  Duration actual = const Duration(seconds: 20);
  final seeks = <Duration>[];
  double volume = 1;
  bool playing = false;
  double speed = 1;
  int creations = 0;
  Uint8List? frame;

  /// 跳轉之後回報「在緩衝」—— 真的播放器跳到沒載過的地方就是這樣
  bool bufferOnSeek = false;

  /// 第一個播放器的那一條. 多數測試只會有這一個.
  StreamController<VideoEvent> get events => _streamFor(1);

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
    creations++;
    return creations;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int id) {
    final stream = _streamFor(id);
    scheduleMicrotask(() {
      if (stream.isClosed) return;
      stream.add(VideoEvent(
          eventType: VideoEventType.initialized,
          duration: const Duration(seconds: 600),
          size: const Size(1920, 1080)));
    });
    return stream.stream;
  }

  @override
  Future<void> dispose(int id) async {}
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
}
