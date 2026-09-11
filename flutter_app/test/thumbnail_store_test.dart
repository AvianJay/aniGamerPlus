/// 手機端縮圖快取: 直接打巴哈 mobile v4 API, 圖片存在手機上, 不再走伺服器
/// 的 /thumbnail.jpg.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:agp_mobile/src/state/app_state.dart';
import 'package:agp_mobile/src/state/thumbnail_store.dart';
import 'package:agp_mobile/src/widgets/local_thumb.dart';

/// 假的 JPEG: 開頭是 FFD8FF, 後面是固定圖樣, 長度 2KB.
Uint8List fakeJpeg([int length = 2048]) {
  final bytes = Uint8List(length);
  bytes[0] = 0xFF;
  bytes[1] = 0xD8;
  bytes[2] = 0xFF;
  for (var i = 3; i < length; i++) {
    bytes[i] = i % 251;
  }
  return bytes;
}

String metaJson(String cover) => jsonEncode({
      'data': {
        'video': {'cover': cover},
      },
    });

class CapturedRequest {
  CapturedRequest(this.method, this.url, this.headers);

  final String method;
  final Uri url;
  final Map<String, String> headers;
}

/// 依 URL 分流的假 http.Client. 預設: video.php 回 metadata, 其他回圖片.
class FakeBahamut extends http.BaseClient {
  FakeBahamut({
    this.metaStatus = 200,
    this.metaBody,
    this.imageStatus = 200,
    this.imageBytes,
    this.imageContentType = 'image/jpeg',
    this.delay = Duration.zero,
  });

  int metaStatus;
  String? metaBody;
  int imageStatus;
  Uint8List? imageBytes;
  String imageContentType;
  Duration delay;

  final List<CapturedRequest> requests = [];
  int metaCalls = 0;
  int imageCalls = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final lower = <String, String>{};
    request.headers.forEach((key, value) => lower[key.toLowerCase()] = value);
    requests.add(CapturedRequest(request.method, request.url, lower));
    if (delay != Duration.zero) {
      await Future<void>.delayed(delay);
    }
    if (request.url.host == 'api.gamer.com.tw') {
      metaCalls++;
      final body = metaBody ??
          metaJson('https://p2.bahamut.com.tw/HOME-BEGAN/dcbcaab4.jpg');
      return _reply(metaStatus, utf8.encode(body), 'application/json');
    }
    imageCalls++;
    final bytes = imageBytes ?? fakeJpeg();
    return _reply(imageStatus, bytes, imageContentType);
  }

  Future<http.StreamedResponse> _reply(
      int status, List<int> bytes, String contentType) async {
    final stream = Stream<List<int>>.value(bytes);
    return http.StreamedResponse(
      stream,
      status,
      contentLength: bytes.length,
      headers: {'content-type': contentType},
    );
  }
}

/// 一碰就炸: 用來證明第二次真的零網路.
class ThrowingClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    throw StateError('must not hit network: ${request.url}');
  }
}

class DelayedSupportPaths extends PathProviderPlatform {
  DelayedSupportPaths(this.documents);

  final String documents;
  final Completer<String?> support = Completer<String?>();

  @override
  Future<String?> getApplicationDocumentsPath() async => documents;

  @override
  Future<String?> getApplicationSupportPath() => support.future;
}

