/// 手機遙控的畫面那一層: 電視上怎麼把按鍵「按」下去、配對碼對話框, 以及
/// 手機上的遙控器頁面.
library;

import 'dart:io';

import 'package:agp_mobile/src/pages/search_page.dart';
import 'package:agp_mobile/src/pages/tv_remote_actions.dart';
import 'package:agp_mobile/src/pages/tv_remote_page.dart';
import 'package:agp_mobile/src/state/app_state.dart';
import 'package:agp_mobile/src/state/tv_remote_client.dart';
import 'package:agp_mobile/src/state/tv_remote_host.dart';
import 'package:agp_mobile/src/state/tv_remote_protocol.dart';
import 'package:agp_mobile/src/util/remote_keys.dart';
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

class FakeRemote extends TvRemoteClient {
  FakeRemote() : super(phoneId: 'phone-1', phoneName: 'Pixel');

  final sent = <String>[];

  void show(TvRemotePhase value) {
    phase = value;
    notifyListeners();
  }

  @override
  Future<void> connect(TvDevice target) async =>
      sent.add('connect ${target.host}');

  @override
  void submitPin(String pin) => sent.add('pin $pin');

  @override
  void key(RemoteKey key) => sent.add('key ${key.name}');

  @override
  void text(String value, {bool submit = false}) =>
      sent.add('text $value $submit');

  @override
  void play(String sn, {double? at, bool streaming = false}) =>
      sent.add('play $sn $at');

  @override
  void seek(double to) => sent.add('seek ${to.round()}');

  @override
  void configure(String server, String token) =>
      sent.add('config $server "$token"');
}

class FakeDiscovery extends TvDiscovery {
  FakeDiscovery(this.tvs);

  final List<TvDevice> tvs;

  @override
  Stream<TvDevice> scan({
    Duration timeout = const Duration(seconds: 4),
    List<InternetAddress>? probeHosts,
    List<InternetAddress>? broadcastTargets,
  }) =>
      Stream.fromIterable(tvs);
}

