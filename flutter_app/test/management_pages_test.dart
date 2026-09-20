import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:agp_mobile/src/api/client.dart';
import 'package:agp_mobile/src/api/models.dart';
import 'package:agp_mobile/src/pages/app_prefs_page.dart';
import 'package:agp_mobile/src/pages/downloads_page.dart';
import 'package:agp_mobile/src/pages/settings_page.dart';
import 'package:agp_mobile/src/state/app_state.dart';
import 'package:agp_mobile/src/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/temp_dir.dart';
import 'support/ui_capture.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late AppState state;
  late Map<String, dynamic> config;
  final uploads = <Map<String, dynamic>>[];
  Completer<void>? saveWait;

  setUpAll(loadCaptureFonts);

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('agp-management-');
    PathProviderPlatform.instance = _Paths(temp.path);
    SharedPreferences.setMockInitialValues({});
    uploads.clear();
    saveWait = null;
    config = {
      'bangumi_dir': '/anime',
      'temp_dir': '',
      'download_resolution': '1080',
      'default_download_mode': 'latest',
      'check_frequency': 5,
      'multi-thread': 2,
      'multi_downloading_segment': 4,
      'download_cd': 0,
      'parse_sn_cd': 3,
      'quantity_of_logs': 7,
      'use_proxy': false,
      'proxy': 'socks5://user:p%40ss%3Aword@[::1]:1080',
      'browser_fingerprint': {'ja3': 'fixture', 'akamai': 'fixture'},
      'plugins': {'keep': true},
    };
    final client = AgpClient(
        baseUrl: 'http://example.test',
        httpClient: MockClient((request) async {
          if (request.url.path == '/data/config.json') {
            return http.Response(jsonEncode(config), 200,
                headers: {'content-type': 'application/json'});
          }
          if (request.url.path == '/uploadConfig') {
            uploads.add(jsonDecode(request.body) as Map<String, dynamic>);
            await saveWait?.future;
            config = uploads.last;
            return http.Response('{"status":200}', 200);
          }
          return http.Response('{}', 404);
        }));
    state = await AppState.boot(client: client);
    state.offline = true;
    state.downloads.concurrency = 0;
  });

  tearDown(() async {
    state.downloadNetwork.dispose();
    state.downloads.dispose();
    state.thumbnails.dispose();
    state.client.close();
    await deleteTempDir(temp);
  });

  Future<void> open(
    WidgetTester tester,
    Widget page, {
    Size size = const Size(360, 780),
    Brightness brightness = Brightness.dark,
    double scale = 1,
  }) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(RepaintBoundary(
      key: const ValueKey('management-capture'),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: captureTheme(buildTheme(brightness: brightness)),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: page,
      ),
    ));
    await tester.pump();
  }

  Future<void> settleIo(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 15)));
      await tester.pump();
    }
  }

  Future<void> capture(WidgetTester tester, String name) async {
    if (Platform.environment['AGP_UI_CAPTURE'] != '1') return;
    await tester.pump(const Duration(milliseconds: 300));
    final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const ValueKey('management-capture')));
    await tester.runAsync(() async {
      final raster = await boundary.toImage(pixelRatio: 2);
      final png = await raster.toByteData(format: ui.ImageByteFormat.png);
      final file = File('../.agpwork/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(png!.buffer.asUint8List());
      raster.dispose();
    });
  }

  testWidgets('download rows remain usable on a small phone with large text',
      (tester) async {
    await tester.runAsync(() async {
      await state.downloads.enqueue(
          VideoItem(
              sn: '101',
              animeName: '很長的動畫作品名稱：第一季特別篇',
              episode: '12',
              resolution: 1080),
          withDanmaku: false);
      await state.downloads.pause('101');
      await state.downloads.enqueue(
          VideoItem(
              sn: '102', animeName: '另一部動畫', episode: '3', resolution: 720),
          withDanmaku: false);
    });
    await open(tester, DownloadsPage(state: state),
        size: const Size(320, 740), scale: 1.4);
    await settleIo(tester);
    expect(tester.takeException(), isNull);
    expect(find.byTooltip('繼續'), findsOneWidget);
    expect(
        tester.getSize(find.byTooltip('繼續')).width, greaterThanOrEqualTo(48));
    await capture(tester, 'downloads-small-phone');
    await tester.tap(find.text('已完成 0'));
    await tester.pump();
    expect(find.text('還沒有已完成的下載'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('preferences and choice sheets scroll in short landscape windows',
      (tester) async {
    await open(tester, AppPrefsPage(state: state),
        size: const Size(740, 320), scale: 1.4);
    await tester.tap(find.text('預設播放速度'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('2.0×'));
    await tester.tap(find.text('2.0×'));
    await tester.pumpAndSettle();
    expect(state.prefs.rate, 2);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'invalid server values never upload and valid edits preserve unrelated settings',
      (tester) async {
    await open(tester, SettingsPage(state: state));
    await tester.pumpAndSettle();
    final field = find.byKey(const ValueKey('setting-multi-thread'));
    await tester.scrollUntilVisible(field, 400,
        scrollable: find.byType(Scrollable).first);
    await tester.enterText(field, '0');
    await tester.tap(find.text('儲存'));
    await tester.pumpAndSettle();
    expect(uploads, isEmpty);
    expect(find.text('請修正 1 個欄位'), findsOneWidget);
    await tester.enterText(field, '3');
    saveWait = Completer<void>();
    await tester.tap(find.text('儲存'));
    await tester.pump();
    expect(uploads.length, 1);
    expect(uploads.single['multi-thread'], 3);
    expect(uploads.single['plugins'], {'keep': true});
    expect(uploads.single['proxy'], 'socks5://user:p%40ss%3Aword@[::1]:1080');
    expect(find.text('儲存中…'), findsOneWidget);
    expect(find.byWidgetPredicate((w) => w is AbsorbPointer && w.absorbing),
        findsWidgets);
    saveWait!.complete();
    await tester.pumpAndSettle();
    expect(find.text('設定與伺服器一致'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'discard dialog can cancel and then actually return to the previous page',
      (tester) async {
    await open(
        tester,
        Scaffold(
            body: Builder(
                builder: (context) => TextButton(
                    onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                            builder: (_) => SettingsPage(state: state))),
                    child: const Text('開啟設定')))));
    await tester.tap(find.text('開啟設定'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('setting-bangumi_dir')), '/changed');
    await tester.pump();
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('/changed'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('離開'));
    await tester.pumpAndSettle();
    expect(find.text('開啟設定'), findsOneWidget);
    expect(find.byType(SettingsPage), findsNothing);
    expect(uploads, isEmpty);
  });

  testWidgets('light settings keep readable labels and a usable narrow layout',
      (tester) async {
    await open(tester, SettingsPage(state: state),
        brightness: Brightness.light, size: const Size(320, 740), scale: 1.25);
    await tester.pumpAndSettle();
    final heading = tester.widget<Text>(find.text('路徑設定'));
    expect(heading.style!.color!.computeLuminance(), lessThan(0.45));
    expect(tester.takeException(), isNull);
    await capture(tester, 'settings-light-phone');
    await tester.pumpWidget(const SizedBox());
  });
}