Future<Directory> tempDir() =>
    Directory.systemTemp.createTemp('agp-thumb-test-');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('AppState boot waits until the thumbnail cache is ready', () async {
    final temp = await tempDir();
    final paths = DelayedSupportPaths(temp.path);
    PathProviderPlatform.instance = paths;
    SharedPreferences.setMockInitialValues(const {});

    var completed = false;
    final boot = AppState.boot()..then((_) => completed = true);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final completedBeforeCache = completed;
    paths.support.complete(temp.path);
    final state = await boot;
    try {
      expect(completedBeforeCache, isFalse,
          reason: 'UI must not start before LocalThumb can use its cache');
      expect(state.thumbnails.directory?.path, '${temp.path}/thumbnails');
    } finally {
      state.dispose();
      await temp.delete(recursive: true);
    }
  });

  group('metadata request', () {
    test('direct Bahamut v4 URL with public headers and no Cookie', () async {
      final temp = await tempDir();
      try {
        final fake = FakeBahamut();
        final store = ThumbnailStore(
          httpClient: fake,
          directory: Directory('${temp.path}/thumbs'),
        );
        final file = await store.load('48503');
        expect(file, isNotNull);

        final meta = fake.requests
            .firstWhere((r) => r.url.host == 'api.gamer.com.tw');
        expect(
          meta.url.toString(),
          'https://api.gamer.com.tw/mobile_app/anime/v4/video.php?sn=48503',
        );
        expect(meta.headers.containsKey('cookie'), isFalse,
            reason: 'server token must never leak to Bahamut');
        expect(meta.headers['accept'], contains('application/json'));
        expect(meta.headers['user-agent'], isNotNull);
        expect(meta.headers['user-agent'], isNotEmpty);
      } finally {
        await temp.delete(recursive: true);
      }
    });

    test('image request carries Referer and no Cookie', () async {
      final temp = await tempDir();
      try {
        final fake = FakeBahamut();
        final store = ThumbnailStore(
          httpClient: fake,
          directory: Directory('${temp.path}/thumbs'),
        );
        await store.load('48503');
        final image = fake.requests
            .firstWhere((r) => r.url.host != 'api.gamer.com.tw');
        expect(image.headers.containsKey('cookie'), isFalse);
        expect(image.headers['referer'], contains('ani.gamer.com.tw'));
      } finally {
        await temp.delete(recursive: true);
      }
    });
  });

  group('cover parsing and persistence', () {
    test('cover URL is fetched and bytes land on disk', () async {
      final temp = await tempDir();
      try {
        final fake = FakeBahamut();
        final store = ThumbnailStore(
          httpClient: fake,
          directory: Directory('${temp.path}/thumbs'),
        );
        final file = await store.load('11');
        expect(file, isNotNull);
        expect(await file!.exists(), isTrue);
        expect(await file.readAsBytes(), equals(fakeJpeg()));
        // 同步快照也拿得到: UI 下一次 build 不必等 future
        expect(store.cachedFile('11')?.path, file.path);
      } finally {
        await temp.delete(recursive: true);
      }
    });

    test('second store instance reuses disk with zero network', () async {
      final temp = await tempDir();
      try {
        final dir = Directory('${temp.path}/thumbs');
        final first =
            ThumbnailStore(httpClient: FakeBahamut(), directory: dir);
        final saved = await first.load('22');
        expect(saved, isNotNull);
        first.close();

        final second =
            ThumbnailStore(httpClient: ThrowingClient(), directory: dir);
        final reused = await second.load('22');
        expect(reused, isNotNull);
        expect(reused!.path, saved!.path);
        expect(await reused.readAsBytes(), equals(fakeJpeg()));
        second.close();
      } finally {
        await temp.delete(recursive: true);
      }
    });

    test('concurrent same-SN requests are deduplicated', () async {
      final temp = await tempDir();
      try {
        final fake = FakeBahamut(delay: const Duration(milliseconds: 60));
        final store = ThumbnailStore(
          httpClient: fake,
          directory: Directory('${temp.path}/thumbs'),
        );
        final results = await Future.wait([
          for (var i = 0; i < 6; i++) store.load('33'),
        ]);
        expect(results.every((f) => f != null), isTrue);
        expect(
          results.map((f) => f!.path).toSet(),
          hasLength(1),
        );
        expect(fake.metaCalls, 1);
        expect(fake.imageCalls, 1);
      } finally {
        await temp.delete(recursive: true);
      }
    });
  });

  group('bad responses never become cache files', () {
    test('metadata failures', () async {
      final cases = <String, FakeBahamut>{
        'http 500': FakeBahamut(metaStatus: 500, metaBody: 'oops'),
        'empty body': FakeBahamut(metaStatus: 200, metaBody: ''),
        'not json': FakeBahamut(metaStatus: 200, metaBody: '<html>no</html>'),
        'missing cover':
            FakeBahamut(metaStatus: 200, metaBody: jsonEncode({'data': {}})),
        'empty cover': FakeBahamut(
            metaStatus: 200, metaBody: metaJson('')),
        'non-http cover': FakeBahamut(
            metaStatus: 200, metaBody: metaJson('javascript:alert(1)')),
      };
      for (final entry in cases.entries) {
        final temp = await tempDir();
        try {
          final store = ThumbnailStore(
            httpClient: entry.value,
            directory: Directory('${temp.path}/thumbs'),
          );
          expect(await store.load('44'), isNull, reason: entry.key);
          expect(store.cachedFile('44'), isNull, reason: entry.key);
        } finally {
          await temp.delete(recursive: true);
        }
      }
    });

    test('image failures', () async {
      final cases = <String, FakeBahamut>{
        'http 404': FakeBahamut(imageStatus: 404),
        'empty bytes': FakeBahamut(imageBytes: Uint8List(0)),
        'html content-type': FakeBahamut(
          imageContentType: 'text/html',
          imageBytes: Uint8List.fromList(utf8.encode('<html>err</html>')),
        ),
        'html body disguised as image': FakeBahamut(
          imageContentType: 'image/jpeg',
          imageBytes: Uint8List.fromList(
              utf8.encode('<html>login please</html>'.padRight(64))),
        ),
      };
      for (final entry in cases.entries) {
        final temp = await tempDir();
        try {
          final store = ThumbnailStore(
            httpClient: entry.value,
            directory: Directory('${temp.path}/thumbs'),
          );
          expect(await store.load('55'), isNull, reason: entry.key);
          expect(store.cachedFile('55'), isNull, reason: entry.key);
        } finally {
          await temp.delete(recursive: true);
        }
      }
    });
  });

  group('bounded cache', () {
    test('oldest entries are evicted past the cap', () async {
      final temp = await tempDir();
      try {
        final store = ThumbnailStore(
          httpClient: FakeBahamut(),
          directory: Directory('${temp.path}/thumbs'),
          maxEntries: 2,
        );
        await store.load('1');
        // 讓 mtime 有明確先後, LRU 順序才不會受檔案系統粒度影響
        await store.cachedFile('1')!.setLastModified(
            DateTime.now().subtract(const Duration(days: 2)));
        await store.load('2');
        await store.cachedFile('2')!.setLastModified(
            DateTime.now().subtract(const Duration(days: 1)));
        await store.load('3');

        expect(store.cachedFile('1'), isNull, reason: 'oldest evicted');
        expect(store.cachedFile('2'), isNotNull);
        expect(store.cachedFile('3'), isNotNull);
      } finally {
        await temp.delete(recursive: true);
      }
    });
  });

  group('offline behaviour', () {
    test('uninitialised store fails silently', () async {
      final store = ThumbnailStore(httpClient: FakeBahamut());
      expect(store.cachedFile('1'), isNull);
      // 沒有目錄 (例如 path_provider 還沒好) 就直接回 null, 不丟例外
      expect(await store.load('1'), isNull);
      store.close();
    });
  });

  group('DownloadStore no longer depends on the server proxy', () {
    test('no local-library UI goes through /thumbnail.jpg', () {
      final roots = [
        Directory('${Directory.current.path}/lib/src'),
        Directory('${Directory.current.path}/flutter_app/lib/src'),
      ];
      final lib = roots.firstWhere((candidate) => candidate.existsSync());
      final offenders = <String>[];
      for (final item in lib.listSync(recursive: true)) {
        if (item is! File || !item.path.endsWith('.dart')) continue;
        if (item.path.endsWith('api/client.dart')) continue;
        // 只看程式碼, 註解裡提到舊路徑沒關係
        final code = item
            .readAsStringSync()
            .split('\n')
            .where((line) => !line.trimLeft().startsWith('//'))
            .join('\n');
        if (code.contains('thumbnailUrl') || code.contains('thumbnail.jpg')) {
          offenders.add(item.path);
        }
      }
      expect(offenders, isEmpty,
          reason: 'local thumbs must load client-side: $offenders');
    });

    test('shared Bahamut fetch sends no Cookie and validates images',
        () async {
      final fake = FakeBahamut();
      final bytes =
          await fetchBahamutThumbnailBytes('48503', client: fake);
      expect(bytes, isNotNull);
      expect(bytes, equals(fakeJpeg()));
      for (final request in fake.requests) {
        expect(request.headers.containsKey('cookie'), isFalse);
      }

      final bad = FakeBahamut(imageContentType: 'text/html');
      expect(await fetchBahamutThumbnailBytes('9', client: bad), isNull);
    });
  });

  group('LocalThumb widget', () {
    /// 真的解得出來的 1x1 PNG. widget 測的是「檔案進來就畫 Image」,
    /// 用有效圖片才不會跟解碼錯誤攪在一起.
    final tinyPng = Uint8List.fromList([
      137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82,
      0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0, 31, 21, 196, 137,
      0, 0, 0, 13, 73, 68, 65, 84, 120, 156, 99, 248, 207, 192, 0,
      0, 3, 1, 1, 0, 203, 237, 190, 132, 0, 0, 0, 0, 73, 69, 78,
      68, 174, 66, 96, 130,
    ]);

    Future<Directory> seedPng(String sn) async {
      final temp = await tempDir();
      final store = ThumbnailStore(
        httpClient: FakeBahamut(imageBytes: tinyPng),
        directory: Directory('${temp.path}/thumbs'),
      );
      final file = await store.load(sn);
      expect(file, isNotNull);
      store.close();
      return temp;
    }

    testWidgets('disk file is rendered without network', (tester) async {
      final temp = await seedPng('71');
      try {
        final store = ThumbnailStore(
          httpClient: ThrowingClient(),
          directory: Directory('${temp.path}/thumbs'),
        );
        await tester.pumpWidget(MaterialApp(
          home: Scaffold(
            body: LocalThumb(store: store, sn: '71', name: '測試作品'),
          ),
        ));
        await tester.pump(const Duration(seconds: 1));
        await tester.pump();
        // 零網路、有圖: 磁碟檔直接變成 Image, 也沒有例外
        expect(find.byType(Image), findsOneWidget);
        expect(tester.takeException(), isNull);
        store.close();
      } finally {
        await temp.delete(recursive: true);
      }
    });

    testWidgets('fetched bytes appear as an Image', (tester) async {
      final temp = await tempDir();
      try {
        final store = ThumbnailStore(
          httpClient: FakeBahamut(imageBytes: tinyPng),
          directory: Directory('${temp.path}/thumbs'),
        );
        await tester.pumpWidget(MaterialApp(
          home: Scaffold(
            body: LocalThumb(store: store, sn: '72', name: '測試作品'),
          ),
        ));
        await tester.pump(const Duration(seconds: 1));
        await tester.pump();
        expect(find.byType(Image), findsOneWidget);
        expect(tester.takeException(), isNull);
        store.close();
      } finally {
        await temp.delete(recursive: true);
      }
    });

    testWidgets('failure keeps the gradient fallback quietly', (tester) async {
      final temp = await tempDir();
      try {
        final store = ThumbnailStore(
          httpClient: FakeBahamut(imageStatus: 404),
          directory: Directory('${temp.path}/thumbs'),
        );
        await tester.pumpWidget(MaterialApp(
          home: Scaffold(
            body: LocalThumb(store: store, sn: '73', name: '測試作品'),
          ),
        ));
        await tester.pump(const Duration(seconds: 1));
        await tester.pump();
        // 抓不到: 沒有 Image, 只有底下的漸層, 而且沒有例外
        expect(find.byType(Image), findsNothing);
        expect(tester.takeException(), isNull);
        store.close();
      } finally {
        await temp.delete(recursive: true);
      }
    });

    testWidgets('a stale SN result cannot overwrite a recycled card',
        (tester) async {
      final temp = await tempDir();
      try {
        final store = ThumbnailStore(
          httpClient: FakeBahamut(
            imageBytes: tinyPng,
            delay: const Duration(milliseconds: 60),
          ),
          directory: Directory('${temp.path}/thumbs'),
        );
        Widget card(String sn) => MaterialApp(
              home: Scaffold(
                body: LocalThumb(store: store, sn: sn, name: '測試作品'),
              ),
            );

        await tester.pumpWidget(card('81'));
        await tester.pump(const Duration(milliseconds: 5));
        await tester.pumpWidget(card('82'));
        await tester.pump(const Duration(seconds: 1));
        await tester.pump();

        final image = tester.widget<Image>(find.byType(Image));
        final provider = image.image as FileImage;
        expect(provider.file.path, endsWith('thumb-82.jpg'));
        store.close();
      } finally {
        await temp.delete(recursive: true);
      }
    });
  });
}
