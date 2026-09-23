import 'dart:convert';

import 'package:agp_mobile/src/state/updater.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

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
}
