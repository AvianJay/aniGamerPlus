/// Resolve a Bahamut series, then ask AniSkip with AnimeSkip as a fallback.
/// Unknown or ambiguous titles are deliberately left to the danmaku fallback.
library;

import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

class OpeningSkipResult {
  const OpeningSkipResult(this.start, this.end, this.source);
  final double start;
  final double end;
  final String source;
  List<double> get interval => [start, end];
}

class EndingSkipResult {
  const EndingSkipResult(this.start, this.end, this.source,
      {required this.terminal});
  final double start, end;
  final String source;

  /// Only plain credits covering the end of this cut may offer auto-next.
  /// A following canon/preview/unknown section is never skipped.
  final bool terminal;
  bool coversEnd(double duration) => terminal && (end - duration).abs() <= 1;
}

class OpeningSkipLookup {
  OpeningSkipLookup(this._http);

  final http.Client _http;
  final Map<String, Future<(int, int?, Map)?>> _malIds = {};
  final Map<String, Future<List>> _animeShows = {};
  static Map<String, String>? _characters;
  static Future<Map<String, String>>? _loadingCharacters;

  static Future<Map<String, String>> get _t2s async {
    if (_characters != null) return _characters!;
    try {
      return _characters = await (_loadingCharacters ??= rootBundle
          .loadString('assets/opening_t2s.json')
          .then((value) => Map<String, String>.from(jsonDecode(value) as Map)));
    } finally {
      _loadingCharacters = null;
    }
  }

  Future<List<double>?> find({
    required String title,
    required String seasonStart,
    required String episode,
    required double duration,
  }) async =>
      (await findWithSource(
              title: title,
              seasonStart: seasonStart,
              episode: episode,
              duration: duration))
          ?.interval;

