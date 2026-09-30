/// iOS 的下載: 影片檔交給系統的背景 URLSession, DownloadStore 只管狀態.
///
/// 原生那一半用假的 MethodChannel 頂著: 記下 Dart 叫了什麼, 需要的時候從
/// 「原生」那邊丟事件回來. 要驗的是 Dart 這邊的狀態機 —— 開始、進度、暫停、
/// 做完、404, 還有 App 被系統收掉重開之後怎麼把背景裡的下載接回來.
library;

import 'dart:async';
import 'dart:io';

import 'package:agp_mobile/src/api/client.dart';
import 'package:agp_mobile/src/api/models.dart';
import 'package:agp_mobile/src/state/downloads.dart';
import 'package:background_download/background_download.dart';
import 'package:flutter/services.dart';
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

const MethodChannel channel = MethodChannel('background_download');

/// 假的原生端
class FakeNative {
  final List<MethodCall> calls = [];
  List<Map<String, Object?>> running = [];
  List<Map<String, Object?>> results = [];

  /// download.cancel 要不要說「有停到東西」
  bool cancelFinds = true;

  Iterable<Map<dynamic, dynamic>> argsOf(String method) => calls
      .where((call) => call.method == method)
      .map((call) => call.arguments as Map);

  Future<Object?> handle(MethodCall call) async {
    calls.add(call);
    switch (call.method) {
      case 'download.cancel':
        return cancelFinds;
      case 'download.snapshot':
        return {'running': running, 'results': results};
    }
    return null;
  }

  /// 從原生那邊送一個事件給 Dart
  Future<void> emit(String method, Map<String, Object?> args) async {
    final completer = Completer<void>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(MethodCall(method, args)),
      (_) => completer.complete(),
    );
    await completer.future;
    // 讓 Dart 那邊接著的 await 都跑完
    await pumpEventQueue();
  }
}

