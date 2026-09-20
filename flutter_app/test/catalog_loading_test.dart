import 'dart:convert';

import 'package:agp_mobile/src/api/client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('cold catalogue retries before returning a page', () async {
    var calls = 0;
    final client = AgpClient(
      baseUrl: 'http://example.test',
      httpClient: MockClient((request) async {
        calls++;
        return http.Response(jsonEncode(calls == 1
            ? {'items': [], 'loading': true, 'retryAfter': 2}
            : {'items': [{'animeSn': '1', 'title': 'Ready'}], 'total': 1,
                'page': 1, 'pages': 1, 'loading': false}), 200);
      }),
    );
    addTearDown(client.close);
    final result = await client.catalogAll();
    expect(calls, 2);
    expect(result.items.single.title, 'Ready');
  });

  test('pending detail is not parsed as an empty series', () async {
    var calls = 0;
    final client = AgpClient(
      baseUrl: 'http://example.test',
      httpClient: MockClient((request) async {
        calls++;
        return http.Response(jsonEncode(calls == 1
            ? {'loading': true, 'retryAfter': 2}
            : {'animeSn': '1', 'title': 'Ready', 'groups': []}),
            calls == 1 ? 202 : 200);
      }),
    );
    addTearDown(client.close);
    expect((await client.catalogAnime('1')).title, 'Ready');
    expect(calls, 2);
  });

  test('failed catalogue does not masquerade as an empty result', () async {
    final client = AgpClient(
      baseUrl: 'http://example.test',
      httpClient: MockClient((request) async => http.Response(
          jsonEncode({'items': [], 'loading': false, 'retryAfter': 60}), 200)),
    );
    addTearDown(client.close);
    await expectLater(client.catalogAll(), throwsA(isA<ApiException>()));
  });
}