  Future<OpeningSkipResult?> findWithSource({
    required String title,
    required String seasonStart,
    required String episode,
    required double duration,
    bool animeSkipFallback = true,
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
    final series = await (_malIds[key] ??= _resolveMalId(title, seasonStart));
    if (series == null || (series.$2 != null && number > series.$2!)) {
      return null;
    }

    Object? failure;
    try {
      final interval = await _aniSkip(series.$1, number, duration);
      if (interval != null) {
        return OpeningSkipResult(interval[0], interval[1], 'AniSkip');
      }
    } catch (error) {
      failure = error;
    }
    if (!animeSkipFallback) {
      if (failure != null) throw failure;
      return null;
    }
    try {
      final interval = await _animeSkip(series.$3, number, duration);
      if (interval != null) {
        return OpeningSkipResult(interval[0], interval[1], 'AnimeSkip');
      }
    } catch (error) {
      failure ??= error;
    }
    if (failure != null) throw failure;
    return null;
  }

  Future<List<double>?> _aniSkip(int malId, int number, double duration) async {
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

  Future<EndingSkipResult?> findEnding({
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
    final series = await (_malIds[key] ??= _resolveMalId(title, seasonStart));
    if (series == null || (series.$2 != null && number > series.$2!)) {
      return null;
    }
    Object? failure;
    try {
      final uri =
          Uri.https('api.aniskip.com', '/v2/skip-times/${series.$1}/$number', {
        'types': 'ed',
        'episodeLength': duration.round().toString(),
      });
      final response = await _http.get(uri).timeout(const Duration(seconds: 8));
      if (response.statusCode != 404) {
        _check(response);
        final payload = jsonDecode(utf8.decode(response.bodyBytes));
        final rows = payload is Map && payload['found'] == true
            ? payload['results']
            : null;
        final valid = <EndingSkipResult>[];
        if (rows is List) {
          for (final row in rows.whereType<Map>()) {
            if (row['skipType'] != 'ed' || row['interval'] is! Map) continue;
            final start = _number(row['interval']['startTime']);
            final end = _number(row['interval']['endTime']);
            final length = _number(row['episodeLength']);
            if (_validEnding(start, end, length, duration)) {
              valid.add(
                  EndingSkipResult(start!, end!, 'AniSkip', terminal: true));
            }
          }
        }
        if (valid.isNotEmpty) return _agreeEnding(valid);
      }
    } catch (error) {
      failure = error;
    }
    try {
      final result = await _animeSkipEnding(series.$3, number, duration);
      if (result != null) return result;
    } catch (error) {
      failure ??= error;
    }
    if (failure != null) throw failure;
    return null;
  }

  static bool _validEnding(
          double? start, double? end, double? length, double duration) =>
      start != null &&
      end != null &&
      length != null &&
      start.isFinite &&
      end.isFinite &&
      length.isFinite &&
      (length - duration).abs() <= 5 &&
      start >= duration * .6 &&
      end > start &&
      end - start >= 20 &&
      end - start <= 240 &&
      end <= duration + 1;

  static EndingSkipResult? _agreeEnding(List<EndingSkipResult> results) {
    if (results.any((a) => results.any((b) =>
        (a.start - b.start).abs() > 3 ||
        (a.end - b.end).abs() > 1 ||
        a.terminal != b.terminal))) {
      return null;
    }
    results.sort((a, b) => a.end.compareTo(b.end));
    return results.first;
  }

  Future<(int, int?, Map)?> _resolveMalId(
      String title, String seasonStart) async {
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
              'keyword': title.runes.map((rune) {
                final ch = String.fromCharCode(rune);
                return characters[ch] ?? ch;
              }).join(),
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
      final requestedYear = _year(seasonStart);
      for (final row in rows) {
        if (row is! Map) continue;
        final year = _year(row['date']);
        if (year != null && requestedYear != null && year != requestedYear) {
          continue;
        }
        scored.add((subjectScore(title, row, characters), row));
      }
      scored.sort((a, b) => b.$1.compareTo(a.$1));
      if (scored.isEmpty || scored.first.$1 < .84) {
        return null;
      }
      final contenders = scored
          .where((row) => row.$1 >= .84 && scored.first.$1 - row.$1 < .06)
          .toList();
      final requestedDate = _date(seasonStart);
      final dated = contenders.where((row) =>
          requestedDate != null && _date(row.$2['date']) == requestedDate);
      // Same-year split cours need the full premiere date to disambiguate.
      if (contenders.length > 1 && dated.length != 1) return null;
      final subject =
          contenders.length == 1 ? contenders.single.$2 : dated.single.$2;
      final original = (subject['name'] ?? '').toString();
      if (original.isEmpty) return null;
      final year = _year(subject['date']);
      final media = await _media(original, year, characters);
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
      if (matches.length == 1) {
        final row = matches.single as Map;
        final episodes = row['episodes'] is int ? row['episodes'] as int : null;
        return (row['idMal'] as int, episodes, row);
      }
      if (matches.isNotEmpty) return null;

      // Some databases split a season into arcs while MAL keeps all episodes
      // together. Only merge with a shared native title, distinct premiere
      // dates, and a verified total episode count; never guess a cour offset.
      final merged = _mergedSeason(contenders, requestedDate);
      if (merged == null) return null;
      final combined = await _media(merged.$1, _year(seasonStart), characters);
      final fullSeason = combined.where((row) {
        if (row is! Map ||
            row['idMal'] is! int ||
            row['idMal'] <= 0 ||
            row['episodes'] != merged.$2 ||
            row['startDate'] is! Map) {
          return false;
        }
        final start = row['startDate'] as Map;
        final date =
            _date('${start['year']}-${start['month']}-${start['day']}');
        final native = row['title'] is Map ? row['title']['native'] : null;
        return date == requestedDate &&
            _plain(native, characters) == _plain(merged.$1, characters);
      }).toList();
      return fullSeason.length == 1
          ? (
              (fullSeason.single as Map)['idMal'] as int,
              merged.$2,
              fullSeason.single as Map
            )
          : null;
    } catch (_) {
      // A temporary API failure must be retried on the next request.
      _malIds.remove('$title\u0000$seasonStart');
      rethrow;
    }
  }

  Future<List> _anilistMedia(String original) async {
    final response = await _http
        .post(
          Uri.https('graphql.anilist.co', '/'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'query':
                'query(\$s:String){Page(perPage:10){media(search:\$s,type:ANIME){id idMal episodes title{native romaji english} startDate{year month day}}}}',
            'variables': {'s': original},
          }),
        )
        .timeout(const Duration(seconds: 8));
    _check(response);
    final data = jsonDecode(utf8.decode(response.bodyBytes));
    final media =
        data is Map && data['data'] is Map && data['data']['Page'] is Map
            ? data['data']['Page']['media']
            : null;
    return media is List ? media : const [];
  }

  Future<List> _media(
      String original, String? year, Map<String, String> chars) async {
    Object? failure;
    try {
      final rows = await _anilistMedia(original);
      if (rows.any((row) =>
          row is Map &&
          row['idMal'] is int &&
          row['idMal'] > 0 &&
          _plain(row['title'] is Map ? row['title']['native'] : null, chars) ==
              _plain(original, chars) &&
          (year == null || '${(row['startDate'] as Map?)?['year']}' == year))) {
        return rows;
      }
    } catch (error) {
      failure = error;
    }
    try {
      final response = await _http
          .get(Uri.https(
              'api.jikan.moe', '/v4/anime', {'q': original, 'limit': '25'}))
          .timeout(const Duration(seconds: 8));
      _check(response);
      final payload = jsonDecode(utf8.decode(response.bodyBytes));
      final data = payload is Map ? payload['data'] : null;
      if (data is! List) return const [];
      final rows = data.whereType<Map>().map((row) {
        final aired = row['aired'] is Map ? row['aired']['from'] : null;
        final date = aired is String ? DateTime.tryParse(aired) : null;
        return {
          'idMal': row['mal_id'],
          'episodes': row['episodes'],
          'title': {
            'native': row['title_japanese'],
            'romaji': row['title'],
            'english': row['title_english']
          },
          'startDate': {
            'year': date?.year,
            'month': date?.month,
            'day': date?.day
          }
        };
      }).toList();
      if (rows.isEmpty && failure != null) throw failure;
      return rows;
    } catch (error) {
      throw failure ?? error;
    }
  }

  Future<List<Map>> _animeEpisodeRows(
      Map media, int number, double duration) async {
    final chars = await _t2s;
    final titles = media['title'] is Map ? media['title'] as Map : const {};
    final rawId = media['id'];
    final id = rawId is int && rawId > 0 ? rawId : null;
    final search =
        (titles['english'] ?? titles['romaji'] ?? titles['native'] ?? '')
            .toString();
    if (id is! int && search.isEmpty) return const [];
    final key = id is int ? 'id:$id' : 'title:$search';
    List shows;
    try {
      shows = await (_animeShows[key] ??=
          _fetchAnimeShows(id is int ? id : null, search));
    } catch (_) {
      _animeShows.remove(key);
      rethrow;
    }
    if (id is! int) {
      final names = titles.values
          .map((name) => _plain(name, chars))
          .where((name) => name.isNotEmpty)
          .toSet();
      shows = shows
          .where((row) =>
              row is Map &&
              (names.contains(_plain(row['name'], chars)) ||
                  names.contains(_plain(row['originalName'], chars))))
          .toList();
    }
    if (shows.length != 1 || shows.single is! Map) return const [];
    final episodes = shows.single['episodes'];
    if (episodes is! List) return const [];
    final seasons = episodes
        .whereType<Map>()
        .map((row) => (row['season'] ?? '1').toString().trim())
        .toSet();
    // A show containing several seasons has no reliable per-MAL season mapping.
    if (seasons.length != 1 || int.tryParse(seasons.single) == null) {
      return const [];
    }
    return episodes.whereType<Map>().where((row) {
      final length = _number(row['baseDuration']);
      return parseEpisodeNumber('${row['number']}') == number &&
          length != null &&
          length.isFinite &&
          (length - duration).abs() <= 5;
    }).toList();
  }

  static List<Map> _stamps(Map row) {
    final raw = row['timestamps'];
    final length = _number(row['baseDuration']);
    if (raw is! List || length == null) return const [];
    return raw.whereType<Map>().where((stamp) {
      final at = _number(stamp['at']);
      return at != null && at.isFinite && at >= 0 && at <= length;
    }).toList()
      ..sort((a, b) => _number(a['at'])!.compareTo(_number(b['at'])!));
  }

  Future<EndingSkipResult?> _animeSkipEnding(
      Map media, int number, double duration) async {
    final episodes = await _animeEpisodeRows(media, number, duration);
    final valid = <EndingSkipResult>[];
    for (final row in episodes) {
      final length = _number(row['baseDuration'])!;
      final stamps = _stamps(row);
      // Filtering malformed timestamps must never turn an unknown tail into
      // terminal credits. End-of-episode offers require the complete timeline.
      if (row['timestamps'] is! List ||
          stamps.length != (row['timestamps'] as List).length) {
        continue;
      }
      for (var i = 0; i < stamps.length; i++) {
        final type = stamps[i]['type'];
        if (type is! Map ||
            !['Credits', 'New Credits'].contains(type['name'])) {
          continue;
        }
        final start = _number(stamps[i]['at'])!;
        var last = i + 1;
        while (last < stamps.length &&
            stamps[last]['type'] is Map &&
            ['Credits', 'New Credits'].contains(stamps[last]['type']['name'])) {
          last++;
        }
        final end =
            last < stamps.length ? _number(stamps[last]['at'])! : length;
        if (_validEnding(start, end, length, duration)) {
          valid.add(EndingSkipResult(start, end, 'AnimeSkip',
              terminal: last == stamps.length || end == length));
        }
        i = last - 1;
      }
    }
    return valid.isEmpty ? null : _agreeEnding(valid);
  }

  Future<List<double>?> _animeSkip(
      Map media, int number, double duration) async {
    final episodes = await _animeEpisodeRows(media, number, duration);
    final valid = <(List<double>, int, double)>[];
    for (final row in episodes) {
      final length = _number(row['baseDuration'])!;
      final stamps = _stamps(row);
      for (var i = 0; i + 1 < stamps.length; i++) {
        final type = stamps[i]['type'];
        if (type is! Map || !['Intro', 'New Intro'].contains(type['name'])) {
          continue;
        }
        final start = _number(stamps[i]['at'])!,
            end = _number(stamps[i + 1]['at'])!;
        if (end - start >= 40 && end - start <= 210 && end <= duration - 300) {
          valid.add(([start, end], stamps.length, (length - duration).abs()));
        }
      }
    }
    if (valid.isEmpty) return null;
    // Duplicate submissions must agree before any can be used to seek.
    if (valid.any((a) => valid.any((b) =>
        (a.$1[0] - b.$1[0]).abs() > 3 || (a.$1[1] - b.$1[1]).abs() > 3))) {
      return null;
    }
    valid.sort((a, b) {
      final count = b.$2.compareTo(a.$2);
      return count != 0 ? count : a.$3.compareTo(b.$3);
    });
    return valid.first.$1;
  }

  Future<List> _fetchAnimeShows(int? id, String search) async {
    final response = await _http
        .post(Uri.https('api.anime-skip.com', '/graphql'),
            headers: {
              'Content-Type': 'application/json',
              // Official shared public client; this is not a private credential.
              'X-Client-ID': const String.fromEnvironment(
                  'ANIME_SKIP_CLIENT_ID',
                  defaultValue: 'ZGfO0sMF3eCwLYf8yMSCJjlynwNGRXWE')
            },
            body: jsonEncode({
              'query': id != null
                  ? 'query(\$id:String!){shows:findShowsByExternalId(service:ANILIST,serviceId:\$id){id name originalName episodes{season number baseDuration timestamps{at type{name}}}}}'
                  : 'query(\$search:String!){shows:searchShows(search:\$search,limit:10){id name originalName episodes{season number baseDuration timestamps{at type{name}}}}}',
              'variables': id != null ? {'id': '$id'} : {'search': search}
            }))
        .timeout(const Duration(seconds: 8));
    if (response.statusCode == 404) return const [];
    _check(response);
    final data = jsonDecode(utf8.decode(response.bodyBytes));
    if (data is Map &&
        data['errors'] is List &&
        (data['errors'] as List).isNotEmpty) {
      throw StateError('AnimeSkip query failed');
    }
    final shows =
        data is Map && data['data'] is Map ? data['data']['shows'] : null;
    return shows is List ? shows : const [];
  }

  static void _check(http.Response response) {
    if (response.statusCode >= 400) {
      throw StateError('Opening skip API returned ${response.statusCode}');
    }
  }
}

(String, int)? _mergedSeason(
    List<(double, Map)> subjects, DateTime? requested) {
  if (subjects.length < 2 || requested == null) return null;
  final names = <List<String>>[];
  final dates = <DateTime>{};
  var total = 0;
  for (final entry in subjects) {
    final row = entry.$2;
    final date = _date(row['date']);
    final episodes = row['eps'];
    if (date == null || !dates.add(date) || episodes is! int || episodes <= 0) {
      return null;
    }
    total += episodes;
    names.add((row['name'] ?? '').toString().trim().split(RegExp(r'\s+')));
  }
  final sorted = dates.toList()..sort();
  if (sorted.first != requested ||
      sorted.last.difference(requested).inDays > 365) {
    return null;
  }
  var common = 0;
  while (names.every((name) => name.length > common) &&
      names.every((name) => name[common] == names.first[common])) {
    common++;
  }
  if (common == 0 || names.any((name) => name.length == common)) return null;
  final title = names.first.take(common).join(' ');
  if (title.runes.length < 8) return null;
  return (title, total);
}

DateTime? _date(Object? value) {
  final match = RegExp(r'^(\d{4})[/-](\d{1,2})[/-](\d{1,2})$')
      .firstMatch((value ?? '').toString().trim());
  if (match == null) return null;
  final year = int.parse(match[1]!);
  final month = int.parse(match[2]!);
  final day = int.parse(match[3]!);
  final date = DateTime.utc(year, month, day);
  return date.month == month && date.day == day ? date : null;
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
    // Bahamut often names the complete season without the database's arc
    // suffix. This is still subject to premiere/episode checks in the resolver.
    final withoutArc =
        candidate.replaceFirst(RegExp(r'\s+[^\s]{1,12}(?:篇|編|编)$'), '');
    if (withoutArc != candidate &&
        _plain(withoutArc.replaceAll(_seasonPattern, ''), characters) == left) {
      best = math.max(best, .9);
    }
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
