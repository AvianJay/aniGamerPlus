import 'dart:convert';
import 'dart:io';

import 'package:agp_mobile/src/api/opening_skip.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  http.Response reply(Object value, [int status = 200]) =>
      http.Response.bytes(utf8.encode(jsonEncode(value)), status);
  Map fixture() => jsonDecode(
          File('../tests/fixtures/bocchi_anime_skip.json').readAsStringSync())
      as Map;
  final calls = <http.Request>[];
  MockClient makeClient(
          {bool anilistDown = false,
          int aniSkipStatus = 404,
          Map? animeSkip,
          Map? jikan,
          int animeSkipStatus = 200}) =>
      MockClient((request) async {
        calls.add(request);
        switch (request.url.host) {
          case 'api.bgm.tv':
            return reply({
              'data': [
                {'name': 'ぼっち・ざ・ろっく！', 'name_cn': '孤独摇滚！', 'date': '2022-10-08'}
              ]
            });
          case 'graphql.anilist.co':
            return reply({
              'data': {
                'Page': {
                  'media': [
                    {
                      'id': 130003,
                      'idMal': 47917,
                      'episodes': 12,
                      'title': {
                        'native': 'ぼっち・ざ・ろっく！',
                        'english': 'Bocchi the Rock!'
                      },
                      'startDate': {'year': 2022}
                    }
                  ]
                }
              }
            }, anilistDown ? 503 : 200);
          case 'api.jikan.moe':
            expect(request.url.queryParameters['q'], 'ぼっち・ざ・ろっく！');
            return reply(jikan ??
                {
                  'data': [
                    {
                      'mal_id': 47917,
                      'episodes': 12,
                      'title_japanese': 'ぼっち・ざ・ろっく！',
                      'title': 'Bocchi the Rock!',
                      'title_english': 'Bocchi the Rock!',
                      'aired': {'from': '2022-10-09T00:00:00+00:00'}
                    }
                  ]
                });
          case 'api.aniskip.com':
            expect(request.url.path, startsWith('/v2/skip-times/47917/'));
            return reply({
              'found': true,
              'results': [
                {
                  'skipType': 'op',
                  'episodeLength': 1420,
                  'interval': {'startTime': 115.96, 'endTime': 205.96}
                }
              ]
            }, aniSkipStatus);
          case 'api.anime-skip.com':
            expect(request.headers['X-Client-ID'], isNotEmpty);
            expect(
                jsonDecode(request.body)['variables'],
                anilistDown
                    ? {'search': 'Bocchi the Rock!'}
                    : {'id': '130003'});
            return reply(animeSkip ?? fixture(), animeSkipStatus);
        }
        throw StateError('Unexpected request ${request.url}');
      });
  Future<OpeningSkipResult?> find(OpeningSkipLookup lookup,
          {String episode = '3',
          double duration = 1420,
          bool fallback = true}) =>
      lookup.findWithSource(
          title: '孤獨搖滾！',
          seasonStart: '2022/10/09',
          episode: episode,
          duration: duration,
          animeSkipFallback: fallback);
  setUp(calls.clear);

  test('Jikan rescues an AniList outage without calling the timing fallback',
      () async {
    final client = makeClient(anilistDown: true, aniSkipStatus: 200);
    addTearDown(client.close);
    final result = await find(OpeningSkipLookup(client));
    expect(result?.source, 'AniSkip');
    expect(result?.interval, [115.96, 205.96]);
    expect(calls.where((r) => r.url.host == 'api.jikan.moe'), hasLength(1));
    expect(calls.where((r) => r.url.host == 'api.anime-skip.com'), isEmpty);
  });

  test('AnimeSkip fills Bocchi episodes 3, 4 and 10 and caches show metadata',
      () async {
    final client = makeClient();
    addTearDown(client.close);
    final lookup = OpeningSkipLookup(client);
    final three = await find(lookup);
    expect(three?.source, 'AnimeSkip');
    expect(three?.interval, [220.823737, 311.37238]);
    expect(
        (await find(lookup, episode: '4'))?.interval, [104.743621, 195.440381]);
    expect((await find(lookup, episode: '10'))?.interval,
        [146.930299, 237.500372]);
    expect(
        calls.where((r) => r.url.host == 'api.anime-skip.com'), hasLength(1));
    expect(calls.where((r) => r.url.host == 'api.jikan.moe'), isEmpty);
  });

  test('both providers can fall back in one request', () async {
    final client = makeClient(anilistDown: true, aniSkipStatus: 503);
    addTearDown(client.close);
    expect((await find(OpeningSkipLookup(client)))?.source, 'AnimeSkip');
  });

  test('AniSkip success keeps its priority', () async {
    final client = makeClient(aniSkipStatus: 200);
    addTearDown(client.close);
    expect((await find(OpeningSkipLookup(client)))?.source, 'AniSkip');
    expect(calls.map((r) => r.url.host),
        ['api.bgm.tv', 'graphql.anilist.co', 'api.aniskip.com']);
  });

  test('AniSkip only suppresses AnimeSkip without poisoning later requests',
      () async {
    final client = makeClient();
    addTearDown(client.close);
    final lookup = OpeningSkipLookup(client);
    expect(await find(lookup, fallback: false), isNull);
    expect(calls.where((r) => r.url.host == 'api.anime-skip.com'), isEmpty);
    expect((await find(lookup))?.source, 'AnimeSkip');
  });

  test('credits, missing intros, and a different streaming cut never seek',
      () async {
    final client = makeClient();
    addTearDown(client.close);
    final lookup = OpeningSkipLookup(client);
    expect(await find(lookup, episode: '8'), isNull);
    expect(await find(lookup, episode: '12'), isNull);
    expect(await find(lookup, duration: 1440), isNull);
    expect(await find(lookup, episode: '13'), isNull);
  });

  for (final scenario in [
    'conflicting copies',
    'multiple seasons',
    'mixed intro'
  ]) {
    test('AnimeSkip rejects $scenario', () async {
      final data = fixture();
      final episodes = data['data']['shows'][0]['episodes'] as List;
      if (scenario == 'multiple seasons') {
        episodes.first['season'] = '2';
      } else {
        for (final row in episodes.where((r) => r['number'] == '3')) {
          if (scenario == 'mixed intro') {
            for (final stamp in row['timestamps']) {
              if (stamp['type']['name'] == 'Intro') {
                stamp['type']['name'] = 'Mixed Intro';
              }
            }
          } else {
            row['timestamps'][2]['at'] = 400;
            break;
          }
        }
      }
      final client = makeClient(animeSkip: data);
      addTearDown(client.close);
      expect(await find(OpeningSkipLookup(client)), isNull);
    });
  }

  test('Jikan requires a unique original title and matching premiere year',
      () async {
    for (final rows in [
      [
        {
          'mal_id': 47917,
          'title_japanese': 'another anime',
          'aired': {'from': '2022-10-09'}
        }
      ],
      [
        {
          'mal_id': 47917,
          'title_japanese': 'ぼっち・ざ・ろっく！',
          'aired': {'from': '2025-10-09'}
        }
      ],
      List.filled(2, {
        'mal_id': 47917,
        'title_japanese': 'ぼっち・ざ・ろっく！',
        'aired': {'from': '2022-10-09'}
      }),
    ]) {
      final client = makeClient(anilistDown: true, jikan: {'data': rows});
      addTearDown(client.close);
      expect(await find(OpeningSkipLookup(client)), isNull);
    }
    expect(calls.where((r) => r.url.host == 'api.aniskip.com'), isEmpty);
  });

  test('AnimeSkip outage is retried instead of cached as missing data',
      () async {
    var attempts = 0;
    final base = makeClient();
    final client = MockClient((request) async {
      if (request.url.host == 'api.anime-skip.com' && attempts++ == 0) {
        return reply({}, 503);
      }
      final copy = http.Request(request.method, request.url)
        ..headers.addAll(request.headers)
        ..bodyBytes = request.bodyBytes;
      return base.send(copy).then(http.Response.fromStream);
    });
    addTearDown(() {
      client.close();
      base.close();
    });
    final lookup = OpeningSkipLookup(client);
    await expectLater(find(lookup), throwsStateError);
    expect((await find(lookup))?.source, 'AnimeSkip');
  });
}
