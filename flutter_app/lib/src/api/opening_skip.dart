/// Resolve a Bahamut series to a MAL ID on the client, then ask AniSkip for OP.
/// Unknown or ambiguous titles are deliberately left to the danmaku fallback.
library;

import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

class OpeningSkipLookup {
  OpeningSkipLookup(this._http);

  final http.Client _http;
  final Map<String, Future<int?>> _malIds = {};
  static Future<Map<String, String>>? _characters;

  static Future<Map<String, String>> get _t2s => _characters ??= rootBundle
      .loadString('assets/opening_t2s.json')
      .then((value) => Map<String, String>.from(jsonDecode(value) as Map));

  Future<List<double>?> find({
    required String title,
    required String seasonStart,
    required String episode,
    required double duration,
  }) async {
    final number = parseEpisodeNumber(episode);
    if (title.trim().isEmpty ||
        number == null ||
        !duration.isFinite ||
        duration < 600 ||
        duration > 7200) {
      return null;
    }
    final key = '$title\u0000$seasonStart';
    final malId = await (_malIds[key] ??= _resolveMalId(title, seasonStart));
    if (malId == null) return null;

    final uri = Uri.https('api.aniskip.com', '/v2/skip-times/$malId/$number', {
      'types': 'op',
      'episodeLength': duration.round().toString(),
    });
    final response = await _http.get(uri).timeout(const Duration(seconds: 8));
    if (response.statusCode == 404) return null;
    _check(response);
    final payload = jsonDecode(utf8.decode(response.bodyBytes));
    if (payload is! Map ||
        payload['found'] != true ||
        payload['results'] is! List) {
      return null;
    }
    List<double>? best;
    for (final row in payload['results'] as List) {
      if (row is! Map || row['skipType'] != 'op' || row['interval'] is! Map) {
        continue;
      }
      final interval = row['interval'] as Map;
      final start = _number(interval['startTime']);
      final end = _number(interval['endTime']);
      final length = _number(row['episodeLength']) ?? duration;
      if (start == null ||
          end == null ||
          !start.isFinite ||
          !end.isFinite ||
          !length.isFinite ||
          start < 0 ||
          end <= start ||
          end > math.min(420, duration * .4) ||
          end - start < 40 ||
          end - start > 210 ||
          end > duration - 300 ||
          (length - duration).abs() > math.max(60, duration * .1)) {
        continue;
      }
      if (best == null || end - start > best[1] - best[0]) {
        best = [start, end];
      }
    }
    return best;
  }

  Future<int?> _resolveMalId(String title, String seasonStart) async {
    try {
      final characters = await _t2s;
      final search = await _http
          .post(
            Uri.https('api.bgm.tv', '/v0/search/subjects'),
            headers: {
              'Content-Type': 'application/json',
              'User-Agent': 'aniGamerPlus/1.0 (opening skip)',
            },
            body: jsonEncode({
              'keyword': title,
              'filter': {
                'type': [2]
              },
              'limit': 20
            }),
          )
          .timeout(const Duration(seconds: 8));
      _check(search);
      final payload = jsonDecode(utf8.decode(search.bodyBytes));
      final rows = payload is Map ? payload['data'] : null;
      if (rows is! List) return null;
      final scored = <(double, Map)>[];
      for (final row in rows) {
        if (row is Map) scored.add((subjectScore(title, row, characters), row));
      }
      scored.sort((a, b) => b.$1.compareTo(a.$1));
      if (scored.isEmpty ||
          scored.first.$1 < .84 ||
          (scored.length > 1 && scored.first.$1 - scored[1].$1 < .06)) {
        return null;
      }
      final subject = scored.first.$2;
      final original = (subject['name'] ?? '').toString();
      if (original.isEmpty) return null;
      final year = _year(subject['date']);
      final requestedYear = _year(seasonStart);
      if (year != null && requestedYear != null && year != requestedYear) {
        return null;
      }

      final anilist = await _http
          .post(
            Uri.https('graphql.anilist.co', '/'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'query':
                  'query(\$s:String){Page(perPage:10){media(search:\$s,type:ANIME){idMal title{native} startDate{year}}}}',
              'variables': {'s': original},
            }),
          )
          .timeout(const Duration(seconds: 8));
      _check(anilist);
      final data = jsonDecode(utf8.decode(anilist.bodyBytes));
      final media = data is Map &&
              data['data'] is Map &&
              (data['data'] as Map)['Page'] is Map
          ? ((data['data'] as Map)['Page'] as Map)['media']
          : null;
      if (media is! List) return null;
      final matches = media.where((row) {
        if (row is! Map || row['idMal'] is! int || (row['idMal'] as int) <= 0) {
          return false;
        }
        final native =
            row['title'] is Map ? (row['title'] as Map)['native'] : null;
        final startYear = row['startDate'] is Map
            ? (row['startDate'] as Map)['year']?.toString()
            : null;
        return _plain(native, characters) == _plain(original, characters) &&
            (year == null || startYear == year);
      }).toList();
      return matches.length == 1
          ? (matches.single as Map)['idMal'] as int
          : null;
    } catch (_) {
      // A temporary API failure must be retried on the next request.
      _malIds.remove('$title\u0000$seasonStart');
      rethrow;
    }
  }

  static void _check(http.Response response) {
    if (response.statusCode >= 400) {
      throw StateError('Opening skip API returned ${response.statusCode}');
    }
  }
}

