/// 觀看進度的離線那一段.
///
/// 進度以前只活在記憶體裡: 飛航模式下看的那幾分鐘, app 一關就沒了, 而且
/// refreshWatchTimes() 在離線時還會把整份清成空的. 這裡驗的就是那三件事 ——
/// 落盤、離線不清空、回到線上補送.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agp_mobile/src/api/models.dart';
import 'package:agp_mobile/src/state/app_state.dart';
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

class WatchServer {
  WatchServer._(this._server);

  final HttpServer _server;

  /// 伺服器手上那份 {sn: {time, ended, duration, timestamp}}
  final Map<String, Map<String, dynamic>> stored = {};

  /// 收到的每一筆 type=set
  final List<Map<String, dynamic>> posts = [];

  /// true = 寫入一律 500, 用來驗「送不出去就繼續欠著」
  bool refuse = false;

  static Future<WatchServer> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fake = WatchServer._(server);
    unawaited(fake._serve());
    return fake;
  }

  String get url => 'http://127.0.0.1:${_server.port}';

  Future<void> stop() => _server.close(force: true);

  Future<void> _serve() async {
    await for (final request in _server) {
      final response = request.response;
      var body = '';
      try {
        if (request.uri.path != '/watch/time') {
          response.statusCode = HttpStatus.notFound;
        } else if (request.method == 'POST') {
          final raw = await utf8.decoder.bind(request).join();
          final json = (jsonDecode(raw) as Map).cast<String, dynamic>();
          if (refuse) {
            response.statusCode = HttpStatus.internalServerError;
          } else {
            posts.add(json);
            final sn = json['sn'].toString();
            if (json['type'] == 'del') {
              stored.remove(sn);
            } else {
              stored[sn] = {
                'time': json['time'],
                'ended': json['ended'],
                'duration': json['duration'] ?? 0,
                'timestamp': DateTime.now().millisecondsSinceEpoch ~/ 1000,
              };
            }
            body = '{"status":"200"}';
          }
        } else {
          body = jsonEncode(stored);
        }
        if (body.isNotEmpty) response.write(body);
        await response.close();
      } catch (_) {
        // 測試結束時伺服器是被強制關掉的, 手上這筆寫不完很正常
      }
    }
  }
}

/// 存一份 watch-times.json 到 support 目錄, 模擬「上一次開 app 留下來的」
Future<void> seedOnDisk(Directory dir, Map<String, dynamic> raw) =>
    File('${dir.path}/watch-times.json').writeAsString(jsonEncode(raw));

