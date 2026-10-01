import 'dart:io';

import 'package:agp_mobile/src/pages/app_prefs_page.dart';
import 'package:agp_mobile/src/pages/me_tab.dart';
import 'package:agp_mobile/src/state/app_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/temp_dir.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;

  @override
  Future<String?> getApplicationDocumentsPath() async => path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
  @override
  Future<String?> getTemporaryPath() async => path;
}

void main() {
  // CI runs this suite both with the default configuration and with the same
  // APP_UPDATER=false declaration used to build the AAB.
  const updaterDisabled = String.fromEnvironment('APP_UPDATER') == 'false';
  late Directory temp;
  late AppState state;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('agp-updater-build-');
    PathProviderPlatform.instance = _Paths(temp.path);
    SharedPreferences.setMockInitialValues({
      'agp-update-auto-check': true,
      'agp-update-channel': 'nightly',
    });
    PackageInfo.setMockInitialValues(
      appName: 'aniGamerPlus',
      packageName: 'tw.avianjay.agpp',
      version: '1.0.0',
      buildNumber: '123',
      buildSignature: '',
    );
    state = await AppState.boot();
  });

  tearDown(() async {
    state.downloads.dispose();
    state.client.close();
    await deleteTempDir(temp);
  });

  Future<void> showPage(WidgetTester tester, Widget page) async {
    // Lay out the whole settings list so an absent control cannot simply be
    // outside the ListView's viewport.
    tester.view.physicalSize = const Size(1000, 5000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: page)));
    await tester.pumpAndSettle();
  }

  testWidgets('build configuration controls the manual update entry',
      (tester) async {
    await showPage(tester, MeTab(state: state));
    expect(find.text('檢查更新'), updaterDisabled ? findsNothing : findsOneWidget);
    expect(find.text('App 偏好設定'), findsOneWidget);
    expect(find.text('離線下載'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('AAB hides update settings even with saved updater preferences',
      (tester) async {
    await showPage(tester, AppPrefsPage(state: state));
    final updaterControls = updaterDisabled ? findsNothing : findsOneWidget;
    expect(find.text('更新'), updaterControls);
    expect(find.text('更新通道'), updaterControls);
    expect(find.text('開啟 App 時檢查更新'), updaterControls);
    expect(find.text('只在 Wi-Fi 下載'), findsOneWidget);
    expect(find.text('儲存空間'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
