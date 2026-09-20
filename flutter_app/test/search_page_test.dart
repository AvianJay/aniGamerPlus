import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:agp_mobile/src/api/client.dart';
import 'package:agp_mobile/src/api/models.dart';
import 'package:agp_mobile/src/pages/search_page.dart';
import 'package:agp_mobile/src/pages/all_tab.dart';
import 'package:agp_mobile/src/state/app_state.dart';
import 'package:agp_mobile/src/state/prefs.dart';
import 'package:agp_mobile/src/theme.dart';
import 'package:agp_mobile/src/widgets/cards.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
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
  late AppState state;
  late Directory temp;
  final requests = <String>[];
  final titles = [
    '相反的你和我 第二季',
    '我的英雄學院 FINAL SEASON',
    '戀上換裝娃娃',
    'BLEACH 死神 千年血戰篇',
    '銀河旅途的故事',
    '夏日與你的約定',
    '星空下的冒險',
    '魔法學院'
  ];
  late List<Map<String, dynamic>> catalog;
  Completer<http.Response>? delayed;
  late Uint8List png;

  setUpAll(() async {
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawPaint(Paint()..color = const Color(0xFF147A8A));
    final picture = recorder.endRecording();
    final raster = await picture.toImage(120, 160);
    png = (await raster.toByteData(format: ui.ImageByteFormat.png))!
        .buffer
        .asUint8List();
    raster.dispose();
    picture.dispose();
    await loadCaptureFonts();
  });

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('agp-search-');
    PathProviderPlatform.instance = _Paths(temp.path);
    SharedPreferences.setMockInitialValues({});
    requests.clear();
    delayed = null;
    catalog = [
      for (var i = 0; i < titles.length; i++)
        {
          'animeSn': 'a$i',
          'videoSn': 'v$i',
          'title': titles[i],
          'cover': 'https://posters.example.test/$i.jpg',
          'info': '2026 / 07 · 共 12 集',
          'popular': '${20 + i} 萬觀看',
        }
    ];
    final client = AgpClient(
        baseUrl: 'http://example.test',
        httpClient: MockClient((request) async {
          if (request.url.path == '/catalog/all.json') {
            final query = request.url.queryParameters['q'] ?? '';
            requests.add(query);
            if (query == 'old' && delayed != null) return delayed!.future;
            final matches = query.isEmpty
                ? catalog
                : catalog
                    .where((e) => (e['title'] as String).contains(query))
                    .toList();
            return http.Response(
                jsonEncode({
                  'items': matches,
                  'total': matches.length,
                  'page': 1,
                  'pages': 1
                }),
                200,
                headers: {'content-type': 'application/json'});
          }
          return http.Response('{}', 404);
        }));
    state = await AppState.boot(client: client);
    state.catalog =
        CatalogIndex(hot: catalog.map(CatalogItem.fromJson).toList());
    await state.thumbnails.init();
    state.thumbnails.seedCatalog(state.catalog.hot);
    final posters = Platform.environment['AGP_POSTER_DIR'];
    for (var i = 0; i < catalog.length; i++) {
      final key = sha1.convert(utf8.encode(catalog[i]['cover'] as String));
      final bytes = posters == null
          ? png
          : await File('$posters/poster-${i % 4}.jpg').readAsBytes();
      await File('${temp.path}/covers/$key.img').writeAsBytes(bytes);
    }
  });

  tearDown(() async {
    state.downloadNetwork.dispose();
    state.downloads.dispose();
    state.thumbnails.dispose();
    state.client.close();
    await deleteTempDir(temp);
  });

  Future<void> open(WidgetTester tester, Widget page,
      {Brightness mode = Brightness.light,
      Size size = const Size(1280, 850),
      double scale = 1}) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final theme = buildTheme(brightness: mode);
    await tester.pumpWidget(RepaintBoundary(
        key: const ValueKey('search-capture'),
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: captureTheme(theme),
          builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(scale)),
              child: child!),
          home: page,
        )));
    await tester.pumpAndSettle();
  }

  Future<void> capture(WidgetTester tester, String name) async {
    await settleImages(tester);
    if (Platform.environment['AGP_UI_CAPTURE'] != '1') return;
    await tester.runAsync(() async {
      final image = await tester
          .renderObject<RenderRepaintBoundary>(
              find.byKey(const ValueKey('search-capture')))
          .toImage(pixelRatio: 1.5);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await File('../.agpwork/$name.png')
          .writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  testWidgets(
      'empty search shows history and real catalog suggestions without requesting all results',
      (tester) async {
    await state.prefs.rememberSearch('相反');
    await state.prefs.rememberSearch('我的英雄');
    await open(tester, SearchPage(state: state));
    expect(find.text('最近搜尋'), findsOneWidget);
    expect(find.text('熱門動畫'), findsOneWidget);
    expect(find.byType(PosterCard), findsNothing);
    expect(requests, isEmpty);
    await capture(tester, 'search-tablet');
    await tester.tap(find.widgetWithText(InputChip, '相反'));
    await tester.pumpAndSettle();
    expect(requests.last, '相反');
    expect(find.byType(PosterCard), findsOneWidget);
    expect(tester.testTextInput.isVisible, false);
    expect(state.prefs.searchHistory.first, '相反');
    await capture(tester, 'search-result-tablet');
    await tester.tap(find.byTooltip('清除搜尋'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('刪除「相反」'));
    await tester.pumpAndSettle();
    expect(state.prefs.searchHistory, ['我的英雄']);
    await tester.tap(find.byTooltip('清除搜尋紀錄'));
    await tester.pumpAndSettle();
    expect(state.prefs.searchHistory, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('tablet catalog uses five columns with real poster files',
      (tester) async {
    await open(
        tester,
        Scaffold(
            appBar: AppBar(title: const Text('所有動畫')),
            body: AllTab(state: state, query: '')));
    expect(find.byType(PosterCard), findsWidgets);
    final grid = tester.widget<SliverGrid>(find.byType(SliverGrid));
    expect(
        (grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount)
            .crossAxisCount,
        5);
    await settleImages(tester);
    expect(tester.takeException(), isNull);
    await capture(tester, 'catalog-tablet');
  });

  testWidgets('phone cards fit at large text sizes', (tester) async {
    await open(tester, Scaffold(body: AllTab(state: state, query: '')),
        mode: Brightness.dark, size: const Size(320, 740), scale: 1.5);
    await settleImages(tester);
    expect(tester.takeException(), isNull);
    final grid = tester.widget<SliverGrid>(find.byType(SliverGrid));
    expect(
        (grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount)
            .crossAxisCount,
        2);
    await capture(tester, 'catalog-phone');
  });

  testWidgets(
      'a previous search response cannot appear during the next debounce window',
      (tester) async {
    delayed = Completer<http.Response>();
    await open(tester, SearchPage(state: state));
    await tester.enterText(find.byKey(const ValueKey('anime-search')), 'old');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(find.byKey(const ValueKey('anime-search')), '相反');
    await tester.pump();
    delayed!.complete(http.Response(
        jsonEncode({
          'items': [catalog[3]],
          'page': 1,
          'pages': 1,
          'total': 1
        }),
        200,
        headers: {'content-type': 'application/json'}));
    await tester.pump();
    expect(find.byType(PosterCard), findsNothing);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(find.byType(PosterCard), findsOneWidget);
    expect(find.text(titles.first), findsOneWidget);
    expect(state.prefs.searchHistory, isEmpty,
        reason: 'typing is not a committed search');
  });

  test(
      'search history persists, deduplicates case-insensitively, and stays bounded',
      () async {
    for (var i = 0; i < 15; i++) {
      await state.prefs.rememberSearch('搜尋 $i');
    }
    await state.prefs.rememberSearch('  CODE   GEASS  ');
    await state.prefs.rememberSearch('code geass');
    final restored = await Prefs.load();
    expect(restored.searchHistory.length, 12);
    expect(restored.searchHistory.first, 'code geass');
    expect(
        restored.searchHistory
            .where((e) => e.toLowerCase() == 'code geass')
            .length,
        1);
  });
}
