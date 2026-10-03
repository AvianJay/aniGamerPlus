/// 手機遙控電視: 配對、指令、狀態回報、找電視.
///
/// 電視 (TvRemoteHost) 跟手機 (TvRemoteClient) 都是真的, 開在 loopback 上;
/// 只有「在電視畫面上做事」那一層換成記錄下來的假貨.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agp_mobile/src/state/tv_remote_client.dart';
import 'package:agp_mobile/src/state/tv_remote_host.dart';
import 'package:agp_mobile/src/state/tv_remote_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeActions implements TvRemoteActions {
  final keys = <RemoteKey>[];
  final texts = <(String, bool)>[];
  final plays = <(String, double?, bool)>[];
  final configs = <(String, String)>[];
  final connections = <String>[];
  final pairings = <PairingRequest>[];

  /// text / play / configure 回的話 (null = 成功)
  String? answer;

  ({String server, String user}) current =
      (server: 'http://10.0.0.2:5000', user: 'ani');

  @override
  ({String server, String user}) get status => current;

  @override
  void key(RemoteKey key) => keys.add(key);

  @override
  Future<String?> text(String value, {required bool submit}) async {
    texts.add((value, submit));
    return answer;
  }

  @override
  Future<String?> play(String sn, {double? at, bool streaming = false}) async {
    plays.add((sn, at, streaming));
    return answer;
  }

  @override
  Future<String?> configure(String server, String token) async {
    configs.add((server, token));
    return answer;
  }

  @override
  void showPairing(PairingRequest request) => pairings.add(request);

  @override
  void connected(String phoneName) => connections.add(phoneName);
}

class FakePlayer implements RemotePlayer {
  final seeks = <double>[];

  @override
  void seekTo(double seconds) => seeks.add(seconds);
}

