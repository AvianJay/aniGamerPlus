/// 封面/縮圖那一層: 清單解析、落盤、以及兩道併發閘門.
///
/// 這裡開兩台 loopback 伺服器 —— 一台假裝是 aniGamerPlus 自己 (清單跟
/// /thumbnail.jpg 都在它身上), 一台假裝是動畫瘋的 CDN. 兩台分開才驗得出
/// 「指回自己伺服器的圖走窄的那道閘」這件事.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agp_mobile/src/api/client.dart';
import 'package:agp_mobile/src/state/thumbnails.dart';
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

class FakeHost {
  FakeHost._(this._server);

  final HttpServer _server;

  /// path -> 圖的位元組. 沒登記的一律 404.
  final Map<String, List<int>> files = {};

  String manifest = '';
  String etag = '';

  final List<String> hits = <String>[];

  /// 同時有幾筆在手上 / 最多曾經有幾筆. 閘門就是靠這個驗的.
  int inFlight = 0;
  int peak = 0;

  /// 非 null 的時候每一筆請求都先卡在這裡, 讓它們堆起來
  Completer<void>? hold;

  static Future<FakeHost> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final host = FakeHost._(server);
    unawaited(host._serve());
    return host;
  }

  String get url => 'http://127.0.0.1:${_server.port}';

  int hitsOn(String path) => hits.where((hit) => hit == path).length;

  void reset() {
    hits.clear();
    peak = 0;
  }

  Future<void> stop() => _server.close(force: true);

  Future<void> _serve() async {
    // 一筆一筆 await 的話整台伺服器會變成單執行緒, 閘門那兩個測試就永遠
    // 看不到第二筆同時在手上
    await for (final request in _server) {
      unawaited(_handle(request));
    }
  }

  Future<void> _handle(HttpRequest request) async {
    hits.add(request.uri.path);
    inFlight += 1;
    if (inFlight > peak) peak = inFlight;
    try {
      await hold?.future;
      final response = request.response;
      if (request.uri.path == '/thumbnails.json') {
        if (request.headers.value('if-none-match') == etag && etag.isNotEmpty) {
          response.statusCode = HttpStatus.notModified;
        } else {
          response.headers.set('ETag', etag);
          response.headers.contentType = ContentType.json;
          response.write(manifest);
        }
      } else {
        final body = files[request.uri.path];
        if (body == null) {
          response.statusCode = HttpStatus.notFound;
        } else {
          response.headers.contentType = ContentType('image', 'jpeg');
          response.add(body);
        }
      }
      await response.close();
    } catch (_) {
      // 測試結束時伺服器是被強制關掉的
    } finally {
      inFlight -= 1;
    }
  }
}

