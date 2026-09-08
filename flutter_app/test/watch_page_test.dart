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
import 'package:agp_mobile/src/pages/watch_page.dart';
import 'package:agp_mobile/src/state/app_state.dart';

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
  final events = StreamController<VideoEvent>.broadcast();
  Duration actual = const Duration(seconds: 20);
  final seeks = <Duration>[];
  double volume = 1;
  bool playing = false;
  double speed = 1;
  int creations = 0;
  @override
  Future<void> init() async {}
  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    creations++;
    return 1;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int id) {
    scheduleMicrotask(() => events.add(VideoEvent(
        eventType: VideoEventType.initialized,
        duration: const Duration(seconds: 600),
        size: const Size(1920, 1080))));
    return events.stream;
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
  Widget buildView(int id) => const ColoredBox(color: Color(0xFF384054));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
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
  setUp(() async {
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
    await player.events.close();
    await temp.delete(recursive: true);
  });
  Future<void> open(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    await tester.pumpWidget(RepaintBoundary(
        key: const ValueKey('capture'),
        child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: ThemeData(fontFamily: 'Roboto'),
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
    await tester.dragFrom(
        box.localToGlobal(Offset(box.size.width * .2, box.size.height * .4)),
        const Offset(0, 60));
    await tester.pump();
    expect(state.prefs.brightness, lessThan(1));
    await tester.dragFrom(
        box.localToGlobal(Offset(box.size.width * .8, box.size.height * .4)),
        const Offset(0, 60));
    await tester.pump();
    expect(player.volume, lessThan(1));
    await tester.tap(find.text('1.0x'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('0.25x'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });
  testWidgets(
      'phone and landscape controls fit and pending seek can be disposed',
      (tester) async {
    await open(tester);
    await tester.binding.setSurfaceSize(const Size(390, 844));
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('全螢幕'));
    await tester.binding.setSurfaceSize(const Size(1000, 650));
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
    await tester.binding.setSurfaceSize(const Size(1280, 882));
    await tester.pump();
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
  testWidgets('fullscreen toggle keeps the rightmost slot in both modes',
      (tester) async {
    // 進出全螢幕會多一顆「畫面比例」出來. 它要是插在全螢幕鍵右邊, 整排就往
    // 左挪一格, 使用者照原來的位置按下去按到的是畫面比例 —— 動畫瘋不會這樣,
    // 這裡把「最右邊永遠是全螢幕」釘住.
    await open(tester);
    await tester.binding.setSurfaceSize(const Size(1280, 882));
    await tester.pump();
    double x(String tooltip) => tester.getCenter(find.byTooltip(tooltip)).dx;
    expect(x('全螢幕'), greaterThan(x('設定')));
    await tester.tap(find.byTooltip('全螢幕'));
    await tester.pump(const Duration(milliseconds: 350));
    expect(x('離開全螢幕'), greaterThan(x('畫面比例')));
    expect(x('畫面比例'), greaterThan(x('設定')));
    await tester.pumpWidget(const SizedBox());
  });
}
