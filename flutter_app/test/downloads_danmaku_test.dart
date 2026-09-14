/// 下載到手機的兩件事: 「等伺服器抓完再接手」跟「事後補抓彈幕」.
///
/// 假伺服器沿用 video_cache_test.dart 的做法 —— 真的在 loopback 上開一個
/// HttpServer, 不去換掉 http.Client. DownloadStore 問「伺服器有沒有這一集」
/// 用的是頂層的 http.head, 那支沒地方注入, 只能從網路的另一端假.
library;

import 'dart:async';
import 'dart:io';

import 'package:agp_mobile/src/api/client.dart';
import 'package:agp_mobile/src/api/models.dart';
import 'package:agp_mobile/src/state/downloads.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class Paths extends PathProviderPlatform {
  Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
}

/// 一小段真的 .ass. 重點是有 [Script Info] 跟 Dialogue: 這兩個記號.
const String kAss = r'''
[Script Info]
ScriptType: v4.00+
PlayResX: 1920
PlayResY: 1080

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:01.00,0:00:09.00,R2L,,0,0,0,,{\move(1920,60,-200,60)}測試彈幕
''';

/// 伺服器把彈幕關掉時回的東西: 200, 但內容是一句話. 這正是以前會被當成
/// 字幕寫到磁碟上的那一份.
const String kDanmuOff = 'Danmu is not enabled';

class FakeServer {
  FakeServer._(this._server);

  final HttpServer _server;

  /// 伺服器上「已經有」的集數. /get_video.mp4 照這個回答 404 還是 200.
  final Set<String> have = <String>{};

  /// /get_danmu.ass 要回什麼.
  String danmaku = '';

  final List<String> hits = <String>[];

  static Future<FakeServer> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fake = FakeServer._(server);
    unawaited(fake._serve());
    return fake;
  }

  String get url => 'http://127.0.0.1:${_server.port}';

  int hitsOn(String path) => hits.where((hit) => hit == path).length;

  Future<void> stop() => _server.close(force: true);

  Future<void> _serve() async {
    await for (final request in _server) {
      hits.add(request.uri.path);
      final sn = request.uri.queryParameters['id'] ?? '';
      final response = request.response;
      var body = '';
      switch (request.uri.path) {
        case '/get_video.mp4':
          if (have.contains(sn)) {
            body = 'fake mp4 bytes';
          } else {
            response.statusCode = HttpStatus.notFound;
          }
        case '/get_danmu.ass':
          body = danmaku;
        default:
          response.statusCode = HttpStatus.notFound;
      }
      try {
        // HEAD 不寫 body, 讓 dart:io 自己把長度算成 0 —— http.head 只看狀態碼
        if (request.method != 'HEAD' && body.isNotEmpty) response.write(body);
        await response.close();
      } catch (_) {
        // 測試結束時把伺服器強制關掉, 手上這筆寫不完是正常的
      }
    }
  }
}

