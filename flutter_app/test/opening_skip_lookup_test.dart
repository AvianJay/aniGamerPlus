import 'dart:convert';

import 'package:agp_mobile/src/api/opening_skip.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const title = '轉生公主與天才千金的魔法革命';
  const original = '転生王女と天才令嬢の魔法革命';
  final subject = {
    'name': original,
    'name_cn': '转生公主与天才千金的魔法革命',
    'date': '2023-01-04',
  };
  const anilist = {
    'data': {
      'Page': {
        'media': [
          {
            'idMal': 52736,
            'title': {'native': original},
            'startDate': {'year': 2023}
          }
        ]
      }
    }
  };

  http.Response reply(Object data, [int status = 200]) =>
      http.Response.bytes(utf8.encode(jsonEncode(data)), status);

  test('episode 10 shows AniSkip at the screenshot position', () async {
    final requested = <Uri>[];
    final client = MockClient((request) async {
      requested.add(request.url);
      switch (request.url.host) {
        case 'api.bgm.tv':
          return reply({
            'data': [subject]
          });
        case 'graphql.anilist.co':
          return reply(anilist);
        case 'api.aniskip.com':
          return reply({
            'found': true,
            'results': [
              {
                'skipType': 'op',
                'episodeLength': 1420,
                'interval': {'startTime': 160.776, 'endTime': 250.776}
              }
            ]
          });
      }
      return reply({}, 404);
    });
    addTearDown(client.close);
    final lookup = OpeningSkipLookup(client);
    final interval = await lookup.find(
        title: title, seasonStart: '2023/01/04', episode: '10', duration: 1420);
    expect(interval, [160.776, 250.776]);
    expect(162 >= interval![0] - 3 && 162 < interval[1] - 5, isTrue);
    expect(requested.map((url) => url.host).toList(),
        ['api.bgm.tv', 'graphql.anilist.co', 'api.aniskip.com']);
    expect(requested.last.path, '/v2/skip-times/52736/10');
    expect(requested.last.queryParameters['episodeLength'], '1420');
    await lookup.find(
        title: title, seasonStart: '2023/01/04', episode: '10', duration: 1420);
    expect(requested.where((url) => url.host == 'api.bgm.tv').length, 1);
  });

  test('ambiguous or wrong season never queries AniSkip', () async {
    var calls = 0;
    final client = MockClient((request) async {
      calls++;
      return reply({
        'data': [
          subject,
          {...subject, 'name': 'another'}
        ]
      });
    });
    addTearDown(client.close);
    final lookup = OpeningSkipLookup(client);
    expect(
        await lookup.find(
            title: title,
            seasonStart: '2023/01/04',
            episode: '10',
            duration: 1420),
        isNull);
    expect(calls, 1);
    expect(
        await lookup.find(
            title: title,
            seasonStart: '2023/01/04',
            episode: '10.5',
            duration: 1420),
        isNull);
    expect(calls, 1);
  });

  test('rejects wrong episode length and end-of-episode intervals', () async {
    final client = MockClient((request) async {
      switch (request.url.host) {
        case 'api.bgm.tv':
          return reply({
            'data': [subject]
          });
        case 'graphql.anilist.co':
          return reply(anilist);
        case 'api.aniskip.com':
          return reply({
            'found': true,
            'results': [
              {
                'skipType': 'op',
                'episodeLength': 1420,
                'interval': {'startTime': 1335, 'endTime': 1420}
              },
              {
                'skipType': 'op',
                'episodeLength': 1800,
                'interval': {'startTime': 160, 'endTime': 250}
              },
            ]
          });
      }
      return reply({}, 404);
    });
    addTearDown(client.close);
    expect(
        await OpeningSkipLookup(client).find(
            title: title,
            seasonStart: '2023/01/04',
            episode: '10',
            duration: 1420),
        isNull);
  });

  test('a transient title lookup failure can retry', () async {
    var calls = 0;
    final client = MockClient((request) async {
      if (request.url.host == 'api.bgm.tv') {
        calls++;
        return calls == 1
            ? reply({}, 429)
            : reply({
                'data': [subject]
              });
      }
      if (request.url.host == 'graphql.anilist.co') return reply(anilist);
      return reply({'found': false});
    });
    addTearDown(client.close);
    final lookup = OpeningSkipLookup(client);
    await expectLater(
        lookup.find(
            title: title,
            seasonStart: '2023/01/04',
            episode: '10',
            duration: 1420),
        throwsStateError);
    expect(
        await lookup.find(
            title: title,
            seasonStart: '2023/01/04',
            episode: '10',
            duration: 1420),
        isNull);
    expect(calls, 2);
  });

  test('valid OP after a long cold open is retained', () async {
    final client = MockClient((request) async {
      if (request.url.host == 'api.bgm.tv') {
        return reply({
          'data': [subject]
        });
      }
      if (request.url.host == 'graphql.anilist.co') return reply(anilist);
      return reply({
        'found': true,
        'results': [
          {
            'skipType': 'op',
            'episodeLength': 1420,
            'interval': {'startTime': 570, 'endTime': 660},
          }
        ]
      });
    });
    addTearDown(client.close);
    expect(
        await OpeningSkipLookup(client).find(
            title: title,
            seasonStart: '2023/01/04',
            episode: '10',
            duration: 1420),
        [570, 660]);
  });

  const rezero = 'Re：從零開始的異世界生活 第四季';
  const native = 'Re:ゼロから始める異世界生活 4th season';
  final cours = [
    {
      'name': '$native 喪失編',
      'name_cn': 'Re：从零开始的异世界生活 第四季 丧失篇',
      'date': '2026-04-08',
      'eps': 11
    },
    {
      'name': '$native 奪還編',
      'name_cn': 'Re：从零开始的异世界生活 第四季 夺还篇',
      'date': '2026-08-12',
      'eps': 8
    },
  ];

  for (final episodes in [19, 11]) {
    test('split arcs require matching combined episode count ($episodes)',
        () async {
      final requested = <Uri>[];
      final client = MockClient((request) async {
        requested.add(request.url);
        if (request.url.host == 'api.bgm.tv') return reply({'data': cours});
        if (request.url.host == 'graphql.anilist.co') {
          final body = jsonDecode(request.body);
          return reply({
            'data': {
              'Page': {
                'media': body['variables']['s'] != native
                    ? []
                    : [
                        {
                          'idMal': 61316,
                          'episodes': episodes,
                          'title': {'native': native},
                          'startDate': {'year': 2026, 'month': 4, 'day': 8},
                        }
                      ],
              }
            }
          });
        }
        return reply({
          'found': true,
          'results': [
            {
              'skipType': 'op',
              'episodeLength': 1420,
              'interval': {'startTime': 500, 'endTime': 590},
            }
          ]
        });
      });
      addTearDown(client.close);
      final result = await OpeningSkipLookup(client).find(
          title: rezero,
          seasonStart: '2026/04/08',
          episode: '17',
          duration: 1420);
      if (episodes == 19) {
        expect(result, [500, 590]);
        expect(requested.last.path, '/v2/skip-times/61316/17');
      } else {
        expect(result, isNull);
        expect(
            requested.where((uri) => uri.host == 'api.aniskip.com'), isEmpty);
      }
    });
  }

  test('split arcs with no exact premiere date remain ambiguous', () async {
    var calls = 0;
    final client = MockClient((request) async {
      calls++;
      return reply({'data': cours});
    });
    addTearDown(client.close);
    expect(
        await OpeningSkipLookup(client).find(
            title: rezero, seasonStart: '2026', episode: '17', duration: 1420),
        isNull);
    expect(calls, 1);
  });

  test('missing OP records are not replaced with a guessed interval', () async {
    final client = MockClient((request) async {
      if (request.url.host == 'api.bgm.tv') {
        return reply({
          'data': [subject]
        });
      }
      if (request.url.host == 'graphql.anilist.co') return reply(anilist);
      return reply({'found': false}, 404);
    });
    addTearDown(client.close);
    expect(
        await OpeningSkipLookup(client).find(
            title: title,
            seasonStart: '2023/01/04',
            episode: '10',
            duration: 1420),
        isNull);
  });
}