void main() {
  late Directory temp;
  late AppState state;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('agp-remote-ui-');
    PathProviderPlatform.instance = Paths(temp.path);
    SharedPreferences.setMockInitialValues(
        {'agp-server': 'http://localhost:12345'});
    state = await AppState.boot();
    state.offline = true;
  });

  tearDown(() => deleteTempDir(temp));

  group('電視上', () {
    testWidgets('按鍵走實體遙控器那一條路: 方向鍵移焦點, 確認鍵按下去', (tester) async {
      var pressed = '';
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Column(children: [
            TextButton(
                autofocus: true,
                onPressed: () => pressed = 'A',
                child: const Text('A')),
            TextButton(onPressed: () => pressed = 'B', child: const Text('B')),
          ]),
        ),
      ));
      await tester.pump();
      bool focused(String label) =>
          Focus.of(tester.element(find.text(label))).hasPrimaryFocus;
      expect(focused('A'), isTrue);

      expect(RemoteKeys.press(RemoteKey.down), isTrue);
      await tester.pump();
      expect(focused('B'), isTrue);

      RemoteKeys.press(RemoteKey.ok);
      await tester.pump();
      expect(pressed, 'B');
    });

    testWidgets('打字: 填進拿著焦點的輸入框, submit 等於按完成', (tester) async {
      var changed = '';
      var submitted = '';
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: TextField(
            autofocus: true,
            onChanged: (value) => changed = value,
            onSubmitted: (value) => submitted = value,
          ),
        ),
      ));
      await tester.pump();
      expect(RemoteKeys.type('葬送的芙莉蓮', submit: true), isTrue);
      await tester.pump();
      expect(changed, '葬送的芙莉蓮');
      expect(submitted, '葬送的芙莉蓮');
      expect(find.text('葬送的芙莉蓮'), findsOneWidget);

      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      expect(RemoteKeys.type('別的'), isFalse);
    });

    testWidgets('返回先問頁面、首頁一路退回去; 沒有輸入框在等的字拿去搜尋', (tester) async {
      final navigator = GlobalKey<NavigatorState>();
      final actions = AppTvRemoteActions(state, navigator);
      await tester.pumpWidget(MaterialApp(
        navigatorKey: navigator,
        home: const Scaffold(body: Text('home')),
      ));
      for (final name in ['one', 'two']) {
        navigator.currentState!.push(MaterialPageRoute<void>(
            builder: (_) => Scaffold(body: Text(name))));
      }
      await tester.pumpAndSettle();

      actions.key(RemoteKey.back);
      await tester.pumpAndSettle();
      expect(find.text('two'), findsNothing);
      expect(find.text('one'), findsOneWidget);

      actions.key(RemoteKey.home);
      await tester.pumpAndSettle();
      expect(find.text('home'), findsOneWidget);

      // 首頁那一層: 手機上按返回不會把電視上的 App 關掉
      actions.key(RemoteKey.back);
      await tester.pumpAndSettle();
      expect(find.text('home'), findsOneWidget);

      expect(await actions.text('芙莉蓮', submit: true), isNull);
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      expect(find.byType(SearchPage), findsOneWidget);
      expect(
          tester
              .widget<TextField>(find.byKey(const ValueKey('anime-search')))
              .controller!
              .text,
          '芙莉蓮');

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('配對碼: 跳出來、配對結束自己收掉; 被返回鍵關掉等於拒絕', (tester) async {
      final navigator = GlobalKey<NavigatorState>();
      final actions = AppTvRemoteActions(state, navigator);
      await tester.pumpWidget(MaterialApp(
        navigatorKey: navigator,
        home: const Scaffold(body: Text('home')),
      ));
      var rejected = 0;

      final request = PairingRequest('Pixel', '0427', () => rejected++);
      actions.showPairing(request);
      await tester.pumpAndSettle();
      expect(find.text('0 4 2 7'), findsOneWidget);
      expect(find.textContaining('Pixel'), findsOneWidget);
      request.finished.value = true;
      await tester.pumpAndSettle();
      expect(find.text('0 4 2 7'), findsNothing);
      expect(find.text('home'), findsOneWidget);
      expect(rejected, 0);

      final second = PairingRequest('iPhone', '1111', () => rejected++);
      actions.showPairing(second);
      await tester.pumpAndSettle();
      actions.key(RemoteKey.back);
      await tester.pumpAndSettle();
      expect(find.text('1 1 1 1'), findsNothing);
      expect(rejected, 1, reason: '手機那邊不能一直等一個看不到的配對碼');
    });
  });

  group('手機上的遙控器', () {
    late FakeRemote remote;

    setUp(() => remote = FakeRemote());
    tearDown(() => remote.dispose());

    Future<void> open(WidgetTester tester,
        {TvCast? cast, List<TvDevice> found = const []}) async {
      await tester.binding.setSurfaceSize(const Size(420, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(MaterialApp(
        home: TvRemotePage(
          state: state,
          cast: cast,
          remote: remote,
          discovery: FakeDiscovery(found),
        ),
      ));
      await tester.pump();
      await tester.pump();
    }

    testWidgets('列出這個網路上的電視, 點一台就連', (tester) async {
      const tv = TvDevice(id: 'tv-1', name: '客廳電視', host: '192.168.1.20');
      await open(tester, found: [tv]);
      expect(find.text('客廳電視'), findsOneWidget);
      await tester.tap(find.text('客廳電視'));
      await tester.pump();
      expect(remote.sent, ['connect 192.168.1.20']);
    });

    testWidgets('配對碼打滿四位就送出', (tester) async {
      await open(tester);
      remote.device = const TvDevice(id: 'tv-1', name: '客廳電視', host: 'x');
      remote.show(TvRemotePhase.pairing);
      await tester.pump();
      expect(find.textContaining('客廳電視'), findsWidgets);
      await tester.enterText(find.byKey(const ValueKey('remote-pin')), '0427');
      await tester.pump();
      expect(remote.sent.last, 'pin 0427');
    });

    testWidgets('連上之後: 方向鍵、按住連發、打字、把設定傳給電視', (tester) async {
      await open(tester);
      remote.device = const TvDevice(id: 'tv-1', name: '客廳電視', host: 'x');
      remote.tvServer = '';
      remote.show(TvRemotePhase.connected);
      await tester.pump();

      await tester.tap(find.bySemanticsLabel('上'));
      await tester.tap(find.bySemanticsLabel('確認'));
      await tester.tap(find.bySemanticsLabel('返回'));
      await tester.pump();
      expect(remote.sent, ['key up', 'key ok', 'key back']);

      // 按住右鍵不放: 一直送
      remote.sent.clear();
      final hold = await tester
          .startGesture(tester.getCenter(find.bySemanticsLabel('右')));
      await tester.pump(const Duration(milliseconds: 1000));
      await hold.up();
      await tester.pump(const Duration(milliseconds: 500));
      final rights = remote.sent.where((sent) => sent == 'key right').length;
      expect(rights, greaterThan(3));
      expect(remote.sent.every((sent) => sent == 'key right'), isTrue);

      remote.sent.clear();
      await tester.enterText(
          find.byKey(const ValueKey('remote-text')), '葬送的芙莉蓮');
      await tester.tap(find.byTooltip('送到電視'));
      await tester.pump();
      expect(remote.sent, ['text 葬送的芙莉蓮 true']);

      // 電視沒有伺服器, 手機有: 問要不要傳過去 (沒登入就不帶 token)
      remote.sent.clear();
      await tester.tap(find.byKey(const ValueKey('remote-push-config')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('傳過去'));
      await tester.pumpAndSettle();
      expect(remote.sent, ['config http://localhost:12345 ""']);

      // 一樣了就不再問
      remote.tvServer = 'http://localhost:12345';
      remote.show(TvRemotePhase.connected);
      await tester.pump();
      expect(find.byKey(const ValueKey('remote-push-config')), findsNothing);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('電視上在播的時候: 進度條拖到哪就跳到哪', (tester) async {
      await open(tester);
      remote.device = const TvDevice(id: 'tv-1', name: '客廳電視', host: 'x');
      remote.tvServer = 'http://localhost:12345';
      remote.playing = const NowPlaying(
        sn: '42',
        title: '葬送的芙莉蓮',
        episode: '第 5 集',
        position: 0,
        duration: 1000,
        playing: false,
      );
      remote.show(TvRemotePhase.connected);
      await tester.pump();
      expect(find.text('葬送的芙莉蓮'), findsOneWidget);

      final slider = find.byKey(const ValueKey('remote-seek'));
      final box = tester.getRect(slider);
      await tester.tapAt(Offset(box.center.dx, box.center.dy));
      await tester.pump();
      final seek = remote.sent.singleWhere((sent) => sent.startsWith('seek'));
      final to = int.parse(seek.split(' ').last);
      expect(to, inInclusiveRange(400, 600));

      await tester.tap(find.byTooltip('下一集'));
      await tester.pump();
      expect(remote.sent.last, 'key next');

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('從播放頁丟過來的: 連上就叫電視播同一集、同一秒', (tester) async {
      remote.device = const TvDevice(id: 'tv-1', name: '客廳電視', host: 'x');
      remote.phase = TvRemotePhase.connected;
      await open(tester, cast: const TvCast(sn: '42', at: 83.5));
      expect(remote.sent, ['play 42 83.5']);
      expect(find.textContaining('已經丟到'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 4));
    });
  });
}
