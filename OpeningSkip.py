# coding: utf-8
"""Conservative metadata and timestamp lookup with opening-skip fallbacks.

Bahamut IDs are not MAL IDs. Match a Bangumi subject by Chinese title and
season, then verify its original title and year at AniList or Jikan.
Unknown or ambiguous matches return no interval; the client can use danmaku.
"""

import difflib
import math
import re
import unicodedata

import requests
try:
    from opencc import OpenCC
except ImportError:  # Old server installs can start before dependencies are upgraded.
    OpenCC = None


_t2s = OpenCC('t2s') if OpenCC else None


def _simplify(value):
    return _t2s.convert(str(value or '')) if _t2s else str(value or '')
_season = re.compile(r'第\s*([一二三四五六七八九十\d]+)\s*季', re.I)


def _plain(value):
    text = unicodedata.normalize('NFKC', _simplify(value)).lower()
    return ''.join(ch for ch in text if ch.isalnum())


def _season_number(value):
    match = _season.search(_simplify(value))
    if not match:
        return ''
    raw = match.group(1)
    return {'一': '1', '二': '2', '三': '3', '四': '4', '五': '5',
            '六': '6', '七': '7', '八': '8', '九': '9', '十': '10'}.get(raw, raw)


def _subject_score(title, subject):
    wanted_season = _season_number(title)
    candidates = [subject.get('name_cn'), subject.get('name')]
    for row in subject.get('infobox') or []:
        if row.get('key') not in ('别名', '別名', '中文名'):
            continue
        value = row.get('value')
        if isinstance(value, list):
            candidates.extend(v.get('v') for v in value if isinstance(v, dict))
        else:
            candidates.append(value)
    best = 0.0
    for candidate in candidates:
        if not candidate:
            continue
        if _season_number(candidate) != wanted_season:
            continue
        left = _plain(_season.sub('', title))
        right = _plain(_season.sub('', candidate))
        if left and right:
            best = max(best, difflib.SequenceMatcher(None, left, right).ratio())
    return best


def resolve_series(title, season_start='', *, session=requests):
    """Only accept a uniquely matching Bangumi subject and AniList title."""
    response = session.post(
        'https://api.bgm.tv/v0/search/subjects',
        json={'keyword': _simplify(title), 'filter': {'type': [2]}, 'limit': 20},
        headers={'User-Agent': 'aniGamerPlus/1.0 (opening skip)'}, timeout=8)
    response.raise_for_status()
    rows = (response.json() or {}).get('data') or []
    scored = sorted(((_subject_score(title, row), row) for row in rows),
                    key=lambda pair: pair[0], reverse=True)
    if not scored or scored[0][0] < 0.87:
        return None
    if len(scored) > 1 and scored[0][0] - scored[1][0] < 0.06:
        return None
    subject = scored[0][1]
    original = subject.get('name') or ''
    if not original:
        return None
    year = str(subject.get('date') or '')[:4]
    requested_year = str(season_start or '')[:4]
    if year.isdigit() and requested_year.isdigit() and year != requested_year:
        return None

    def match(media):
        return [row for row in media if isinstance(row.get('idMal'), int)
                and row['idMal'] > 0 and
                _plain((row.get('title') or {}).get('native')) == _plain(original) and
                (not year.isdigit() or str((row.get('startDate') or {}).get('year')) == year)]

    failure = None
    matches = []
    try:
        response = session.post('https://graphql.anilist.co',
            json={'query': 'query($s:String){Page(perPage:10){media(search:$s,type:ANIME){id idMal episodes title{native romaji english} startDate{year}}}}',
                  'variables': {'s': original}}, timeout=8)
        response.raise_for_status()
        matches = match((((response.json() or {}).get('data') or {}).get('Page') or {}).get('media') or [])
    except Exception as error:
        failure = error
    if not matches:
        try:
            response = session.get('https://api.jikan.moe/v4/anime',
                params={'q': original, 'limit': 25}, timeout=8)
            response.raise_for_status()
            media = []
            for row in (response.json() or {}).get('data') or []:
                aired = str((row.get('aired') or {}).get('from') or '')[:4]
                media.append({'idMal': row.get('mal_id'), 'episodes': row.get('episodes'),
                    'title': {'native': row.get('title_japanese'), 'romaji': row.get('title'),
                              'english': row.get('title_english')},
                    'startDate': {'year': aired}})
            matches = match(media)
        except Exception as error:
            raise failure or error
        if not matches and failure:
            raise failure
    if len(matches) != 1:
        return None
    row = matches[0]
    return {'malId': row['idMal'], 'anilistId': row.get('id'),
            'episodes': row.get('episodes'), 'titles': row.get('title') or {}}


def resolve_mal_id(title, season_start='', *, session=requests):
    series = resolve_series(title, season_start, session=session)
    return series['malId'] if series else None


