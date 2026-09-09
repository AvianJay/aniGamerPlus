/// 影片快取那台小伺服器. 它擋在播放器跟真伺服器中間, 錯了就是整支播不出來,
/// 所以這裡對著一台假的上游把每一條路都走過一遍.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:agp_mobile/src/state/video_cache.dart';

/// 一支假的 mp4: 每個 byte 都是它自己位移的低八位, 所以任何一段都驗得出來
List<int> body(int total) =>
    List<int>.generate(total, (index) => index % 251);

class Upstream {
  Upstream(this.server, this.data);

  final HttpServer server;
  final List<int> data;

  /// 收到幾個請求. 用來確認第二次真的沒去問上游.
  int requests = 0;
  bool refuse = false;

  /// 每 64 KB 之間歇一下, 用來模擬一條慢線路
  Duration chunkDelay = Duration.zero;

  /// 真的送進 socket 的量. 用來確認播放器不讀的時候, 我們也就不抓.
  int served = 0;

  /// 分片被跟上游要了幾次
  int segmentHits = 0;

  static Future<Upstream> start(int total) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final upstream = Upstream(server, body(total));
    server.listen((request) async {
      upstream.requests++;
      final response = request.response;
      if (upstream.refuse) {
        response.statusCode = HttpStatus.internalServerError;
        await response.close();
        return;
      }
      // 換畫質那條路: /stream/playlist.m3u8 + 相對路徑的分片
      if (request.uri.path.endsWith('playlist.m3u8')) {
        response.headers.set(HttpHeaders.contentTypeHeader,
            'application/vnd.apple.mpegurl');
        response.write('#EXTM3U\n#EXT-X-VERSION:3\n'
            '#EXT-X-TARGETDURATION:4\n#EXT-X-PLAYLIST-TYPE:VOD\n'
            '#EXTINF:4.0,\nsegment.ts?id=1&res=720&n=0\n'
            '#EXTINF:4.0,\nsegment.ts?id=1&res=720&n=1\n'
            '#EXT-X-ENDLIST\n');
        await response.close();
        return;
      }
      if (request.uri.path.endsWith('segment.ts')) {
        final n = int.tryParse(request.uri.queryParameters['n'] ?? '0') ?? 0;
        upstream.segmentHits++;
        response.headers.set(HttpHeaders.contentTypeHeader, 'video/mp2t');
        response.add(List<int>.filled(4096, 100 + n));
        await response.close();
        return;
      }

      final data = upstream.data;
      final header = request.headers.value(HttpHeaders.rangeHeader);
      var start = 0;
      var end = data.length - 1;
      if (header != null && header.startsWith('bytes=')) {
        final spec = header.substring(6).split('-');
        start = int.tryParse(spec[0]) ?? 0;
        if (spec.length > 1 && spec[1].isNotEmpty) {
          end = int.tryParse(spec[1]) ?? end;
        }
        if (end > data.length - 1) end = data.length - 1;
        response.statusCode = HttpStatus.partialContent;
        response.headers.set(HttpHeaders.contentRangeHeader,
            'bytes $start-$end/${data.length}');
      }
      response.headers.set(HttpHeaders.etagHeader, '"stub-v1"');
      response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      // 一塊一塊送, 而且走 addStream —— 這樣「送出去多少」才會跟著對面讀多快
      const step = 64 * 1024;
      Stream<List<int>> pieces() async* {
        for (var at = start; at <= end; at += step) {
          final stop = (at + step - 1) > end ? end : at + step - 1;
          upstream.served += stop - at + 1;
          yield data.sublist(at, stop + 1);
          if (upstream.chunkDelay != Duration.zero) {
            await Future<void>.delayed(upstream.chunkDelay);
          }
        }
      }

      try {
        await response.addStream(pieces());
        await response.close();
      } catch (_) {
        // 對面中途跑掉了
      }
    });
    return upstream;
  }

  Uri get url => Uri.parse('http://127.0.0.1:${server.port}/get_video.mp4');

  Uri get playlist => Uri.parse(
      'http://127.0.0.1:${server.port}/stream/playlist.m3u8?id=1&res=720');

  Future<void> stop() => server.close(force: true);
}

