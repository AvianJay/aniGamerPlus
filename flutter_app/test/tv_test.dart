/// 電視版面: 左邊的分頁列、掃碼設定那一塊、卡片的焦點框.
library;

import 'dart:io';

import 'package:agp_mobile/src/pages/root_page.dart';
import 'package:agp_mobile/src/state/app_state.dart';
import 'package:agp_mobile/src/state/remote_setup.dart';
import 'package:agp_mobile/src/util/device.dart';
import 'package:agp_mobile/src/widgets/cards.dart';
import 'package:agp_mobile/src/widgets/common.dart';
import 'package:agp_mobile/src/widgets/remote_setup_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/temp_dir.dart';

/// flutter_test 把每一個 HttpClient 都換成一律回 400 的假貨, 免得測試不小心
/// 連到外面. 這裡連的是自己開在 loopback 上的那台, 要真的.
class RealHttp extends HttpOverrides {}

class Paths extends PathProviderPlatform {
  Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
}

void main() {
  tearDown(() => Device.tv = false);

  group('分頁', () {
    late Directory temp;
    late AppState state;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('agp-tv-test-');
      PathProviderPlatform.instance = Paths(temp.path);
      SharedPreferences.setMockInitialValues(
          {'agp-server': 'http://localhost:12345'});
      state = await AppState.boot();
      state.offline = true;
    });

    tearDown(() => deleteTempDir(temp));

    testWidgets('電視: 分頁移到左邊', (tester) async {
      Device.tv = true;
      await tester.pumpWidget(MaterialApp(home: RootPage(state: state)));
      await tester.pump();
      expect(find.byType(NavigationRail), findsOneWidget);
      expect(find.byType(NavigationBar), findsNothing);

      await tester.tap(find.text('收藏').last);
      await tester.pump();
      expect(
          tester
              .widget<NavigationRail>(find.byType(NavigationRail))
              .selectedIndex,
          2);

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('手機: 還是底下那一排', (tester) async {
      await tester.pumpWidget(MaterialApp(home: RootPage(state: state)));
      await tester.pump();
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.byType(NavigationRail), findsNothing);

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 2));
    });
  });

  testWidgets('掃碼設定: 顯示 QR 碼, 手機送出之後這一塊說完成', (tester) async {
    RemoteSetupForm? got;
    // 在真的時間裡蓋起來: 伺服器是在 initState 裡開的, 開在測試的假時間裡的話,
    // 它處理請求的每一步都要等 pump, 而手機那一端又在等它回應
    await tester.runAsync(() => tester.pumpWidget(MaterialApp(
          home: Scaffold(
            body: Center(
              child: RemoteSetupPanel(
                host: InternetAddress.loopbackIPv4,
                onSubmit: (form) async {
                  got = form;
                  return null;
                },
              ),
            ),
          ),
        )));

    // 伺服器是真的, 要在真的時間裡開起來
    Uri? url;
    for (var i = 0; i < 100 && url == null; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
      final text = find.byType(SelectableText);
      if (text.evaluate().isNotEmpty) {
        url = Uri.parse(tester.widget<SelectableText>(text).data!);
      }
    }
    expect(url, isNotNull);
    expect(find.byKey(const ValueKey('remote-setup-qr')), findsOneWidget);
    expect(find.text('等手機掃碼…'), findsOneWidget);

    // 手機那一端送出去, 等這一塊跟上
    final client =
        HttpOverrides.runWithHttpOverrides(HttpClient.new, RealHttp());
    addTearDown(() => client.close(force: true));
    final sent = (await tester.runAsync(() async {
      final request = await client.postUrl(url!);
      request.headers.contentType =
          ContentType('application', 'x-www-form-urlencoded', charset: 'utf-8');
      request.write('server=http%3A%2F%2F192.168.1.10%3A5000');
      return request.close();
    }))!;
    for (var i = 0; i < 100 && find.text('完成！').evaluate().isEmpty; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    expect(got?.server, 'http://192.168.1.10:5000');
    expect(find.text('完成！'), findsOneWidget);
    expect(sent.statusCode, 200);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('卡片: 遙控器移到時畫框, 手指點下去不會', (tester) async {
    var taps = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 150,
            child: PosterCard(title: '測試', onTap: () => taps++),
          ),
        ),
      ),
    ));
    BoxBorder? border() => (tester
            .widget<DecoratedBox>(find
                .descendant(
                    of: find.byType(FocusFrame),
                    matching: find.byType(DecoratedBox))
                .first)
            .decoration as BoxDecoration)
        .border;

    await tester.tap(find.byType(PosterCard));
    await tester.pump();
    expect(taps, 1);
    expect(border(), isNull);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(border(), isNotNull);

    await tester.sendKeyEvent(LogicalKeyboardKey.select, platform: 'android');
    await tester.pump();
    expect(taps, 2);
  });
}