def aniskip_op(mal_id, episode, duration, *, session=requests):
    if not isinstance(mal_id, int) or mal_id <= 0 or not 1 <= episode <= 999:
        return None
    if not 300 <= duration <= 7200:
        return None
    response = session.get(
        f'https://api.aniskip.com/v2/skip-times/{mal_id}/{episode}',
        params=[('types', 'op'), ('episodeLength', round(duration))],
        timeout=8)
    if response.status_code == 404:
        return None
    response.raise_for_status()
    payload = response.json() or {}
    if not payload.get('found'):
        return None
    valid = []
    for row in payload.get('results') or []:
        if row.get('skipType') != 'op':
            continue
        interval = row.get('interval') or {}
        try:
            start = float(interval['startTime'])
            end = float(interval['endTime'])
            episode_length = float(row.get('episodeLength') or duration)
        except (KeyError, TypeError, ValueError):
            continue
        if (all(math.isfinite(value) for value in (start, end, episode_length)) and
                0 <= start < end and
                40 <= end - start <= 210 and
                end <= duration - 300 and
                abs(episode_length - duration) <= max(60, duration * .1)):
            valid.append((start, end))
    return max(valid, key=lambda pair: pair[1] - pair[0]) if valid else None


# Official public client from anime-skip/api-client-ts; not a private key.
ANIME_SKIP_CLIENT_ID = 'ZGfO0sMF3eCwLYf8yMSCJjlynwNGRXWE'


def anime_skip_op(series, episode, duration, *, session=requests):
    titles = series.get('titles') or {}
    anilist_id = series.get('anilistId')
    search = titles.get('english') or titles.get('romaji') or titles.get('native') or ''
    if not anilist_id and not search:
        return None
    fields = '{id name originalName episodes{season number baseDuration timestamps{at type{name}}}}'
    query = ('query($id:String!){shows:findShowsByExternalId(service:ANILIST,serviceId:$id)' + fields + '}'
             if anilist_id else 'query($search:String!){shows:searchShows(search:$search,limit:10)' + fields + '}')
    response = session.post('https://api.anime-skip.com/graphql',
        headers={'Content-Type': 'application/json', 'X-Client-ID': ANIME_SKIP_CLIENT_ID},
        json={'query': query, 'variables': {'id': str(anilist_id)} if anilist_id else {'search': search}},
        timeout=8)
    if response.status_code == 404:
        return None
    response.raise_for_status()
    data = response.json() or {}
    if data.get('errors'):
        raise ValueError('AnimeSkip query failed')
    shows = (data.get('data') or {}).get('shows') or []
    if not anilist_id:
        names = {_plain(value) for value in titles.values() if value}
        shows = [row for row in shows if _plain(row.get('name')) in names or
                 _plain(row.get('originalName')) in names]
    if len(shows) != 1:
        return None
    episodes = shows[0].get('episodes') or []
    seasons = {str(row.get('season') if row.get('season') is not None else '1').strip() for row in episodes}
    if len(seasons) != 1 or not next(iter(seasons)).isdigit():
        return None
    valid = []
    for row in episodes:
        if not re.fullmatch(r'\d{1,3}', str(row.get('number') or '')) or int(row['number']) != episode:
            continue
        try:
            length = float(row['baseDuration'])
        except (KeyError, TypeError, ValueError):
            continue
        # Do not guess offsets between different streaming cuts.
        if not math.isfinite(length) or abs(length - duration) > 5:
            continue
        stamps = sorted((stamp for stamp in row.get('timestamps') or []
            if isinstance(stamp.get('at'), (int, float)) and math.isfinite(stamp['at'])
            and 0 <= stamp['at'] <= length), key=lambda stamp: stamp['at'])
        for index, stamp in enumerate(stamps[:-1]):
            if (stamp.get('type') or {}).get('name') not in ('Intro', 'New Intro'):
                continue
            start, end = stamp['at'], stamps[index + 1]['at']
            if 40 <= end - start <= 210 and end <= duration - 300:
                valid.append(((start, end), len(stamps), abs(length - duration)))
    if not valid or any(abs(a[0][0] - b[0][0]) > 3 or abs(a[0][1] - b[0][1]) > 3
                        for a in valid for b in valid):
        return None
    return min(valid, key=lambda row: (-row[1], row[2]))[0]


def opening_op(series, episode, duration, *, session=requests):
    if not series or not 1 <= episode <= 999 or not 600 <= duration <= 7200:
        return None
    if isinstance(series.get('episodes'), int) and episode > series['episodes']:
        return None
    failure = None
    for source, lookup in [('AniSkip', lambda: aniskip_op(series['malId'], episode, duration, session=session)),
                           ('AnimeSkip', lambda: anime_skip_op(series, episode, duration, session=session))]:
        try:
            interval = lookup()
            if interval:
                return {'interval': list(interval), 'source': source}
        except Exception as error:
            failure = failure or error
    if failure:
        raise failure
    return None
