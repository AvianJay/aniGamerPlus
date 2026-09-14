/// 「下載單集到手機」與「選集下載到手機」.
///
/// 這兩條路以前都被 episode.local 擋著: 伺服器片庫裡還沒有的集數, 長按選單
/// 連選項都不給, 也沒有一次挑好幾集的地方. 這裡拿一份假的 /watch/series.json
/// 把作品資訊那張 sheet 叫起來, 驗介面真的給得出那兩條路.
///
/// 網路全部避開: client.baseUrl 留空, 劇集表直接塞進 client 的 memo, 封面
/// 一律留空字串 —— 給了 URL 的話 CoverImage 會真的去抓圖, 測試裡沒有那台
/// 伺服器, 留下來的 timeout Timer 還會把測試弄壞.
library;

import 'dart:io';

import 'package:agp_mobile/src/api/models.dart';
import 'package:agp_mobile/src/pages/anime_sheet.dart';
import 'package:agp_mobile/src/state/app_state.dart';
import 'package:agp_mobile/src/state/downloads.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

class Paths extends PathProviderPlatform {
  Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
}

/// 一集. local = 伺服器片庫裡已經有這個檔案了.
Map<String, dynamic> ep(String sn, String episode, {bool local = false}) => {
      'videoSn': sn,
      'episode': episode,
      'cover': '',
      'local': local,
      'resolution': local ? 1080 : 0,
    };

/// /watch/series.json 的形狀. 人氣/評分/總集數那些欄位一律留空 —— 它們會被
/// 畫成 hero 上的小標籤, 標籤上的字跟集數格子的字撞在一起就沒辦法用 find.text
/// 指認集數了.
Map<String, dynamic> seriesJson(
  String videoSn,
  List<Map<String, dynamic>> episodes,
) =>
    {
      'animeSn': '',
      'videoSn': videoSn,
      'title': '測試動畫',
      'cover': '',
      'content': '',
      'groups': [
        {'name': '第一季', 'episodes': episodes},
      ],
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temp;
  late AppState state;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('agp-picker-test-');
    PathProviderPlatform.instance = Paths(temp.path);
    SharedPreferences.setMockInitialValues({'agp-server': ''});
    state = await AppState.boot();
    // 這裡驗的是「有沒有排進佇列」, 不是真的搬位元組: 幫浦關掉, queued 就
    // 停在 queued
    state.downloads.concurrency = 0;
  });

  tearDown(() async {
    state.downloads.dispose();
    await temp.delete(recursive: true);
  });

  /// 真的寫檔跟 widget test 的 fake async 是兩個世界: I/O 本身要讓真的
  /// event loop 跑得到 (runAsync), 接在後面的那段 microtask 又只有 pump()
  /// 會清. 兩件事輪流做, 直到條件成立為止.
  Future<void> settle(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 40; i++) {
      if (done()) return;
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    fail('等不到寫檔完成');
  }

  /// 開一張作品資訊 sheet. [videoSn] 每個測試都要不一樣 —— anime_sheet.dart
  /// 的 _detailCache 是檔案層級的, 同一支測試檔裡活過每一個 test.
  Future<void> open(
    WidgetTester tester,
    String videoSn,
    List<Map<String, dynamic>> episodes,
  ) async {
    state.client.seedSeriesJson(videoSn, seriesJson(videoSn, episodes));
    // 預設的 800x600 放不下整張 sheet, 集數格子會落在 ListView 的可視範圍外,
    // 根本不會被 build 出來
    await tester.binding.setSurfaceSize(const Size(1000, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showAnimeSheet(context, state, videoSn: videoSn),
            child: const Text('開啟作品資訊'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('開啟作品資訊'));
    await tester.pumpAndSettle();
  }

  ListTile tileOf(WidgetTester tester, String title) => tester.widget<ListTile>(
        find.ancestor(of: find.text(title), matching: find.byType(ListTile)),
      );

  testWidgets('伺服器上還沒有的集數, 長按照樣給得出「下載單集到手機」', (tester) async {
    await open(tester, 'sheet-a', [
      ep('l1', '1', local: true),
      ep('r2', '2'),
    ]);

    await tester.longPress(find.text('2'));
    await tester.pumpAndSettle();

    expect(find.text('下載單集到手機'), findsOneWidget);
    expect(find.text('伺服器上還沒有這一集，抓完會自動存到手機'), findsOneWidget);
    expect(tileOf(tester, '下載單集到手機').enabled, isTrue);
  });

  testWidgets('沒有管理員權限時那一項擺出來但按不下去', (tester) async {
    // 開了帳號系統又不是管理員: 伺服器任務排不進去, 所以這條路走不通 ——
    // 但要讓使用者看得到為什麼, 不是整個藏起來
    state.serverInfo = ServerInfo(userControl: true);

    await open(tester, 'sheet-b', [ep('r2', '2')]);
    await tester.longPress(find.text('2'));
    await tester.pumpAndSettle();

    expect(find.text('下載單集到手機'), findsOneWidget);
    expect(find.text('伺服器上還沒有這一集，需要管理員權限'), findsOneWidget);
    expect(tileOf(tester, '下載單集到手機').enabled, isFalse);
    expect(find.text('加入伺服器下載佇列'), findsNothing);
  });

  testWidgets('「選集下載到手機」不管伺服器上有沒有片都在', (tester) async {
    state.serverInfo = ServerInfo(userControl: true);

    await open(tester, 'sheet-c', [ep('r2', '2'), ep('r3', '3')]);

    expect(find.text('加入下載'), findsNothing, reason: '排伺服器任務要管理員');
    expect(find.text('選集下載到手機'), findsOneWidget);
  });

  testWidgets('挑好的集數真的進手機的下載佇列', (tester) async {
    await open(tester, 'sheet-d', [
      ep('l1', '1', local: true),
      ep('r2', '2'),
    ]);

    await tester.tap(find.text('選集下載到手機'));
    await tester.pumpAndSettle();

    // 空方格只有選集那張 sheet 上有, 背後那張用的是別的圖示
    final blanks = find.byIcon(Icons.check_box_outline_blank_rounded);
    expect(blanks, findsNWidgets(2));
    expect(find.text('選一些集數'), findsOneWidget);

    await tester.tap(blanks.first);
    await tester.pumpAndSettle();
    expect(find.text('下載 1 集到手機'), findsOneWidget);

    await tester.tap(find.text('下載 1 集到手機'));
    await settle(tester, () => state.downloads.entryFor('l1') != null);

    expect(state.downloads.entryFor('l1')!.status, DownloadStatus.queued);
    expect(state.downloads.entryFor('r2'), isNull,
        reason: '沒挑的那一集不該跟著進佇列');

    // toast 是 3.2 秒的 SnackBar, 燒不完的話測試結束時會抱怨還有 Timer 掛著
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
  });

  testWidgets('已經在手機上的集數挑不動, 全選也跳過它', (tester) async {
    await tester.runAsync(() => state.downloads.enqueue(
          VideoItem(sn: 'l1', animeName: '測試動畫', episode: '1'),
        ));

    await open(tester, 'sheet-e', [
      ep('l1', '1', local: true),
      ep('r2', '2'),
    ]);

    await tester.tap(find.text('選集下載到手機'));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.check_box_outline_blank_rounded), findsOneWidget,
        reason: '已經在手機上的那一集不該還能勾');

    await tester.tap(find.text('全選'));
    await tester.pumpAndSettle();
    expect(find.text('下載 1 集到手機'), findsOneWidget);
  });
}