/// _download 會把小於 256 bytes 的東西當成錯誤訊息丟掉, 所以假圖要夠大
List<int> fakeJpeg([int seed = 0]) =>
    List<int>.generate(512, (i) => (i + seed) % 256);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temp;
  late FakeHost agp;
  late FakeHost cdn;
  late AgpClient client;
  late ThumbnailStore store;

  String manifestJson() => jsonEncode({
        'generatedAt': 1757000000,
        'anime': {'a1': '${cdn.url}/poster-a1.jpg'},
        'episodes': {
          'v1': ['a1', '${cdn.url}/still-v1.jpg'],
          // 有作品但沒有這一集的劇照
          'v2': ['a1', ''],
          // 兩邊都沒有
          'v3': ['', ''],
        },
      });

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('agp-thumbs-test-');
    PathProviderPlatform.instance = Paths(temp.path);
    agp = await FakeHost.start();
    cdn = await FakeHost.start();
    agp.etag = 'W/"abc123"';
    agp.manifest = manifestJson();
    agp.files['/thumbnail.jpg'] = fakeJpeg(7);
    cdn.files['/poster-a1.jpg'] = fakeJpeg(1);
    cdn.files['/still-v1.jpg'] = fakeJpeg(2);
    client = AgpClient(baseUrl: agp.url);
    store = ThumbnailStore(client);
  });

  tearDown(() async {
    store.dispose();
    client.close();
    await agp.stop();
    await cdn.stop();
    await temp.delete(recursive: true);
  });

  /// 等到條件成立為止 —— _trim() 是 unawaited 的, 沒別的辦法等它
  Future<void> waitFor(bool Function() done, {String reason = ''}) async {
    for (var i = 0; i < 200; i++) {
      if (done()) return;
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    fail('等不到: $reason');
  }

  test('清單解析: 劇照優先, 沒有就退回主視覺', () async {
    await store.refresh();

    expect(store.isEmpty, isFalse);
    expect(store.animeSnOf('v1'), 'a1');
    expect(store.animeSnOf('v3'), isNull);

    expect(store.stillFor('v1'), '${cdn.url}/still-v1.jpg');
    expect(store.posterFor('v1'), '${cdn.url}/poster-a1.jpg',
        reason: '沒直接登記的話要從所屬作品找主視覺');
    expect(store.posterFor('a1'), '${cdn.url}/poster-a1.jpg');
    expect(store.stillFor('v2'), '${cdn.url}/poster-a1.jpg',
        reason: '沒有劇照就用主視覺, 有圖比沒圖好');
    expect(store.stillFor('v3'), isNull);
    expect(store.urlFor('v1', poster: true), store.posterFor('v1'));
  });

  test('清單會落盤, 下次開機帶著 ETag 去問就是一個 304', () async {
    await store.refresh();
    expect(agp.hitsOn('/thumbnails.json'), 1);
    expect(File('${temp.path}/thumbnails.json').existsSync(), isTrue);
    expect(File('${temp.path}/thumbnails.etag').readAsStringSync(), agp.etag);

    final again = ThumbnailStore(client);
    addTearDown(again.dispose);
    await again.init();
    expect(again.stillFor('v1'), '${cdn.url}/still-v1.jpg',
        reason: '還沒連網就該畫得出來');

    await again.refresh();
    expect(agp.hitsOn('/thumbnails.json'), 2);
    expect(again.stillFor('v1'), '${cdn.url}/still-v1.jpg',
        reason: '304 不該把手上那份弄掉');
  });

  test('抓過的圖留在磁碟上, 第二次不再走網路', () async {
    await store.refresh();

    final file = await store.resolve('v1');
    expect(file, isNotNull);
    expect(file!.lengthSync(), 512);
    expect(cdn.hitsOn('/still-v1.jpg'), 1);
    expect(store.cachedFile(store.stillFor('v1')), isNotNull,
        reason: 'cachedFile() 是同步的, 熱的封面要第一帧就畫得出來');

    final second = await store.resolve('v1');
    expect(second!.path, file.path);
    expect(cdn.hitsOn('/still-v1.jpg'), 1);
    expect(store.cached('v1'), isNotNull);
  });

  test('清單上沒有的集數才退回伺服器的 /thumbnail.jpg', () async {
    await store.refresh();
    agp.reset();

    final file = await store.resolve('v9');
    expect(file, isNotNull);
    expect(agp.hitsOn('/thumbnail.jpg'), 1);
    expect(store.cachedServerThumb('v9'), isNotNull);
    expect(cdn.hits, isEmpty);
  });

  test('離線那一輪記下的失敗, 連得上伺服器時要整組放掉', () async {
    await store.refresh();
    final url = '${cdn.url}/late.jpg';

    expect(await store.resolveUrl(url), isNull);
    expect(cdn.hitsOn('/late.jpg'), 1);

    // 黑名單: 每次重畫都再打一次同一個 404 是以前的毛病
    expect(await store.resolveUrl(url), isNull);
    expect(cdn.hitsOn('/late.jpg'), 1);

    cdn.files['/late.jpg'] = fakeJpeg(3);
    // 問得到伺服器就表示網路通了 —— 就算只是一個 304
    await store.refresh();
    expect(agp.hitsOn('/thumbnails.json'), 2);

    expect(await store.resolveUrl(url), isNotNull);
    expect(cdn.hitsOn('/late.jpg'), 2);
  });

  test('同時去 CDN 的數量有上限', () async {
    await store.refresh();
    cdn.reset();
    cdn.hold = Completer<void>();

    final wanted = kCoverFetchConcurrency * 2;
    for (var i = 0; i < wanted; i++) {
      cdn.files['/gate-$i.jpg'] = fakeJpeg(i);
    }
    final all = [
      for (var i = 0; i < wanted; i++) store.resolveUrl('${cdn.url}/gate-$i.jpg'),
    ];

    await waitFor(() => cdn.inFlight >= kCoverFetchConcurrency,
        reason: '閘門開不到滿');
    // 多給一點時間讓「多出來的那幾筆」有機會擠進來 —— 擠得進來才是壞掉
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(cdn.peak, kCoverFetchConcurrency);

    cdn.hold!.complete();
    cdn.hold = null;
    expect(await Future.wait(all), everyElement(isNotNull));
    expect(cdn.peak, kCoverFetchConcurrency);
  });

  test('同時去伺服器要圖的數量壓得更低 —— 每一筆都可能開一支 ffmpeg', () async {
    await store.refresh();
    agp.reset();
    agp.hold = Completer<void>();

    final wanted = kServerThumbConcurrency * 3;
    final all = [for (var i = 0; i < wanted; i++) store.resolve('none-$i')];

    await waitFor(() => agp.inFlight >= kServerThumbConcurrency,
        reason: '伺服器那道閘開不到滿');
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(agp.peak, kServerThumbConcurrency);

    agp.hold!.complete();
    agp.hold = null;
    expect(await Future.wait(all), everyElement(isNotNull));
    expect(agp.peak, kServerThumbConcurrency);
  });

  test('磁碟上的封面滿了會照 mtime 丟掉最舊的', () async {
    await store.refresh();
    final covers = Directory('${temp.path}/covers');
    expect(covers.existsSync(), isTrue);

    // 塞到超過上限. 每個都很小, 所以先撞到的是檔案數那一條線.
    // mtime 明確寫成很舊的 —— 不然這一批跟等一下那張新圖可能落在同一個
    // 時間戳上, 排序就變成擲骰子.
    final long = DateTime(2020, 1, 1);
    for (var i = 0; i < kCoverCacheMax + 20; i++) {
      final file = File('${covers.path}/old-$i.img');
      await file.writeAsBytes(const [0, 1, 2, 3]);
      await file.setLastModified(long);
    }
    expect(covers.listSync().length, kCoverCacheMax + 20);

    // 抓一張新的就會順手清一次
    expect(await store.resolve('v1'), isNotNull);
    await waitFor(() => covers.listSync().length <= kCoverCacheMax,
        reason: '清不完');

    expect(covers.listSync().length, kCoverCacheMax);
    expect(store.cachedFile(store.stillFor('v1')), isNotNull,
        reason: '剛抓的那一張是最新的, 不該被自己清掉');
  });

  test('clear() 把清單跟圖一起丟掉', () async {
    await store.refresh();
    expect(await store.resolve('v1'), isNotNull);
    expect(await store.cacheBytes(), greaterThan(0));

    await store.clear();
    expect(store.isEmpty, isTrue);
    expect(store.stillFor('v1'), isNull);
    expect(File('${temp.path}/thumbnails.json').existsSync(), isFalse);
    expect(await store.cacheBytes(), 0);
  });
}
