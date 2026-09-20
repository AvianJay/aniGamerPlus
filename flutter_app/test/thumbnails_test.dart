/// 封面/縮圖那一層: 清單解析、落盤、以及兩道併發閘門.
///
/// 這裡開兩台 loopback 伺服器 —— 一台假裝是 aniGamerPlus 自己 (清單跟
/// /thumbnail.webp 都在它身上), 一台假裝是動畫瘋的 CDN. 兩台分開才驗得出
/// 「指回自己伺服器的圖走窄的那道閘」這件事.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agp_mobile/src/api/client.dart';
import 'package:agp_mobile/src/api/models.dart';
import 'package:agp_mobile/src/state/thumbnails.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'support/temp_dir.dart';

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
  final Map<String, Map<String, String>> headers = {};

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
    headers[request.uri.path] = {};
    request.headers.forEach((name, values) {
      headers[request.uri.path]![name] = values.join('; ');
    });
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
          response.headers.contentType = ContentType(
              'image', request.uri.path.endsWith('.webp') ? 'webp' : 'jpeg');
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

/// Cache transport tests need a recognized image signature, not decoded pixels.
List<int> fakeJpeg([int seed = 0]) =>
    [0xff, 0xd8, 0xff, ...List<int>.generate(509, (i) => (i + seed) % 256)];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // binding 會裝一個假的 HttpOverrides, 把每一筆 dart:io 請求都變成 400 ——
  // 那是為了擋住 widget test 裡偷偷去抓圖的程式. 這裡的假伺服器是真的開在
  // loopback 上, 所以要把它拿掉 (video_cache_test 是靠不初始化 binding 躲開的)
  HttpOverrides.global = null;

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
    agp.files['/thumbnail.webp'] = fakeJpeg(7);
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
    await deleteTempDir(temp);
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

  test('同一張圖同時要兩次只走一次網路, 而且兩邊都等得到結果', () async {
    await store.refresh();
    final url = '${cdn.url}/still-v1.jpg';

    // 先把伺服器卡住, 第二筆進來的時候第一筆還在飛 —— 這樣才走得到合併那條路
    cdn.hold = Completer<void>();
    final first = store.resolveUrl(url);
    final second = store.resolveUrl(url);
    await waitFor(() => cdn.hitsOn('/still-v1.jpg') >= 1, reason: '第一筆沒出去');
    cdn.hold!.complete();
    cdn.hold = null;

    // 這裡的 timeout 是在守一個真的踩過的坑: 合併用的 whenComplete 如果回傳了
    // 被移掉的那個 future, 它等的就是自己, 兩邊都永遠醒不過來.
    final files =
        await Future.wait([first, second]).timeout(const Duration(seconds: 5));
    expect(files.first, isNotNull);
    expect(files.last!.path, files.first!.path);
    expect(cdn.hitsOn('/still-v1.jpg'), 1, reason: '被合併掉的那一筆不該再打一次');
  });

  test('同一部作品的兩集同時要主視覺, 不會互相把圖抓壞', () async {
    await store.refresh();
    cdn.reset();

    // v2 沒有自己的劇照, 所以它退回 a1 的主視覺 —— 跟 poster(v1) 是同一個
    // 網址. 但 resolve() 的合併鍵是 sn ('v1:p' / 'v2:s'), 兩把不同的鍵,
    // 所以這兩筆會各自開一次下載, 而它們算出來的快取檔名是同一個.
    expect(store.posterFor('v1'), store.stillFor('v2'));

    cdn.hold = Completer<void>();
    final first = store.resolve('v1', poster: true);
    final second = store.resolve('v2');
    await waitFor(() => cdn.hitsOn('/poster-a1.jpg') >= 1, reason: '第一筆沒出去');
    await Future<void>.delayed(const Duration(milliseconds: 120));
    cdn.hold!.complete();
    cdn.hold = null;

    final files =
        await Future.wait([first, second]).timeout(const Duration(seconds: 5));
    // 以前輸的那一筆 rename 會丟例外, 回 null, 而且把網址記進黑名單 ——
    // 整部作品的封面這一輪就全沒了
    expect(files.first, isNotNull, reason: 'v1 的主視覺不見了');
    expect(files.last, isNotNull, reason: 'v2 的主視覺不見了');
    expect(files.last!.path, files.first!.path);
    expect(files.first!.lengthSync(), 512);
    expect(cdn.hitsOn('/poster-a1.jpg'), 1, reason: '同一張圖不該抓兩次');

    // 黑名單也不該被弄髒: 再要一次還是拿得到
    expect(await store.resolve('v2'), isNotNull);
  });

  test('清單上沒有的集數才退回伺服器的 /thumbnail.webp', () async {
    await store.refresh();
    agp.reset();

    final file = await store.resolve('v9');
    expect(file, isNotNull);
    expect(agp.hitsOn('/thumbnail.webp'), 1);
    expect(store.cachedServerThumb('v9'), isNotNull);
    expect(cdn.hits, isEmpty);
  });

  test('小於 256 bytes 的 WebP 仍可作為縮圖', () async {
    final image = base64Decode(
        'UklGRjgAAABXRUJQVlA4ICwAAABwAQCdASoIAAgAAUAiJaACdAFAAAD+/NVh/7Sz//tLP/+0s/z0NcXNkWkAAA==');
    agp.files['/thumbnail.webp'] = image;
    final file = await store.resolve('small-webp');
    expect(file, isNotNull);
    expect(file!.readAsBytesSync(), image);
  });

  test(
      'catalog posters normalize relative paths and never leak server credentials to the CDN',
      () async {
    client.token = 'test-session';
    await store.init();
    store.seedCatalog([
      CatalogItem.fromJson({
        'animeSn': 'a5',
        'videoSn': 'v5',
        'title': '測試 動畫',
        'cover': '/poster.jpg'
      }),
    ]);
    agp.files['/poster.jpg'] = fakeJpeg();
    expect(store.posterForTitle('測試動畫'), '${agp.url}/poster.jpg');
    expect(await store.resolve('v5', poster: true), isNotNull);
    expect(agp.headers['/poster.jpg']!['cookie'], contains('test-session'));
    final file = await store.resolveUrl('${cdn.url}/poster-a1.jpg', headers: {
      'Cookie': 'private-cookie',
      'Authorization': 'private-token'
    });
    expect(file, isNotNull);
    expect(
        cdn.headers['/poster-a1.jpg']!['referer'], 'https://ani.gamer.com.tw/');
    expect(cdn.headers['/poster-a1.jpg']!['cookie'], isNull);
    expect(cdn.headers['/poster-a1.jpg']!['authorization'], isNull);
  });

  test('missing manifest posters are recovered from series and survive restart',
      () async {
    agp.files['/watch/series.json'] = utf8.encode(jsonEncode({
      'animeSn': 'a9',
      'videoSn': 'v9',
      'title': 'Recovered series',
      'cover': '${cdn.url}/poster-a1.jpg',
      'groups': [
        {
          'name': '',
          'episodes': [
            {'videoSn': 'v9'},
            {'videoSn': 'v10'}
          ]
        }
      ],
    }));
    await store.init();
    expect(await store.resolve('v9', poster: true), isNotNull);
    expect(store.posterFor('v10'), '${cdn.url}/poster-a1.jpg');
    expect(agp.hitsOn('/thumbnail.webp'), 0);
    final again = ThumbnailStore(client);
    addTearDown(again.dispose);
    await again.init();
    expect(again.posterFor('v10'), '${cdn.url}/poster-a1.jpg');
    expect(await again.resolve('v10', poster: true), isNotNull);
    expect(agp.hitsOn('/watch/series.json'), 1);
  });

  test('a successful HTML response is never cached as a poster', () async {
    cdn.files['/error.jpg'] = utf8.encode('<html>${'Error' * 100}</html>');
    expect(await store.resolveUrl('${cdn.url}/error.jpg'), isNull);
    expect(store.cachedFile('${cdn.url}/error.jpg'), isNull);
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
      for (var i = 0; i < wanted; i++)
        store.resolveUrl('${cdn.url}/gate-$i.jpg'),
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