Future<void> until(bool Function() done,
    {Duration timeout = const Duration(seconds: 5)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('等不到條件成立');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  late FakeActions actions;
  late TvRemoteHost host;
  late TvDevice tv;
  final clients = <TvRemoteClient>[];
  var saved = <TvDevice>[];

  TvRemoteClient phone({String id = 'phone-1', String name = 'Pixel'}) {
    final client = TvRemoteClient(
      phoneId: id,
      phoneName: name,
      saved: saved,
      onSavedChanged: (tvs) async => saved = tvs,
    );
    clients.add(client);
    return client;
  }

  /// 一路配對到連上
  Future<TvRemoteClient> paired() async {
    final client = phone();
    await client.connect(tv);
    await until(() => client.phase == TvRemotePhase.pairing);
    client.submitPin(actions.pairings.last.pin);
    await until(() => client.connected);
    return client;
  }

  setUp(() async {
    actions = FakeActions();
    saved = [];
    host = TvRemoteHost(
      actions: actions,
      id: 'tv-1',
      name: '客廳電視',
      port: 0,
      discoveryPort: 0,
    );
    await host.start();
    tv = TvDevice(
        id: '', name: '127.0.0.1', host: '127.0.0.1', port: host.boundPort);
  });

  tearDown(() async {
    for (final client in clients) {
      client.dispose();
    }
    clients.clear();
    await host.stop();
    host.dispose();
  });

  test('第一次要輸入電視上的配對碼, 之後憑 token 直接連', () async {
    final client = phone();
    await client.connect(tv);
    await until(() => client.phase == TvRemotePhase.pairing);
    expect(actions.pairings, hasLength(1));
    final request = actions.pairings.single;
    expect(request.phoneName, 'Pixel');
    expect(request.pin, matches(RegExp(r'^\d{4}$')));

    // 打錯一次: 還能再試
    client.submitPin(request.pin == '0000' ? '1111' : '0000');
    await until(() => client.message.isNotEmpty);
    expect(client.phase, TvRemotePhase.pairing);
    expect(client.pinAttemptsLeft, 2);

    client.submitPin(request.pin);
    await until(() => client.connected);
    expect(request.finished.value, isTrue, reason: '電視上的配對碼要收掉');
    expect(client.device!.name, '客廳電視');
    expect(client.device!.id, 'tv-1');
    expect(client.device!.token, isNotEmpty);
    expect(client.tvServer, 'http://10.0.0.2:5000');
    expect(client.tvUser, 'ani');
    expect(host.paired.single.id, 'phone-1');
    expect(host.paired.single.token, client.device!.token);
    expect(actions.connections, ['Pixel']);
    expect(saved.single.token, client.device!.token);

    // 同一支手機再連一次 (手上只有位址): 不必再配對
    client.disconnect();
    final again = phone();
    await again.connect(tv);
    await until(() => again.connected);
    expect(actions.pairings, hasLength(1));
    expect(actions.connections, ['Pixel', 'Pixel']);
  });

  test('配對碼錯三次就斷線, 什麼都沒記下來', () async {
    final client = phone();
    await client.connect(tv);
    await until(() => client.phase == TvRemotePhase.pairing);
    final pin = actions.pairings.single.pin;
    final wrong = pin == '0000' ? '1111' : '0000';
    for (var i = 0; i < 3; i++) {
      client.submitPin(wrong);
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }
    await until(() => client.phase == TvRemotePhase.failed);
    expect(client.message, contains('太多次'));
    expect(actions.pairings.single.finished.value, isTrue);
    expect(host.paired, isEmpty);

    // 馬上重連換一組新的來猜: 先等一下
    final retry = phone();
    await retry.connect(tv);
    await until(() => retry.phase == TvRemotePhase.failed);
    expect(retry.message, contains('等半分鐘'));
    expect(actions.pairings, hasLength(1), reason: '電視上不該又跳出一組配對碼');
  });

  test('電視上按拒絕, 手機就知道被拒絕了', () async {
    final client = phone();
    await client.connect(tv);
    await until(() => actions.pairings.isNotEmpty);
    actions.pairings.single.reject();
    await until(() => client.phase == TvRemotePhase.failed);
    expect(client.message, contains('拒絕'));
  });

  test('一支手機正在配對時, 另一支先等', () async {
    final first = phone();
    await first.connect(tv);
    await until(() => first.phase == TvRemotePhase.pairing);
    final second = phone(id: 'phone-2', name: 'iPhone');
    await second.connect(tv);
    await until(() => second.phase == TvRemotePhase.failed);
    expect(second.message, contains('另一支手機'));
    expect(actions.pairings, hasLength(1));
  });

  test('配對過才能送指令; 送到的指令原樣交給電視', () async {
    // 沒打招呼就想按鍵: 直接被請出去
    final raw =
        await WebSocket.connect('ws://127.0.0.1:${host.boundPort}/remote/ws');
    final replies = <String>[];
    final closed = Completer<void>();
    raw.listen((data) => replies.add('$data'), onDone: closed.complete);
    raw.add(jsonEncode({'t': 'key', 'k': 'up'}));
    await closed.future.timeout(const Duration(seconds: 3));
    expect(replies.single, contains('"error"'));
    expect(actions.keys, isEmpty);

    final client = await paired();
    final notices = <String>[];
    final subscription = client.notices.listen(notices.add);
    addTearDown(subscription.cancel);

    client.key(RemoteKey.up);
    client.key(RemoteKey.ok);
    client.key(RemoteKey.volumeUp);
    client.key(RemoteKey.volumeDown);
    client.key(RemoteKey.mute);
    client.text('葬送的芙莉蓮', submit: true);
    client.play('12345', at: 83.5, streaming: true);
    client.configure('http://192.168.1.10:5000', 'secret-token');
    await until(() => actions.configs.isNotEmpty);
    expect(actions.keys, [
      RemoteKey.up,
      RemoteKey.ok,
      RemoteKey.volumeUp,
      RemoteKey.volumeDown,
      RemoteKey.mute
    ]);
    expect(actions.texts.single, ('葬送的芙莉蓮', true));
    expect(actions.plays.single, ('12345', 83.5, true));
    expect(
        actions.configs.single, ('http://192.168.1.10:5000', 'secret-token'));
    await until(() => notices.isNotEmpty);
    expect(notices.single, contains('電視已經換上'));

    // 電視那邊做不到的, 原因送回手機
    actions.answer = '電視還沒設定伺服器。';
    client.play('999');
    await until(() => notices.length == 2);
    expect(notices.last, '電視還沒設定伺服器。');

    client.play('not-a-sn');
    await until(() => notices.length == 3);
    expect(notices.last, contains('看不懂'));
    expect(actions.plays, hasLength(2));
  });

  test('電視報告在播什麼, 手機拖進度條叫得動播放頁', () async {
    final client = await paired();
    expect(client.playing, isNull);

    final player = FakePlayer();
    host.attachPlayer(player);
    host.publish(const NowPlaying(
      sn: '42',
      title: '葬送的芙莉蓮',
      episode: '第 5 集',
      position: 60,
      duration: 1440,
      playing: false,
    ));
    await until(() => client.playing != null);
    expect(client.playing!.title, '葬送的芙莉蓮');
    expect(client.position, 60);

    client.seek(300);
    // 手機這邊先跳過去, 不等電視回報
    expect(client.position, 300);
    await until(() => player.seeks.isNotEmpty);
    expect(player.seeks.single, 300);

    // 播放頁關掉: 手機上的那一塊也收掉
    host.detachPlayer(player);
    await until(() => client.playing == null);

    // 沒有在播的時候拖進度條: 說一聲
    final notices = <String>[];
    final subscription = client.notices.listen(notices.add);
    addTearDown(subscription.cancel);
    client.seek(10);
    await until(() => notices.isNotEmpty);
    expect(notices.single, contains('沒有在播放'));
  });

  test('伺服器 / 帳號換了才告訴手機', () async {
    final client = await paired();
    var updates = 0;
    client.addListener(() => updates++);
    host.statusChanged();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(updates, 0, reason: '沒換就不送');

    actions.current = (server: 'http://10.0.0.9:5000', user: '');
    host.statusChanged();
    await until(() => client.tvServer == 'http://10.0.0.9:5000');
    expect(client.tvUser, '');
  });

  test('電視上移除這支手機: 正連著的也斷掉, 下次要重新配對', () async {
    final client = await paired();
    await host.forget('phone-1');
    await until(() => client.phase == TvRemotePhase.failed);
    expect(client.message, contains('移除'));
    expect(host.paired, isEmpty);

    final again = phone();
    await again.connect(tv);
    await until(() => again.phase == TvRemotePhase.pairing);
  });

  test('瀏覽器來的一律擋掉; /remote/info 報上名字', () async {
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    final info = await (await client.getUrl(
            Uri.parse('http://127.0.0.1:${host.boundPort}/remote/info')))
        .close();
    expect(info.statusCode, 200);
    final body = jsonDecode(await utf8.decodeStream(info)) as Map;
    expect(body['app'], 'aniGamerPlus');
    expect(body['id'], 'tv-1');
    expect(body['name'], '客廳電視');

    final request = await client
        .getUrl(Uri.parse('http://127.0.0.1:${host.boundPort}/remote/info'));
    request.headers.set('Origin', 'http://evil.example');
    final blocked = await request.close();
    await blocked.drain<void>();
    expect(blocked.statusCode, 403);
  });

  test('找電視: 廣播的回音跟逐台敲門都找得到', () async {
    final loopback = InternetAddress.loopbackIPv4;
    final discovery = TvDiscovery(
        port: host.boundPort, discoveryPort: host.discoveryBoundPort);

    final byBroadcast = await discovery.scan(
      timeout: const Duration(seconds: 2),
      broadcastTargets: [loopback],
      probeHosts: const [],
    ).toList();
    expect(byBroadcast.single.id, 'tv-1');
    expect(byBroadcast.single.name, '客廳電視');
    expect(byBroadcast.single.host, '127.0.0.1');
    expect(byBroadcast.single.port, host.boundPort);

    final byProbe = await discovery.scan(
      timeout: const Duration(seconds: 2),
      broadcastTargets: const [],
      probeHosts: [loopback],
    ).toList();
    expect(byProbe.single.id, 'tv-1');

    final manual = await discovery.probe(tv);
    expect(manual.name, '客廳電視');
  });

  test('手動輸入的位址', () {
    expect(TvDevice.parseAddress('192.168.1.20')!.host, '192.168.1.20');
    expect(TvDevice.parseAddress('192.168.1.20')!.port, kRemotePort);
    final withPort = TvDevice.parseAddress(' http://192.168.1.20:5555/ ')!;
    expect(withPort.host, '192.168.1.20');
    expect(withPort.port, 5555);
    expect(withPort.address, '192.168.1.20:5555');
    expect(TvDevice.parseAddress(''), isNull);
    expect(TvDevice.parseAddress('192.168.1.20:99999'), isNull);
    expect(TvDevice.parseAddress('bad host'), isNull);
  });
}
