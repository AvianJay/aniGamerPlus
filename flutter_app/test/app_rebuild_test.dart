/// AppState 一動, 不相干的畫面不該跟著重建.
///
/// 播放中每十秒記一次進度, 以前每一次都會讓整個 app —— 包括正在播的那一頁
/// 和壓在底下的五個分頁 —— 全部重建一次.
library;

import 'dart:io';

import 'package:agp_mobile/src/api/models.dart';
import 'package:agp_mobile/src/app.dart';
import 'package:agp_mobile/src/state/app_state.dart';
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

void main() {
  late Directory temp;
  late AppState state;

  // 在 setUp 裡開機, 跟其它測試一樣: 測試環境沒有 connectivity 那個平台
  // 通道, 在測試本體裡開機的話那個錯會被算成這個測試失敗
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('agp-rebuild-test-');
    PathProviderPlatform.instance = Paths(temp.path);
    SharedPreferences.setMockInitialValues({});
    state = await AppState.boot();
  });

  tearDown(() => deleteTempDir(temp));

  testWidgets('AppState 通知的時候, 疊在上面的頁面不會被整頁重建', (tester) async {
    await tester.pumpWidget(AgpApp(state: state));
    await tester.pump();

    // 播放頁就是這樣開的: MaterialPageRoute(builder: (_) => WatchPage(...)),
    // 而且整頁到處都在 Theme.of(context)
    var pages = 0;
    var builds = 0;
    tester.state<NavigatorState>(find.byType(Navigator)).push(
      MaterialPageRoute<void>(builder: (context) {
        pages++;
        return Builder(builder: (context) {
          Theme.of(context);
          builds++;
          return const SizedBox();
        });
      }),
    );
    await tester.pumpAndSettle();
    final pagesBefore = pages;
    final buildsBefore = builds;

    for (var i = 0; i < 3; i++) {
      state.noteWatchTime(
          '1', WatchTime(time: 10 + i, duration: 600, timestamp: 1));
      await tester.pump();
    }
    expect(pages, pagesBefore,
        reason: 'MaterialApp 跟著 AppState 重建, Navigator 就叫每一頁從 builder 整個重來');
    expect(builds, buildsBefore,
        reason: '主題每次都是新的一份, 內容一樣卻不相等, 用到它的全部跟著重建');

    await tester.pumpWidget(const SizedBox());
    // 進度落盤那一秒的 debounce 走完
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('換主題照樣馬上生效', (tester) async {
    await tester.pumpWidget(AgpApp(state: state));
    await tester.pump();
    Brightness brightness() =>
        Theme.of(tester.element(find.byType(Navigator))).brightness;
    expect(brightness(), Brightness.light);

    await tester.runAsync(() => state.setThemeMode('dark'));
    await tester.pumpAndSettle();
    expect(brightness(), Brightness.dark);
    await tester.pumpWidget(const SizedBox());
  });
}
