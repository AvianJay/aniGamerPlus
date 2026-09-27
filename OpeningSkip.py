# coding: utf-8
"""Conservative AniSkip lookup for the Flutter player's skip-intro button.

Bahamut IDs are not MAL IDs. Match a Bangumi subject by Chinese title and
season, then match its original title and year to AniList's MAL mapping.
Unknown or ambiguous matches return no interval; the client can use danmaku.
"""

import difflib
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


def resolve_mal_id(title, season_start='', *, session=requests):
    """Only accept a uniquely matching Bangumi subject and AniList title."""
    response = session.post(
        'https://api.bgm.tv/v0/search/subjects',
        json={'keyword': title, 'filter': {'type': [2]}, 'limit': 20},
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

    response = session.post(
        'https://graphql.anilist.co',
        json={'query': 'query($s:String){Page(perPage:10){media(search:$s,type:ANIME){idMal title{native} startDate{year}}}}',
              'variables': {'s': original}},
        timeout=8)
    response.raise_for_status()
    media = (((response.json() or {}).get('data') or {}).get('Page') or {}).get('media') or []
    matches = [row for row in media
               if row.get('idMal') and
               _plain((row.get('title') or {}).get('native')) == _plain(original) and
               (not year.isdigit() or
                str((row.get('startDate') or {}).get('year')) == year)]
    return matches[0]['idMal'] if len(matches) == 1 else None


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
        if (0 <= start < end <= min(420, duration * .4) and
                40 <= end - start <= 210 and
                end <= duration - 300 and
                abs(episode_length - duration) <= max(60, duration * .1)):
            valid.append((start, end))
    return max(valid, key=lambda pair: pair[1] - pair[0]) if valid else None
