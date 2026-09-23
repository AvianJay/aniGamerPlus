import 'dart:convert';
import 'dart:io';

import 'package:agp_mobile/src/state/updater.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'support/temp_dir.dart';

class Paths extends PathProviderPlatform {
  Paths(this.path);
  final String path;
  @override
  Future<String?> getTemporaryPath() async => path;
}

/// 回 [body] 的 APK 下載, 可以謊報 Content-Length 來模擬斷在半路
Updater _apkServer(List<int> body, {int? contentLength}) => Updater(
      httpClient: MockClient.streaming((request, _) async =>
          http.StreamedResponse(Stream.value(body), 200,
              contentLength: contentLength ?? body.length)),
    );

UpdateInfo _apk({int size = 0, String sha = ''}) => UpdateInfo(
      channel: UpdateChannel.nightly,
      version: '1.0.0',
      build: 9,
      url: 'http://dl.test/a.apk',
      size: size,
      sha256: sha,
    );

Updater _updater(Map<String, Object> routes) => Updater(
      apiBase: 'http://api.test',
      downloadBase: 'http://dl.test',
      httpClient: MockClient((request) async {
        final body = routes[request.url.toString()];
        if (body == null) return http.Response('', 404);
        return http.Response(jsonEncode(body), 200);
      }),
    );

const _release = {
  'tag_name': 'v25.3',
  'body': 'notes',
  'assets': [
    {
      'name': 'aniGamerPlus_v25.3_windows_64bit.zip',
      'browser_download_url': 'http://dl.test/v25.3/win.zip',
    },
    {
      'name': 'aniGamerPlus-1.2.0-140.apk',
      'browser_download_url': 'http://dl.test/v25.3/app.apk',
    },
    {
      'name': 'aniGamerPlus-flutter-1.2.0-140-unsigned.ipa',
      'browser_download_url': 'http://dl.test/v25.3/app.ipa',
    },
  ],
};

const _nightly = {
  'version': '1.2.0',
  'build': 152,
  'commit': 'abcdef1234',
  'date': '2026-09-23T00:00:00Z',
  'apk': 'aniGamerPlus-nightly.apk',
  'ipa': 'aniGamerPlus-nightly-unsigned.ipa',
};

void main() {
  test('stable picks the asset for this platform and reads its build',
      () async {
    final updater = _updater({'http://api.test/releases/latest': _release});
    addTearDown(updater.close);

    final apk = await updater.latest(UpdateChannel.stable, ios: false);
    expect(apk!.build, 140);
    expect(apk.version, '1.2.0');
    expect(apk.url, 'http://dl.test/v25.3/app.apk');
    expect(apk.notes, 'notes');

    final ipa = await updater.latest(UpdateChannel.stable, ios: true);
    expect(ipa!.url, 'http://dl.test/v25.3/app.ipa');
    expect(ipa.build, 140);
  });

  test('stable release without app files has nothing to offer', () async {
    final updater = _updater({
      'http://api.test/releases/latest': {'tag_name': 'v25.3', 'assets': []},
    });
    addTearDown(updater.close);
    expect(await updater.latest(UpdateChannel.stable, ios: false), isNull);
  });

  test('nightly reads the manifest and builds fixed download urls', () async {
    final updater =
        _updater({'http://dl.test/nightly/flutter-nightly.json': _nightly});
    addTearDown(updater.close);

    final apk = await updater.latest(UpdateChannel.nightly, ios: false);
    expect(apk!.build, 152);
    expect(apk.url, 'http://dl.test/nightly/aniGamerPlus-nightly.apk');
    expect(apk.commit, 'abcdef1234');

    final ipa = await updater.latest(UpdateChannel.nightly, ios: true);
    expect(
        ipa!.url, 'http://dl.test/nightly/aniGamerPlus-nightly-unsigned.ipa');
  });

  test('check only reports builds newer than the running one', () async {
    final updater =
        _updater({'http://dl.test/nightly/flutter-nightly.json': _nightly});
    addTearDown(updater.close);

    expect(
        await updater.check(UpdateChannel.nightly,
            ios: false, currentBuild: 152),
        isNull);
    expect(
        (await updater.check(UpdateChannel.nightly,
                ios: false, currentBuild: 151))!
            .build,
        152);
  });

  test('a missing release is an error, not "up to date"', () async {
    final updater = _updater({});
    addTearDown(updater.close);
    await expectLater(updater.latest(UpdateChannel.nightly, ios: false),
        throwsA(isA<UpdateException>()));
  });

  test('sideload stores get the ipa url percent-encoded', () {
    expect(
      IosInstaller.trollStore.installUri('https://x.test/a b.ipa').toString(),
      'apple-magnifier://install?url=https%3A%2F%2Fx.test%2Fa%20b.ipa',
    );
    expect(IosInstaller.parse('sidestore'), IosInstaller.sideStore);
    expect(IosInstaller.parse('bogus'), IosInstaller.auto);
    expect(UpdateChannel.parse('nightly'), UpdateChannel.nightly);
  });

  group('downloadApk', () {
    late Directory temp;
    final body = List<int>.generate(4096, (i) => i % 251);
    final sha = sha256.convert(body).toString();

    setUp(() {
      temp = Directory.systemTemp.createTempSync('agp-update-');
      PathProviderPlatform.instance = Paths(temp.path);
    });
    tearDown(() => deleteTempDir(temp));

    test('keeps a complete file whose hash matches', () async {
      final updater = _apkServer(body);
      addTearDown(updater.close);
      final file = await updater.downloadApk(_apk(size: body.length, sha: sha));
      expect(await file.readAsBytes(), body);
    });

    test('rejects a stream that ends before Content-Length', () async {
      final updater =
          _apkServer(body.sublist(0, 1000), contentLength: body.length);
      addTearDown(updater.close);
      await expectLater(
          updater.downloadApk(_apk()), throwsA(isA<UpdateException>()));
      expect(temp.listSync(), isEmpty);
    });

    test('rejects a file shorter than the published size', () async {
      final short = body.sublist(0, 1000);
      final updater = _apkServer(short);
      addTearDown(updater.close);
      await expectLater(updater.downloadApk(_apk(size: body.length)),
          throwsA(isA<UpdateException>()));
      expect(temp.listSync(), isEmpty);
    });

    test('rejects a file whose hash does not match', () async {
      final corrupt = [...body]..[10] ^= 0xff;
      final updater = _apkServer(corrupt);
      addTearDown(updater.close);
      await expectLater(updater.downloadApk(_apk(size: body.length, sha: sha)),
          throwsA(isA<UpdateException>()));
      expect(temp.listSync(), isEmpty);
    });
  });

  test('nightly manifest and GitHub digests feed size and hash', () async {
    final hex = 'ab' * 32;
    final updater = _updater({
      'http://dl.test/nightly/flutter-nightly.json': {
        ..._nightly,
        'apk_size': 123,
        'apk_sha256': hex,
      },
      'http://api.test/releases/latest': {
        'assets': [
          {
            'name': 'aniGamerPlus-1.2.0-140.apk',
            'browser_download_url': 'http://dl.test/app.apk',
            'size': 456,
            'digest': 'sha256:${hex.toUpperCase()}',
          },
        ],
      },
    });
    addTearDown(updater.close);
    final nightly = await updater.latest(UpdateChannel.nightly, ios: false);
    expect(nightly!.size, 123);
    expect(nightly.sha256, hex);
    final stable = await updater.latest(UpdateChannel.stable, ios: false);
    expect(stable!.size, 456);
    expect(stable.sha256, hex);
  });
}