/// 已經下載好的一集. 這裡要驗的是 done 之後的行為, 真的搬位元組是
/// video_cache_test 那邊的事, 所以直接把檔案擺好、狀態撥過去.
Future<DownloadEntry> settled(DownloadStore store, String sn) async {
  final entry = await store.enqueue(
    VideoItem(sn: sn, animeName: '測試動畫', episode: '1', resolution: 1080),
  );
  await store.videoFile(entry).writeAsString('fake mp4 bytes');
  entry.status = DownloadStatus.done;
  return entry;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // binding 會裝一個假的 HttpOverrides, 把每一筆 dart:io 請求都變成 400.
  // 假伺服器是真的開在 loopback 上的, 要把它拿掉才問得到.
  HttpOverrides.global = null;

  group('looksLikeAss', () {
    test('伺服器關掉彈幕時那句話不是字幕', () {
      expect(looksLikeAss(kDanmuOff), isFalse);
    });

    test('太短的一律不算, 免得把錯誤訊息寫成字幕檔', () {
      expect(looksLikeAss(''), isFalse);
      expect(looksLikeAss('Dialogue:'), isFalse);
    });

    test('真的 .ass 認得出來', () {
      expect(looksLikeAss(kAss), isTrue);
    });

    test('只有 Dialogue: 的也算 —— 有些來源不寫檔頭', () {
      expect(
        looksLikeAss('Dialogue: 0,0:00:01.00,0:00:09.00,R2L,,0,0,0,,測試彈幕'),
        isTrue,
      );
    });
  });

  group('DownloadStore', () {
    late Directory temp;
    late FakeServer fake;
    late AgpClient client;
    late DownloadStore store;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('agp-downloads-test-');
      PathProviderPlatform.instance = Paths(temp.path);
      fake = await FakeServer.start();
      client = AgpClient(baseUrl: fake.url);
      store = DownloadStore(client);
      await store.init();
      // 這一組要驗的是狀態機, 不是真的去搬位元組: 把幫浦關掉, queued 就停在
      // queued, 斷言才有東西可看
      store.concurrency = 0;
    });

    tearDown(() async {
      store.dispose();
      client.close();
      await fake.stop();
      await temp.delete(recursive: true);
    });

    test('伺服器還沒抓完的集數先掛著, 檔案出現了才轉成排隊', () async {
      await store.enqueueWaiting(
        VideoItem(sn: '123', animeName: '測試動畫', episode: '1'),
      );
      expect(store.entryFor('123')!.waitingForServer, isTrue);

      await store.pollWaiting();
      expect(store.entryFor('123')!.status, DownloadStatus.waiting,
          reason: '伺服器還是 404, 不該動它');

      fake.have.add('123');
      await store.pollWaiting();
      expect(store.entryFor('123')!.status, DownloadStatus.queued);
    });

    test('連不上伺服器的時候維持等待, 不算失敗', () async {
      await store.enqueueWaiting(VideoItem(sn: '234', episode: '2'));
      await fake.stop();

      await store.pollWaiting();
      expect(store.entryFor('234')!.status, DownloadStatus.waiting);
      expect(store.entryFor('234')!.error, isEmpty);
    });

    test('第一輪沒抓到的彈幕, 冷卻過了還會再試一次', () async {
      final entry = await settled(store, '456');
      fake.danmaku = kDanmuOff;

      await store.retryMissingDanmaku();
      expect(entry.hasDanmaku, isFalse);
      expect(store.danmakuFile('456').existsSync(), isFalse,
          reason: '那句話不是字幕, 不能落盤');
      expect(entry.danmakuTries, 1);
      expect(entry.danmakuLastTry, greaterThan(0));

      // 剛問過, 冷卻期內不該再打伺服器
      fake.danmaku = kAss;
      await store.retryMissingDanmaku();
      expect(entry.danmakuTries, 1);
      expect(entry.hasDanmaku, isFalse);

      // 使用者按「補抓彈幕」就是 force, 直接跳過冷卻
      await store.retryMissingDanmaku(force: true);
      expect(entry.hasDanmaku, isTrue);
      expect(store.danmakuFile('456').readAsStringSync(), kAss);
    });

    test('.ass 已經在磁碟上的話只補狀態, 不必再問伺服器', () async {
      final entry = await settled(store, '789');
      await store.danmakuFile('789').writeAsString(kAss);
      final before = fake.hitsOn('/get_danmu.ass');

      await store.retryMissingDanmaku();
      expect(entry.hasDanmaku, isTrue);
      expect(fake.hitsOn('/get_danmu.ass'), before);
    });

    test('沒下載完的集數也收得下播放頁回填的彈幕', () async {
      // 邊看邊下載: 影片還在抓, 但彈幕已經拿到了
      final entry = await store.enqueue(VideoItem(sn: '321', episode: '3'));
      expect(entry.playable, isFalse);

      await store.cacheDanmaku('321', kDanmuOff);
      expect(entry.hasDanmaku, isFalse);
      expect(store.danmakuFile('321').existsSync(), isFalse);

      await store.cacheDanmaku('321', kAss);
      expect(entry.hasDanmaku, isTrue);
      expect(store.danmakuFile('321').readAsStringSync(), kAss);
    });

    test('試過幾次、上次什麼時候試的, 重開 app 之後還記得', () async {
      final entry = await settled(store, '654');
      fake.danmaku = kDanmuOff;
      await store.retryMissingDanmaku();
      expect(entry.danmakuTries, 1);

      final again = DownloadStore(client);
      addTearDown(again.dispose);
      await again.init();
      again.concurrency = 0;

      final reloaded = again.entryFor('654')!;
      expect(reloaded.status, DownloadStatus.done);
      expect(reloaded.danmakuTries, entry.danmakuTries);
      expect(reloaded.danmakuLastTry, entry.danmakuLastTry);
      expect(reloaded.danmakuPending, isTrue);
    });
  });
}
