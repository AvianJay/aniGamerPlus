/// 匯出影片檔: 檔名怎麼取、哪些檔案會交出去, 以及選單 → 系統選擇器 → 進度
/// 對話框這一整條.
///
/// 系統選擇器本身是原生的, 這裡把 file_export 的 MethodChannel 換成假的:
/// 收到 save 就記下檔案清單, 需要的話先回報幾次進度, 再照測試指定的結果回覆.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agp_mobile/src/api/client.dart';
import 'package:agp_mobile/src/pages/downloads_page.dart';
import 'package:agp_mobile/src/pages/export_sheet.dart';
import 'package:agp_mobile/src/state/app_state.dart';
import 'package:agp_mobile/src/state/downloads.dart';
import 'package:agp_mobile/src/state/video_export.dart';
import 'package:file_export/file_export.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/temp_dir.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
}

const String _ass = '[Script Info]\nScriptType: v4.00+\n\n[Events]\n'
    'Dialogue: 0,0:00:01.00,0:00:09.00,R2L,,0,0,0,,測試\n';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('export file names', () {
    test('illegal characters turn full-width like the server does', () {
      expect(legalizeFileName('Re:Zero|| 第二季?/特別篇*'), 'Re：Zero｜ 第二季？／特別篇＊');
      expect(legalizeFileName('a//b\\\\c'), 'a／／b＼＼c');
      expect(legalizeFileName('  .hidden.  '), 'hidden');
      expect(legalizeFileName('tab\there'), 'tabhere');
    });

    test('base name follows the server layout without the prefix', () {
      expect(
          exportBaseName(DownloadEntry(
              sn: '1', animeName: '葬送的芙莉蓮', episode: '12', resolution: 1080)),
          '葬送的芙莉蓮[12][1080P]');
      expect(
          exportBaseName(DownloadEntry(sn: '2', title: '劇場版', resolution: 0)),
          '劇場版');
      expect(exportBaseName(DownloadEntry(sn: '3')), '3');
    });

    test('long names are cut on a character boundary under the byte limit', () {
      final name = exportBaseName(DownloadEntry(
          sn: '4', animeName: '長' * 120, episode: '1', resolution: 720));
      expect(utf8.encode(name).length, lessThanOrEqualTo(kExportNameMaxBytes));
      expect(name, '長' * (kExportNameMaxBytes ~/ 3));
    });
  });

  group('with downloaded episodes', () {
    late Directory temp;
    late DownloadStore store;
    final calls = <MethodCall>[];

    /// save 要回什麼. 預設是「全部存好」.
    late Future<Object?> Function(MethodCall call) onSave;

    Future<void> seed(List<Map<String, dynamic>> entries) async {
      final dir = Directory('${temp.path}/downloads');
      await dir.create(recursive: true);
      for (final entry in entries) {
        final sn = entry['sn'];
        final res = entry['resolution'] ?? 0;
        final name = res > 0 ? '$sn-${res}p.mp4' : '$sn.mp4';
        if (entry['missing'] != true) {
          await File('${dir.path}/$name').writeAsBytes(List.filled(64, 7));
        }
        if (entry['hasDanmaku'] == true) {
          await File('${dir.path}/$sn.ass').writeAsString(_ass);
        }
      }
      await File('${dir.path}/index.json').writeAsString(jsonEncode([
        for (final entry in entries)
          {
            'status': 'done',
            'total': 64,
            'received': 64,
            'wantDanmaku': false,
            ...entry,
          },
      ]));
    }

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('agp-export-');
      PathProviderPlatform.instance = _Paths(temp.path);
      calls.clear();
      onSave = (call) async {
        final files = (call.arguments as Map)['files'] as List;
        return {'saved': files.length, 'cancelled': false};
      };
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(FileExport.channel, (call) async {
        calls.add(call);
        if (call.method == 'save') return onSave(call);
        return null;
      });
    });

    tearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(FileExport.channel, null);
      store.dispose();
      await deleteTempDir(temp);
    });

    Future<void> boot() async {
      store = DownloadStore(AgpClient(
          baseUrl: 'http://example.test',
          httpClient: MockClient((_) async => http.Response('', 404))));
      await store.setNetworkAllowed(false);
      await store.init(concurrency: 1);
      store.concurrency = 0;
    }

    List<Map> savedFiles() => [
          for (final call in calls.where((c) => c.method == 'save'))
            ...((call.arguments as Map)['files'] as List).cast<Map>(),
        ];

    test('danmaku goes along only when asked and the file exists', () async {
      await seed([
        {
          'sn': '101',
          'anime_name': '作品',
          'episode': '1',
          'resolution': 1080,
          'hasDanmaku': true
        },
        {'sn': '102', 'anime_name': '作品', 'episode': '2', 'resolution': 1080},
        {'sn': '103', 'anime_name': '作品', 'episode': '3', 'missing': true},
      ]);
      await boot();
      final entries = [
        for (final sn in ['101', '102', '103'])
          if (store.entryFor(sn) case final entry?) entry,
      ];

      final plain = exportFilesFor(store, entries, withDanmaku: false);
      expect(
          plain.map((f) => f.name), ['作品[1][1080P].mp4', '作品[2][1080P].mp4']);

      final withDanmaku = exportFilesFor(store, entries, withDanmaku: true);
      expect(withDanmaku.map((f) => f.name), [
        '作品[1][1080P].mp4',
        '作品[1][1080P].ass',
        '作品[2][1080P].mp4',
      ]);
      expect(withDanmaku[1].path, endsWith('101.ass'));
      expect(withDanmaku[1].mimeType, 'application/octet-stream');
    });

    test('episodes that would share a name keep their danmaku paired',
        () async {
      await seed([
        {'sn': '201', 'title': '同名', 'hasDanmaku': true},
        {'sn': '202', 'title': '同名', 'hasDanmaku': true},
      ]);
      await boot();
      final files = exportFilesFor(
          store, [store.entryFor('201')!, store.entryFor('202')!],
          withDanmaku: true);
      expect(files.map((f) => f.name),
          ['同名.mp4', '同名.ass', '同名-202.mp4', '同名-202.ass']);
    });

    Future<void> pumpLauncher(WidgetTester tester, {String? only}) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () => showExportSheet(context, store, only: only),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('one episode exports under a readable name with its danmaku',
        (tester) async {
      await tester.runAsync(() async {
        await seed([
          {
            'sn': '301',
            'anime_name': '孤獨搖滾!',
            'episode': '5',
            'resolution': 720,
            'hasDanmaku': true
          },
        ]);
        await boot();
      });
      await pumpLauncher(tester, only: '301');

      expect(find.text('孤獨搖滾![5][720P].mp4'), findsOneWidget);
      expect(find.text('附上彈幕字幕檔'), findsOneWidget);

      await tester.tap(find.text('選擇儲存位置'));
      await tester.pumpAndSettle();

      expect(savedFiles().map((f) => f['name']),
          ['孤獨搖滾![5][720P].mp4', '孤獨搖滾![5][720P].ass']);
      expect(savedFiles().first['mimeType'], 'video/mp4');
      expect(find.textContaining('已匯出'), findsOneWidget);
    });

    testWidgets('turning danmaku off sends only the video', (tester) async {
      await tester.runAsync(() async {
        await seed([
          {'sn': '302', 'anime_name': '作品', 'episode': '1', 'hasDanmaku': true},
        ]);
        await boot();
      });
      await pumpLauncher(tester, only: '302');
      await tester.tap(find.text('附上彈幕字幕檔'));
      await tester.pump();
      await tester.tap(find.text('選擇儲存位置'));
      await tester.pumpAndSettle();
      expect(savedFiles().map((f) => f['name']), ['作品[1].mp4']);
    });

    testWidgets('picking several episodes groups them by series',
        (tester) async {
      await tester.runAsync(() async {
        await seed([
          {'sn': '401', 'anime_name': '甲', 'episode': '10', 'addedAt': 3},
          {'sn': '402', 'anime_name': '甲', 'episode': '2', 'addedAt': 2},
          {'sn': '403', 'anime_name': '乙', 'episode': '1', 'addedAt': 1},
        ]);
        await boot();
      });
      await pumpLauncher(tester);

      expect(find.text('選一些集數'), findsOneWidget);
      // 集數照數字排, 不是照字串 —— 第 2 集在第 10 集前面
      expect(tester.getTopLeft(find.text('第 2 集')).dy,
          lessThan(tester.getTopLeft(find.text('第 10 集')).dy));

      await tester.tap(find.text('甲'));
      await tester.pump();
      expect(find.textContaining('匯出 2 集'), findsOneWidget);

      await tester.tap(find.textContaining('匯出 2 集'));
      await tester.pumpAndSettle();
      expect(savedFiles().map((f) => f['name']), ['甲[2].mp4', '甲[10].mp4']);
      expect(find.text('已匯出 2 集。'), findsOneWidget);
    });

    testWidgets('copy progress shows a dialog that can stop the export',
        (tester) async {
      await tester.runAsync(() async {
        await seed([
          {'sn': '501', 'anime_name': '作品', 'episode': '1'},
        ]);
        await boot();
      });
      final finish = Completer<Object?>();
      onSave = (call) async {
        await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .handlePlatformMessage(
                FileExport.channel.name,
                FileExport.channel.codec.encodeMethodCall(
                    const MethodCall('progress', {'copied': 32, 'total': 64})),
                (_) {});
        return finish.future;
      };
      await pumpLauncher(tester, only: '501');
      await tester.tap(find.text('選擇儲存位置'));
      await tester.pumpAndSettle();

      expect(find.text('正在匯出…'), findsOneWidget);
      expect(find.textContaining('50%'), findsOneWidget);

      await tester.tap(find.text('取消'));
      await tester.pump();
      expect(calls.map((c) => c.method), contains('cancel'));
      expect(find.text('正在停止…'), findsOneWidget);

      finish.complete({'saved': 0, 'cancelled': true});
      await tester.pumpAndSettle();
      expect(find.text('正在匯出…'), findsNothing);
      expect(find.text('已取消匯出。'), findsOneWidget);
    });

    testWidgets('backing out of the system picker says nothing',
        (tester) async {
      await tester.runAsync(() async {
        await seed([
          {'sn': '601', 'anime_name': '作品', 'episode': '1'},
        ]);
        await boot();
      });
      onSave = (_) async => {'saved': 0, 'cancelled': true};
      await pumpLauncher(tester, only: '601');
      await tester.tap(find.text('選擇儲存位置'));
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsNothing);
    });

    group('on the downloads page', () {
      late AppState state;

      // 在 setUp 裡開機, 跟其它測試一樣: 測試環境沒有 connectivity 那個平台
      // 通道, 在測試本體裡開機的話那個錯會被算成這個測試失敗
      setUp(() async {
        await seed([
          {
            'sn': '801',
            'anime_name': '作品',
            'episode': '3',
            'resolution': 1080,
          },
        ]);
        SharedPreferences.setMockInitialValues({});
        state = await AppState.boot(
            client: AgpClient(
                baseUrl: 'http://example.test',
                httpClient: MockClient((_) async => http.Response('{}', 404))));
        state.offline = true;
        state.downloads.concurrency = 0;
        store = state.downloads;
      });

      tearDown(() {
        state.downloadNetwork.dispose();
        state.thumbnails.dispose();
        state.client.close();
      });

      testWidgets('finished episodes can be exported', (tester) async {
        await tester.pumpWidget(MaterialApp(home: DownloadsPage(state: state)));
        await tester.pump();
        expect(find.byTooltip('匯出影片檔'), findsOneWidget);

        await tester.tap(find.byTooltip('匯出'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        expect(find.text('作品[3][1080P].mp4'), findsOneWidget);
        // 沒抓到彈幕的集數不必問要不要附
        expect(find.text('附上彈幕字幕檔'), findsNothing);

        await tester.tap(find.text('選擇儲存位置'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        expect(savedFiles().map((f) => f['name']), ['作品[3][1080P].mp4']);
        await tester.pumpWidget(const SizedBox());
      });
    });

    testWidgets('a failed copy reports how far it got', (tester) async {
      await tester.runAsync(() async {
        await seed([
          {'sn': '701', 'anime_name': '作品', 'episode': '1'},
          {'sn': '702', 'anime_name': '作品', 'episode': '2'},
        ]);
        await boot();
      });
      onSave = (_) async => throw PlatformException(
          code: 'copy_failed',
          message: '空間不足',
          details: {'saved': 1, 'cancelled': false});
      await pumpLauncher(tester);
      await tester.tap(find.text('全選'));
      await tester.pump();
      await tester.tap(find.textContaining('匯出 2 集'));
      await tester.pumpAndSettle();
      expect(find.text('匯出失敗：空間不足（已存好 1 個檔案）'), findsOneWidget);
    });
  });
}
