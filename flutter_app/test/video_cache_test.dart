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
    await temp.delete(recursive: true);
  });

  Uri wrap() => cache.wrap(
      upstream: upstream.url, headers: const {}, key: 'v123-1080');

  /// 補齊是背景做的, 而且會等播放那條路安靜下來才動 —— 等它把頭尾都寫完
  Future<void> settle() async {
    for (var i = 0; i < 300; i++) {
      final head = File('${temp.path}/v123-1080.head');
      final tail = File('${temp.path}/v123-1080.tail');
      if (head.existsSync() &&
          tail.existsSync() &&
          head.lengthSync() == kCacheHeadBytes &&
          tail.lengthSync() == kCacheTailBytes) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    fail('頭尾沒有在時限內補齊');
  }

  test('整份抓下來跟上游一模一樣', () async {
    final url = wrap();
    await settle();
    final bytes = await fetch(url);
    expect(bytes.length, total);
    expect(bytes, equals(upstream.data));
  });

  test('播放器要的那兩段 (開頭 + moov 所在的檔尾) 都對得上', () async {
    final url = wrap();
    await settle();

    final head = await fetch(url, range: 'bytes=0-${kCacheHeadBytes - 1}');
    expect(head.length, kCacheHeadBytes);
    expect(head, equals(upstream.data.sublist(0, kCacheHeadBytes)));

    final tailStart = total - kCacheTailBytes;
    final tail = await fetch(url, range: 'bytes=$tailStart-${total - 1}');
    expect(tail.length, kCacheTailBytes);
    expect(tail, equals(upstream.data.sublist(tailStart)));
  });

  test('跨越快取邊界的一段要拼得起來', () async {
    final url = wrap();
    await settle();
    // 從頭快取裡面一路要到中間那段沒快取的地方
    const start = kCacheHeadBytes - 4096;
    const end = kCacheHeadBytes + 4096;
    final bytes = await fetch(url, range: 'bytes=$start-$end');
    expect(bytes.length, end - start + 1);
    expect(bytes, equals(upstream.data.sublist(start, end + 1)));
  });

  test('上游倒了, 快取住的那兩塊照樣發得出來', () async {
    final url = wrap();
    await settle();
    // 這正是「app 關掉再開」要的效果: 檔頭在磁碟上, 不必再問伺服器
    upstream.refuse = true;

    final head = await fetch(url, range: 'bytes=0-65535');
    expect(head, equals(upstream.data.sublist(0, 65536)));

    final tailStart = total - 65536;
    final tail = await fetch(url, range: 'bytes=$tailStart-${total - 1}');
    expect(tail, equals(upstream.data.sublist(tailStart)));
  });

  test('磁碟上那份還在的話, 重開一台伺服器不必再跟上游要', () async {
    wrap();
    await settle();
    await cache.close();

    final second = await VideoCacheServer.start(temp);
    expect(second, isNotNull);
    cache = second!;
    upstream.requests = 0;
    final url = wrap();
    // 補齊那一輪只會去驗一次長度 (1 byte 的 Range), 不會把頭尾重抓一遍
    await Future<void>.delayed(const Duration(milliseconds: 400));
    final head = await fetch(url, range: 'bytes=0-65535');
    expect(head, equals(upstream.data.sublist(0, 65536)));
    expect(upstream.requests, lessThanOrEqualTo(1));
  });

  test('伺服器上換了檔案就把舊的丟掉', () async {
    wrap();
    await settle();

    // 換一份長度不一樣的
    upstream.data
      ..clear()
      ..addAll(body(total ~/ 2));
    final url = wrap();
    for (var i = 0; i < 100; i++) {
      final head = File('${temp.path}/v123-1080.head');
      if (head.existsSync() && head.lengthSync() == kCacheHeadBytes) {
        final bytes = await fetch(url, range: 'bytes=0-4095');
        if (bytes[0] == upstream.data[0]) break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    final bytes = await fetch(url);
    expect(bytes.length, total ~/ 2);
    expect(bytes, equals(upstream.data));
  });

  test('播放器在要東西的時候, 補快取要讓路', () async {
    // 這是整個快取最重要的一條規矩. 之前它一 wrap 就衝去抓 6 MB, 在慢線路上
    // 直接把播放要的頻寬吃光, 畫面就卡在轉圈 —— 這個測試把那件事釘住.
    upstream.chunkDelay = const Duration(milliseconds: 30);
    final url = wrap();

    // 持續讓播放那條路有動靜, 時間拉得比 kPrimeIdleGap 長
    final until = DateTime.now().add(const Duration(seconds: 7));
    while (DateTime.now().isBefore(until)) {
      // 中間那段沒有快取, 一定會走上游
      await fetch(url, range: 'bytes=${total ~/ 2}-${total ~/ 2 + 32767}');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      // 一直有人在看的時候, 快取不該偷偷補完
      expect(File('${temp.path}/v123-1080.tail').existsSync(), isFalse,
          reason: '播放中不該把頻寬拿去補快取');
    }

    // 人停下來了, 這時候補才是對的
    upstream.chunkDelay = Duration.zero;
    await settle();
  }, timeout: const Timeout(Duration(minutes: 2)));

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
    await settle();
    expect(cache.bytesPerSecond, greaterThan(0));

    // 等取樣視窗過去, 然後只讀快取住的那一段: 沒有流量, 速度該回到 0
    await Future<void>.delayed(kSpeedWindow + const Duration(milliseconds: 200));
    expect(cache.bytesPerSecond, 0);
    await fetch(url, range: 'bytes=0-65535');
    expect(cache.bytesPerSecond, 0);
  });
}
