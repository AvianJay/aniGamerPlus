/// 「繼續觀看」與「所有動畫 → 點進一部作品」要顯示的東西.
///
/// 這裡驗的是那兩個以前只認片庫的地方現在認得線上看過的集數: 進度表裡只有 sn,
/// 作品名跟集數是播放頁一拿到集數表就整批寫進名稱表的. 沒有那一步, 看了一整晚
/// 線上動畫的首頁永遠是「還沒有看到一半的影片」.
library;

import 'dart:io';

import 'package:agp_mobile/src/api/models.dart';
import 'package:agp_mobile/src/pages/home_tab.dart';
import 'package:agp_mobile/src/state/app_state.dart';
import 'package:agp_mobile/src/theme.dart';
import 'package:agp_mobile/src/widgets/cards.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/temp_dir.dart';

class Paths extends PathProviderPlatform {
  Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
}

/// 一部線上看過、片庫裡沒有的作品
SeriesInfo remoteSeries() => SeriesInfo(
      animeSn: 'a-remote',
      videoSn: '9001',
      title: '線上看的作品',
      cover: 'https://covers.example.test/remote.jpg',
      groups: [
        SeriesGroup(name: '本篇', episodes: [
          SeriesEpisode(videoSn: '9001', episode: '1'),
          SeriesEpisode(videoSn: '9002', episode: '2'),
          SeriesEpisode(videoSn: '9003', episode: '3'),
        ]),
      ],
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temp;
  late AppState state;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('agp-continue-test-');
    PathProviderPlatform.instance = Paths(temp.path);
    SharedPreferences.setMockInitialValues({'agp-server': ''});
    state = await AppState.boot();
    state.offline = true;
    state.booting = false;
  });

  tearDown(() async {
    state.downloadNetwork.dispose();
    state.downloads.dispose();
    state.thumbnails.dispose();
    state.client.close();
    await deleteTempDir(temp);
  });

  void note(int sn, int time, {int duration = 1440, int timestamp = 100}) {
    state.noteWatchTime('$sn',
        WatchTime(time: time, duration: duration, timestamp: timestamp));
  }

  test('片庫裡沒有的集數, 名稱表認出來之後也進得了繼續觀看', () {
    // 還沒有名字之前: 進度表裡只是一個 sn, 認不出是哪一部
    note(9001, 300);
    expect(state.continueWatching, isEmpty);

    state.rememberSeriesNames(remoteSeries());

    final rows = state.continueWatching;
    expect(rows, hasLength(1), reason: '線上看過的作品也該出現在繼續觀看');
    expect(rows.single.name, '線上看的作品');
    expect(rows.single.episode, '1');
    expect(rows.single.local, isFalse, reason: '片庫裡沒有這一集');
    // 卡片要的形狀自己湊得出來, 名稱表已經知道它是誰
    expect(rows.single.cardVideo?.animeName, '線上看的作品');
    expect(rows.single.remainingLabel, contains('剩餘'));
  });

  test('作品資訊查得到「看到第 N 集」', () {
    note(9002, 600, timestamp: 200);
    state.rememberSeriesNames(remoteSeries());

    final last = state.lastWatchedOf('線上看的作品');
    expect(last, isNotNull);
    expect(last!.sn, '9002');
    expect(last.episode, '2');
    expect(last.progress, closeTo(600 / 1440, 0.001));
    expect(state.lastWatchedOf('  線上看的作品  '), isNotNull,
        reason: '前後空白不該影響比對');
    expect(state.lastWatchedOf('別的作品'), isNull);
  });

  test('看完整部作品之後就不再列進繼續觀看', () {
    note(9003, 0, timestamp: 300);
    state.noteWatchTime('9003',
        WatchTime(time: 0, ended: true, duration: 1440, timestamp: 300));
    state.rememberSeriesNames(remoteSeries());

    expect(state.continueWatching, isEmpty);
    // 但「看到哪裡」還在, 作品資訊要說得出「已看完」
    expect(state.lastWatchedOf('線上看的作品')!.time.ended, isTrue);
  });

  test('同一部作品只留最後看的那一集', () {
    note(9001, 300, timestamp: 100);
    note(9003, 120, timestamp: 300);
    note(9002, 60, timestamp: 200);
    state.rememberSeriesNames(remoteSeries());

    final rows = state.continueWatching;
    expect(rows, hasLength(1));
    expect(rows.single.sn, '9003', reason: '要留 timestamp 最新的那一集');
  });

  test('名稱表活得過重開機', () async {
    note(9001, 300);
    state.rememberSeriesNames(remoteSeries());
    await state.flushWatchNames();
    await state.flushWatchTimesToDisk();

    final second = await AppState.boot();
    await second.refreshWatchTimes();

    expect(second.watchNameOf('9001')?.name, '線上看的作品');
    expect(second.continueWatching, hasLength(1));
  });

  testWidgets('首頁那一格畫得出來, 而且是「線上看」那一種', (tester) async {
    note(9001, 300);
    state.rememberSeriesNames(remoteSeries());
    // 進度落盤那個一秒的 debounce 收掉, 不然 widget test 會說還有 Timer 掛著.
    // 真的寫檔要 runAsync —— fake async 圈裡 await 真 I/O 會永遠不回來.
    await tester.runAsync(() async {
      await state.flushWatchTimesToDisk();
      await state.flushWatchNames();
    });

    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(brightness: Brightness.dark),
      home: Scaffold(body: HomeTab(state: state, onSeeAll: () {})),
    ));
    await tester.pump();

    expect(find.text('繼續觀看'), findsOneWidget);
    expect(find.byType(EpisodeCard), findsOneWidget);
    expect(find.text('線上看的作品'), findsOneWidget);
    // 那一句「剩餘 N 分」是這一格存在的理由
    expect(find.textContaining('剩餘'), findsOneWidget);

    // 這一格代表的是一集片庫裡沒有的影片, 所以點下去要走作品資訊那條路
    // (onTap 的分支就是看這個) —— 直接開 sheet 需要真的連線, 這裡只釘住條件
    final row = state.continueWatching.single;
    expect(row.local, isFalse);
    expect(row.cardVideo!.sn, '9001');
    expect(tester.takeException(), isNull);
  });
}
