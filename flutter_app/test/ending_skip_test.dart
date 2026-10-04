import 'dart:convert';

import 'package:agp_mobile/src/api/opening_skip.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Future<EndingSkipResult?> find(
      {List<Map>? aniSkip,
      List<Map>? stamps,
      double length = 1420,
      double duration = 1420}) async {
    http.Response reply(Object data, [int status = 200]) =>
        http.Response.bytes(utf8.encode(jsonEncode(data)), status);
    final client = MockClient((request) async {
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
                    'title': {'native': 'ぼっち・ざ・ろっく！'},
                    'startDate': {'year': 2022}
                  }
                ]
              }
            }
          });
        case 'api.aniskip.com':
          expect(request.url.queryParameters['types'], 'ed');
          return reply({'found': aniSkip != null, 'results': aniSkip ?? []});
        case 'api.anime-skip.com':
          return reply({
            'data': {
              'shows': [
                {
                  'episodes': [
                    {
                      'number': '6',
                      'baseDuration': length,
                      'timestamps': stamps ?? []
                    }
                  ]
                }
              ]
            }
          });
      }
      return reply({}, 404);
    });
    addTearDown(client.close);
    return OpeningSkipLookup(client).findEnding(
        title: '孤獨搖滾！',
        seasonStart: '2022/10/09',
        episode: '6',
        duration: duration);
  }

  Map row(double start, double end, [double length = 1420]) => {
        'skipType': 'ed',
        'episodeLength': length,
        'interval': {'startTime': start, 'endTime': end}
      };
  Map stamp(double at, String name) => {
        'at': at,
        'type': {'name': name}
      };

  test('AniSkip terminal ED is safe, ED with 30 seconds after it is not',
      () async {
    expect((await find(aniSkip: [row(1330, 1420)]))?.coversEnd(1420), isTrue);
    expect((await find(aniSkip: [row(1300, 1390)]))?.coversEnd(1420), isFalse);
  });
  test('wrong cut and conflicting ED submissions never offer early auto-next',
      () async {
    expect(await find(aniSkip: [row(1330, 1420, 1460)]), isNull);
    expect(await find(aniSkip: [row(1330, 1420), row(1300, 1390)]), isNull);
  });
  test('AnimeSkip terminal credits fill missing AniSkip endings', () async {
    final result =
        await find(stamps: [stamp(0, 'Canon'), stamp(1330, 'Credits')]);
    expect(result?.source, 'AnimeSkip');
    expect(result?.coversEnd(1420), isTrue);
  });
  for (final tail in ['Canon', 'Preview', 'Unknown']) {
    test('AnimeSkip preserves $tail after credits', () async {
      final result = await find(stamps: [
        stamp(0, 'Canon'),
        stamp(1300, 'Credits'),
        stamp(1390, tail)
      ]);
      expect(result?.coversEnd(1420), isFalse);
    });
  }
  test('mixed credits and duration mismatch remain unclassified', () async {
    expect(await find(stamps: [stamp(1300, 'Mixed Credits')]), isNull);
    final cut = await find(stamps: [stamp(1330, 'Credits')], duration: 1425);
    expect(cut?.coversEnd(1425), isFalse);
  });
  test('malformed tail cannot be filtered into safe terminal credits',
      () async {
    expect(
        await find(stamps: [
          stamp(1330, 'Credits'),
          {
            'at': 'broken',
            'type': {'name': 'Canon'}
          }
        ]),
        isNull);
  });
  test(
      'consecutive credits and an end marker do not invent post-credit content',
      () async {
    final result = await find(stamps: [
      stamp(1330, 'Credits'),
      stamp(1380, 'New Credits'),
      stamp(1420, 'Canon')
    ]);
    expect(result?.coversEnd(1420), isTrue);
  });
}