Future<List<int>> fetch(Uri url, {String? range}) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(url);
    if (range != null) request.headers.set(HttpHeaders.rangeHeader, range);
    final response = await request.close();
    final bytes = <int>[];
    await for (final chunk in response) {
      bytes.addAll(chunk);
    }
    return bytes;
  } finally {
    client.close(force: true);
  }
}

void main() {
  late Directory temp;
  late Upstream upstream;
  late VideoCacheServer cache;

  // 頭尾加起來要小於 total, 中間才會空出一段必須跟上游要的
  const total = 8 * 1024 * 1024;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('agp-cache-test-');
    upstream = await Upstream.start(total);
    final server = await VideoCacheServer.start(temp);
    expect(server, isNotNull);
    cache = server!;
  });

  tearDown(() async {
    await cache.close();
    await upstream.stop();
    try {
      await temp.delete(recursive: true);
    } catch (_) {
      // 收尾刪暫存目錄失敗不該讓測試變紅 (Windows 上背景還在掃的時候會這樣)
    }
  });

  Uri wrap() => cache.wrap(
      upstream: upstream.url, headers: const {}, key: 'v123-1080');

  /// 這一段有沒有被存下來 (整塊整塊算)
  bool blocksCached(int start, int end) {
    for (var block = start ~/ kCacheBlockBytes;
        block <= end ~/ kCacheBlockBytes;
        block++) {
      if (!File('${temp.path}/v123-1080/$block.blk').existsSync()) {
        return false;
      }
    }
    return true;
  }

  test('整份抓下來跟上游一模一樣', () async {
    final url = wrap();
    final bytes = await fetch(url);
    expect(bytes.length, total);
    expect(bytes, equals(upstream.data));
  });

  test('讀過的段落會留在磁碟上, 再讀一次不必問上游', () async {
    // 這就是「看到一半退出再回來」要的: 已經載過的別再載一次
    final url = wrap();
    const from = 3 * kCacheBlockBytes;
    const to = from + 2 * kCacheBlockBytes - 1;
    final first = await fetch(url, range: 'bytes=$from-$to');
    expect(first, equals(upstream.data.sublist(from, to + 1)));
    expect(blocksCached(from, to), isTrue);

    // 上游倒掉, 同一段還是發得出來
    upstream.refuse = true;
    final again = await fetch(url, range: 'bytes=$from-$to');
    expect(again, equals(upstream.data.sublist(from, to + 1)));
  });

  test('跳轉到不對齊的位置也存得起來', () async {
    // moov 在檔尾而且不對齊. 不往前對齊到塊開頭的話, 那一塊永遠只拿得到半塊,
    // 也就永遠存不進去 —— 每次開同一集都要重抓一次.
    // 播放器跳轉時發的是開放式的 bytes=N- (要到檔尾), 所以尾巴那塊一定是完整的;
    // 會不會存起來全看開頭那塊有沒有往前對齊.
    final url = wrap();
    const from = 5 * kCacheBlockBytes + 12345;
    final first = await fetch(url, range: 'bytes=$from-');
    expect(first, equals(upstream.data.sublist(from)));

    upstream.refuse = true;
    final again = await fetch(url, range: 'bytes=$from-');
    expect(again, equals(upstream.data.sublist(from)),
        reason: '不對齊的跳轉沒有被快取住');
  });

  test('一半在快取一半不在, 要拼得起來', () async {
    final url = wrap();
    const cachedFrom = 2 * kCacheBlockBytes;
    const cachedTo = cachedFrom + kCacheBlockBytes - 1;
    await fetch(url, range: 'bytes=$cachedFrom-$cachedTo');

    // 跨過已經有的那一塊, 兩邊都要對
    const from = cachedFrom - 4096;
    const to = cachedTo + 4096;
    final bytes = await fetch(url, range: 'bytes=$from-$to');
    expect(bytes, equals(upstream.data.sublist(from, to + 1)));
  });

  test('播放器要的那兩段 (開頭 + moov 所在的檔尾) 都對得上', () async {
    final url = wrap();

    final head = await fetch(url, range: 'bytes=0-${kCacheBlockBytes - 1}');
    expect(head.length, kCacheBlockBytes);
    expect(head, equals(upstream.data.sublist(0, kCacheBlockBytes)));

    final tailStart = total - kCacheBlockBytes;
    final tail = await fetch(url, range: 'bytes=$tailStart-${total - 1}');
    expect(tail.length, kCacheBlockBytes);
    expect(tail, equals(upstream.data.sublist(tailStart)));
  });

  test('上游倒了, 快取住的段落照樣發得出來', () async {
    final url = wrap();
    // 先整份讀過一遍 (等於看完了)
    await fetch(url);
    upstream.refuse = true;

    final head = await fetch(url, range: 'bytes=0-65535');
    expect(head, equals(upstream.data.sublist(0, 65536)));

    final tailStart = total - 65536;
    final tail = await fetch(url, range: 'bytes=$tailStart-${total - 1}');
    expect(tail, equals(upstream.data.sublist(tailStart)));
  });

  test('app 重開之後, 看過的段落還在', () async {
    // 這是使用者真正在意的那一句: 關掉再開, 剛剛載好的別再載一次
    var url = wrap();
    const from = 0;
    const to = 2 * kCacheBlockBytes - 1;
    await fetch(url, range: 'bytes=$from-$to');
    await cache.close();

    final second = await VideoCacheServer.start(temp);
    expect(second, isNotNull);
    cache = second!;
    upstream.requests = 0;
    url = wrap();

    final bytes = await fetch(url, range: 'bytes=$from-$to');
    expect(bytes, equals(upstream.data.sublist(from, to + 1)));
    // 只該有那一個 byte 的驗證請求, 不該把資料重抓一遍
    expect(upstream.requests, lessThanOrEqualTo(1));
  });

  test('伺服器上換了檔案就把舊的丟掉', () async {
    var url = wrap();
    await fetch(url);

    // 換一份長度不一樣的
    upstream.data
      ..clear()
      ..addAll(body(total ~/ 2));
    url = wrap();
    final bytes = await fetch(url);
    expect(bytes.length, total ~/ 2);
    expect(bytes, equals(upstream.data));
  });

  test('讀到一半就跑掉, 那半塊也算數', () async {
    // 播放器開一集時只會把檔頭讀個兩三百 KB 就跑去拿 moov, 那一塊永遠湊不滿.
    // 只認滿塊的話最常走的那條路就永遠快取不到.
    final url = wrap();
    final client = HttpClient();
    try {
      final request = await client.getUrl(url);
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-');
      final response = await request.close();
      var read = 0;
      await for (final chunk in response) {
        read += chunk.length;
        if (read >= 200 * 1024) break;
      }
    } finally {
      client.close(force: true);
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));

    // 上游倒掉, 剛剛讀過的那前 128 KB 還是發得出來
    upstream.refuse = true;
    final again = await fetch(url, range: 'bytes=0-${128 * 1024 - 1}');
    expect(again, equals(upstream.data.sublist(0, 128 * 1024)),
        reason: '沒讀滿一塊的前綴沒有被快取住');
  });

  test('換畫質那條路 (HLS) 的分片也要存下來', () async {
    // 這條路以前完全沒有快取: 換過畫質之後看的每一集, 關掉 app 再回來都要
    // 整個重抓. 使用者在慢網路上把畫質調低, 結果反而完全享受不到快取.
    var url = cache.wrapHls(
        playlist: upstream.playlist, headers: const {}, key: 's1-720');

    final list = await fetch(url);
    expect(String.fromCharCodes(list), contains('segment.ts?id=1&res=720&n=0'));

    // 播放器照著清單去要分片 —— 相對路徑會落回這台上
    final seg0 = url.resolve('segment.ts?id=1&res=720&n=0');
    final first = await fetch(seg0);
    expect(first.length, 4096);
    expect(upstream.segmentHits, 1);

    // 再要一次同一片: 該從磁碟出來, 不再問上游
    final again = await fetch(seg0);
    expect(again, equals(first));
    expect(upstream.segmentHits, 1, reason: '分片沒有被快取住');

    // app 關掉再開, 分片還在
    await cache.close();
    final second = await VideoCacheServer.start(temp);
    cache = second!;
    url = cache.wrapHls(
        playlist: upstream.playlist, headers: const {}, key: 's1-720');
    upstream.refuse = true;
    final afterRestart =
        await fetch(url.resolve('segment.ts?id=1&res=720&n=0'));
    expect(afterRestart, equals(first), reason: '重開之後分片不見了');
  });

  test('完全不預抓: 沒被要求過的段落不會出現在磁碟上', () async {
    // 舊版一開播就衝去抓頭尾, 在慢線路上把播放要的頻寬吃光. 現在只從播放器
    // 本來就要的東西順手撿, 所以沒讀過的地方不該有任何檔案.
    final url = wrap();
    await fetch(url, range: 'bytes=0-${kCacheBlockBytes - 1}');
    await Future<void>.delayed(const Duration(seconds: 2));
    expect(blocksCached(0, kCacheBlockBytes - 1), isTrue);
    expect(File('${temp.path}/v123-1080/5.blk').existsSync(), isFalse,
        reason: '沒人要過的段落不該被預抓');
  });

  test('播放器停下來不讀時, 我們也停下來不抓', () async {
    // 之前這裡是手動 response.add(): 播放器緩衝滿了不再讀 socket, 但代理還是
    // 全速把上游灌進記憶體 —— 慢線路上頻寬全花在沒人要的資料上, 畫面就一直
    // 轉圈. addStream 會把 socket 的回壓一路傳到上游.
    final url = wrap();
    final client = HttpClient();
    try {
      final request = await client.getUrl(url);
      // 中間那段沒有快取, 一定走上游
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=${total ~/ 2}-');
      final response = await request.close();

      upstream.served = 0;
      var read = 0;
      final done = Completer<void>();
      late StreamSubscription<List<int>> sub;
      sub = response.listen((chunk) {
        read += chunk.length;
        if (read >= 128 * 1024 && !done.isCompleted) {
          // 播放器緩衝滿了: 不再讀, 但也還沒斷線
          sub.pause();
          done.complete();
        }
      }, onError: (Object _) {}, cancelOnError: false);
      await done.future;

      // 對面不讀了, 上游那邊就該停下來
      await Future<void>.delayed(const Duration(seconds: 3));
      final servedWhilePaused = upstream.served;
      await sub.cancel();

      // socket 跟中間那幾層本來就吃得下一些, 但不該是整段 4 MB
      expect(servedWhilePaused, lessThan(total ~/ 4),
          reason: '播放器沒在讀, 卻還是把上游抓了 $servedWhilePaused bytes 進來');
    } finally {
      client.close(force: true);
    }
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('轉手過的量算得出速度, 從磁碟讀的不算', () async {
    final url = wrap();
    await fetch(url, range: 'bytes=0-${kCacheBlockBytes - 1}');
    expect(cache.bytesPerSecond, greaterThan(0));

    // 等取樣視窗過去, 然後只讀快取住的那一段: 沒有流量, 速度該回到 0
    await Future<void>.delayed(kSpeedWindow + const Duration(milliseconds: 200));
    expect(cache.bytesPerSecond, 0);
    await fetch(url, range: 'bytes=0-65535');
    expect(cache.bytesPerSecond, 0);
  });
}