int? parseEpisodeNumber(String value) {
  final match =
      RegExp(r'^\s*(?:第\s*)?(\d{1,3})(?:\s*集)?\s*$').firstMatch(value);
  final number = match == null ? null : int.tryParse(match.group(1)!);
  return number != null && number >= 1 && number <= 999 ? number : null;
}

double subjectScore(String title, Map subject,
    [Map<String, String> characters = const {}]) {
  final candidates = <String>[
    (subject['name_cn'] ?? '').toString(),
    (subject['name'] ?? '').toString(),
  ];
  final infobox = subject['infobox'];
  if (infobox is List) {
    for (final item in infobox) {
      if (item is! Map || !['别名', '別名', '中文名'].contains(item['key'])) {
        continue;
      }
      final value = item['value'];
      if (value is List) {
        for (final alias in value) {
          if (alias is Map && alias['v'] != null) {
            candidates.add(alias['v'].toString());
          }
        }
      } else if (value != null) {
        candidates.add(value.toString());
      }
    }
  }
  final wantedSeason = _season(title);
  final left = _plain(title.replaceAll(_seasonPattern, ''), characters);
  if (left.isEmpty) return 0;
  var best = 0.0;
  for (final candidate in candidates) {
    if (_season(candidate) != wantedSeason) continue;
    final right = _plain(candidate.replaceAll(_seasonPattern, ''), characters);
    if (right.isNotEmpty) best = math.max(best, _similarity(left, right));
  }
  return best;
}

final _seasonPattern = RegExp(r'第\s*([一二三四五六七八九十\d]+)\s*季');

String _season(String title) {
  final raw = _seasonPattern.firstMatch(title)?.group(1) ?? '';
  const numbers = {
    '一': '1',
    '二': '2',
    '三': '3',
    '四': '4',
    '五': '5',
    '六': '6',
    '七': '7',
    '八': '8',
    '九': '9',
    '十': '10'
  };
  return numbers[raw] ?? raw;
}

String _plain(Object? value, Map<String, String> characters) {
  final normalized = (value ?? '')
      .toString()
      .toLowerCase()
      .replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), '');
  return String.fromCharCodes(normalized.runes.map((rune) {
    final mapped = characters[String.fromCharCode(rune)];
    return mapped == null ? rune : mapped.runes.first;
  }));
}

String? _year(Object? value) {
  final match = RegExp(r'^\s*(\d{4})').firstMatch((value ?? '').toString());
  return match?.group(1);
}

double? _number(Object? value) =>
    value is num ? value.toDouble() : double.tryParse((value ?? '').toString());

double _similarity(String a, String b) {
  if (a == b) return 1;
  final left = a.runes.toList();
  final right = b.runes.toList();
  if (left.isEmpty || right.isEmpty) return 0;
  var previous = List<int>.generate(right.length + 1, (i) => i);
  for (var i = 1; i <= left.length; i++) {
    final next = List<int>.filled(right.length + 1, 0)..[0] = i;
    for (var j = 1; j <= right.length; j++) {
      next[j] = math.min(
          next[j - 1] + 1,
          math.min(previous[j] + 1,
              previous[j - 1] + (left[i - 1] == right[j - 1] ? 0 : 1)));
    }
    previous = next;
  }
  return 1 - previous.last / math.max(left.length, right.length);
}