/// 收尾那一段會去抓封面 (真的 I/O), 一輪 event queue 不一定等得到.
/// 開始下載也一樣: 交給原生之前要先看一眼 .part 有多長, 那也是真的 I/O ——
/// CI 的機器慢一點, pumpEventQueue() 那二十輪就等不到.
Future<void> eventually(bool Function() condition) async {
  for (var i = 0; i < 100 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

VideoItem video(String sn) =>
    VideoItem(sn: sn, animeName: '測試動畫', episode: '1', resolution: 1080);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temp;
  late FakeNative fake;
  late AgpClient client;
  late NativeTransfer native;
  late DownloadStore store;

  /// 原生那邊至少收到 [count] 次開始下載
  bool started(int count) => fake.argsOf('download.start').length >= count;

  Future<DownloadStore> boot() async {
    final made = DownloadStore(client, native: native);
    await made.init();
    return made;
  }

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('agp-native-test-');
    PathProviderPlatform.instance = Paths(temp.path);
    fake = FakeNative();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, fake.handle);
    // 連不上的位址: 做完之後抓封面那一步直接失敗, 不會卡住
    client = AgpClient(baseUrl: 'http://127.0.0.1:9');
    native = NativeTransfer(channel: channel);
    store = await boot();
  });

  tearDown(() async {
    store.dispose();
    client.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await deleteTempDir(temp);
  });

  test('開始下載交給原生, 進度跟完成都照原生報的', () async {
    final entry = await store.enqueue(video('100'), withDanmaku: false);
    await eventually(() => started(1));

    final start = fake.argsOf('download.start').single;
    expect(start['sn'], '100');
    expect(start['name'], entry.videoFileName);
    expect(start['directory'], store.directory.path);
    expect(start['offset'], 0);
    expect(start['allowCellular'], isTrue);
    expect(entry.status, DownloadStatus.running);

    await fake.emit('download.progress',
        {'sn': '100', 'received': 400, 'total': 1000});
    expect(entry.received, 400);
    expect(entry.total, 1000);

    // 原生那邊已經把檔案搬到位了才回報 done
    await store.videoFile(entry).writeAsBytes(List.filled(1000, 1));
    await fake.emit('download.result',
        {'sn': '100', 'status': 'done', 'received': 1000, 'total': 1000});

    await eventually(() => fake.argsOf('download.ack').isNotEmpty);
    expect(entry.status, DownloadStatus.done);
    expect(entry.received, 1000);
    expect(store.localVideo('100'), isNotNull);
    expect(fake.argsOf('download.ack').map((args) => args['sn']), ['100']);
  });

  test('暫停叫原生停, 續傳時從 .part 的長度接著要', () async {
    final entry = await store.enqueue(video('200'), withDanmaku: false);
    await eventually(() => started(1));

    await store.pause('200');
    await eventually(() => fake.argsOf('download.cancel').isNotEmpty);
    expect(fake.argsOf('download.cancel').single['sn'], '200');
    // 系統把抓到一半的那段留在續傳資料裡, 回報的進度比 .part 多
    await fake.emit('download.result',
        {'sn': '200', 'status': 'cancelled', 'received': 700});
    expect(entry.status, DownloadStatus.paused);
    expect(entry.received, 700);
    expect(fake.argsOf('download.ack'), isEmpty,
        reason: '叫停的結果原生那邊本來就不留, 不必 ack');

    await store.partFile(entry).writeAsBytes(List.filled(300, 1));
    await store.resume('200');
    await eventually(() => started(2));
    final starts = fake.argsOf('download.start').toList();
    expect(starts, hasLength(2));
    expect(starts.last['offset'], 300);
  });

  test('原生那邊沒東西可停的時候, 暫停也要收得完', () async {
    fake.cancelFinds = false;
    final entry = await store.enqueue(video('250'), withDanmaku: false);
    await eventually(() => started(1));

    await store.pause('250');
    await eventually(() => entry.status == DownloadStatus.paused);
    expect(entry.status, DownloadStatus.paused);

    // 那一格讓出來了: 繼續的話會再開一次
    await store.resume('250');
    await eventually(() => started(2));
    expect(fake.argsOf('download.start'), hasLength(2));
  });

  test('伺服器 404 就回去等, 不算失敗', () async {
    final entry = await store.enqueue(video('300'), withDanmaku: false);
    await eventually(() => started(1));

    await fake.emit('download.result', {'sn': '300', 'status': 'notFound'});
    expect(entry.status, DownloadStatus.waiting);
    expect(entry.error, isEmpty);
  });

  test('失敗照原生給的原因顯示', () async {
    final entry = await store.enqueue(video('350'), withDanmaku: false);
    await eventually(() => started(1));

    await fake.emit('download.result',
        {'sn': '350', 'status': 'failed', 'error': '伺服器回應 500'});
    expect(entry.status, DownloadStatus.failed);
    expect(entry.error, '伺服器回應 500');
  });

  test('App 進背景時, 排隊的全部交給系統', () async {
    store.concurrency = 1;
    for (final sn in ['400', '401', '402']) {
      await store.enqueue(video(sn), withDanmaku: false);
    }
    await eventually(() => started(1));
    // 再多等幾輪: 同時只開一集的話, 等多久都只該有一個
    await pumpEventQueue();
    expect(fake.argsOf('download.start'), hasLength(1));

    store.setBackgrounded(true);
    await eventually(() => started(3));
    expect(
      fake.argsOf('download.start').map((args) => args['sn']).toSet(),
      {'400', '401', '402'},
    );
  });

  test('App 被收掉重開: 做完的收下來, 還在跑的接回去', () async {
    final done = await store.enqueue(video('500'), withDanmaku: false);
    final still = await store.enqueue(video('501'), withDanmaku: false);
    await store.enqueue(video('502'), withDanmaku: false);
    await eventually(() => started(1));
    // 不再理會原生的回覆, 當作 App 在這裡被系統收掉了
    store.dispose();

    // 背景裡: 500 做完了 (檔案已經搬好), 501 還在抓, 502 伺服器沒有
    await store.videoFile(done).writeAsBytes(List.filled(10, 1));
    fake
      ..calls.clear()
      ..results = [
        {'sn': '500', 'status': 'done', 'received': 10, 'total': 10},
        {'sn': '502', 'status': 'notFound'},
      ]
      ..running = [
        {'sn': '501', 'name': still.videoFileName, 'received': 50, 'total': 90},
      ];

    store = await boot();
    await eventually(() => fake.argsOf('download.ack').length >= 2);

    expect(store.entryFor('500')!.status, DownloadStatus.done);
    expect(store.entryFor('502')!.status, DownloadStatus.waiting);
    final attached = store.entryFor('501')!;
    expect(attached.status, DownloadStatus.running);
    expect(attached.received, 50);
    expect(fake.argsOf('download.start'), isEmpty,
        reason: '還在背景跑的只要接回來, 不能再開一個');
    expect(fake.argsOf('download.ack').map((args) => args['sn']).toSet(),
        {'500', '502'});

    // 接回來的那一集做完了也照常收尾
    await store.videoFile(attached).writeAsBytes(List.filled(90, 1));
    await fake.emit('download.result',
        {'sn': '501', 'status': 'done', 'received': 90, 'total': 90});
    expect(attached.status, DownloadStatus.done);
  });

  test('背景裡還在抓、但那一集已經被刪了: 叫原生停掉並丟掉續傳資料', () async {
    fake.running = [
      {'sn': '600', 'name': '600-1080p.mp4', 'received': 1, 'total': 2},
    ];
    store.dispose();
    store = await boot();
    await eventually(() => fake.argsOf('download.discard').isNotEmpty);

    expect(fake.argsOf('download.cancel').single['sn'], '600');
    expect(fake.argsOf('download.discard').single['name'], '600-1080p.mp4');
    expect(store.entryFor('600'), isNull);
  });

  test('刪掉一集時連原生的續傳資料一起丟', () async {
    final entry = await store.enqueue(video('700'), withDanmaku: false);
    await eventually(() => started(1));

    final removing = store.remove('700');
    await eventually(() => fake.argsOf('download.cancel').isNotEmpty);
    await fake.emit('download.result', {'sn': '700', 'status': 'cancelled'});
    await removing;

    expect(fake.argsOf('download.discard').single['name'], entry.videoFileName);
    expect(store.entryFor('700'), isNull);
  });
}