Map<String, dynamic> row(
  int time, {
  int timestamp = 0,
  int duration = 1400,
  bool dirty = false,
}) =>
    {
      'time': time,
      'ended': false,
      'duration': duration,
      'timestamp': timestamp,
      if (dirty) 'dirty': true,
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // binding 會裝一個假的 HttpOverrides, 把每一筆 dart:io 請求都變成 400.
  // 假伺服器是真的開在 loopback 上的, 要把它拿掉才問得到.
  HttpOverrides.global = null;

  late Directory temp;
  late WatchServer fake;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('agp-watch-times-test-');
    PathProviderPlatform.instance = Paths(temp.path);
    fake = await WatchServer.start();
    // Prefs 是一個不會重設的 static singleton, 所以伺服器位址不能靠這裡傳 ——
    // 開機之後直接改 client.baseUrl (AppState 上下都共用同一個 client)
    SharedPreferences.setMockInitialValues({'agp-server': ''});
  });

  tearDown(() async {
    await fake.stop();
    await deleteTempDir(temp);
  });

  /// 開一台指向假伺服器的 app. offline = true 就完全不碰網路.
  Future<AppState> boot({bool offline = false}) async {
    final state = await AppState.boot();
    state.offline = offline;
    state.client.baseUrl = offline ? '' : fake.url;
    return state;
  }

  test('離線記下的進度會落盤, 重開 app 還在', () async {
    final first = await boot(offline: true);
    first.noteWatchTime(
      '111',
      WatchTime(time: 120, duration: 1400, timestamp: 1700000000),
      pending: true,
    );
    await first.flushWatchTimesToDisk();

    final second = await boot(offline: true);
    expect(second.watchTimes, isEmpty, reason: '還沒讀檔之前手上是空的');

    await second.refreshWatchTimes();
    expect(second.watchTimeOf('111')?.time, 120);
    expect(second.isWatchTimePending('111'), isTrue,
        reason: '離線記的那一筆伺服器還沒收到, 欠帳要一起活過重開機');
  });

  test('離線時 refreshWatchTimes() 不會把本機那份清成空的', () async {
    await seedOnDisk(temp, {'222': row(300, timestamp: 1700000000)});

    final state = await boot(offline: true);
    await state.refreshWatchTimes();
    expect(state.watchTimeOf('222')?.time, 300);

    // 再跑一次也一樣 —— 以前這裡是 watchTimes = const {}
    await state.refreshWatchTimes();
    expect(state.watchTimeOf('222')?.time, 300);
  });

  test('回到線上時把欠的那幾筆補送給伺服器', () async {
    await seedOnDisk(temp, {'333': row(480, timestamp: 1700000000, dirty: true)});

    final state = await boot();
    await state.refreshWatchTimes();
    expect(state.isWatchTimePending('333'), isTrue);

    await state.flushPendingWatchTimes();
    expect(fake.posts, hasLength(1));
    expect(fake.posts.first['sn'], '333');
    expect(fake.posts.first['time'], 480);
    expect(fake.posts.first['duration'], 1400);
    expect(state.isWatchTimePending('333'), isFalse);
    expect(state.hasPendingWatchTimes, isFalse);
  });

  test('補送失敗就繼續欠著, 不會把進度弄丟', () async {
    await seedOnDisk(temp, {'444': row(60, timestamp: 1700000000, dirty: true)});
    fake.refuse = true;

    final state = await boot();
    await state.refreshWatchTimes();
    await state.flushPendingWatchTimes();

    expect(state.isWatchTimePending('444'), isTrue);
    expect(state.watchTimeOf('444')?.time, 60);
  });

  test('合併以 timestamp 新的那一份為準, 但還欠伺服器的一律以本機為準', () async {
    await seedOnDisk(temp, {
      // 伺服器上有, 而且比較新 —— 該被蓋過去
      'A': row(10, timestamp: 100),
      // 本機還欠著: 伺服器那份就算 timestamp 更大也是舊帳
      'B': row(999, timestamp: 100, dirty: true),
      // 伺服器沒有, 本機也不欠它 —— 在別台裝置上刪掉的
      'C': row(30, timestamp: 100),
    });
    fake.stored['A'] = {'time': 50, 'ended': false, 'duration': 1400, 'timestamp': 200};
    fake.stored['B'] = {'time': 5, 'ended': false, 'duration': 1400, 'timestamp': 900};

    final state = await boot();
    await state.refreshWatchTimes();

    expect(state.watchTimeOf('A')?.time, 50);
    expect(state.watchTimeOf('B')?.time, 999);
    expect(state.isWatchTimePending('B'), isTrue);
    expect(state.watchTimeOf('C'), isNull);
  });

  test('抓不到伺服器那份的時候照樣留著本機的', () async {
    await seedOnDisk(temp, {'555': row(90, timestamp: 1700000000)});

    final state = await boot();
    await fake.stop();
    await state.refreshWatchTimes();

    expect(state.watchTimeOf('555')?.time, 90);
  });

  test('忘掉一集之後磁碟上也不該再有它', () async {
    final state = await boot();
    state.noteWatchTime('666', WatchTime(time: 12, timestamp: 1700000000));
    await state.flushWatchTimesToDisk();

    await state.forgetWatchTime('666');
    await state.flushWatchTimesToDisk();

    final raw = jsonDecode(
        await File('${temp.path}/watch-times.json').readAsString()) as Map;
    expect(raw.containsKey('666'), isFalse);
  });
}
