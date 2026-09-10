"""A standalone FastAPI app that serves the real dashboard templates and static
files against fixture data.

``Dashboard/Server.py`` pulls in ``Config`` -> ``Loginer`` -> ``selenium`` and a
live ``config.json``, none of which belong in a UI test. This harness mounts the
same ``templates`` / ``static`` folders and reimplements only the handful of
endpoints the redesigned pages talk to, with the same response shapes as the
real server (see ``_build_dashboard_bootstrap`` / ``_build_watch_bootstrap`` and
the ``/watch/time`` route in ``Dashboard/Server.py``).
"""

import json
import os
import re
import shutil
import subprocess
import threading
import time
from datetime import datetime, timedelta

from fastapi import FastAPI, Request
from fastapi.responses import FileResponse, JSONResponse, Response
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
import uvicorn

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TEMPLATE_PATH = os.path.join(ROOT, 'Dashboard', 'templates')
STATIC_PATH = os.path.join(ROOT, 'Dashboard', 'static')
FIXTURES = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'fixtures')

ANIMES = [
    ('葬送的芙莉蓮', 4),
    ('迷宮飯', 3),
    ('孤獨搖滾！', 2),
    ('SPY×FAMILY', 3),
    ('Frieren Beyond Journey', 2),
]


def build_video_list():
    """Mirror the schema written by ``aniGamerPlus.updatelist()``."""
    videos = []
    sn = 100000
    now = datetime.now().replace(microsecond=0)
    for day, (anime, episodes) in enumerate(ANIMES):
        # Anchored inside its own calendar day rather than a fixed number of
        # hours back: an hour before ``now`` is yesterday when the suite runs
        # just after midnight, and the timetable then has no 今天 group at all.
        midnight = (now - timedelta(days=day)).replace(hour=0, minute=0, second=0)
        for episode in range(1, episodes + 1):
            sn += 1
            stamp = max(midnight, now - timedelta(days=day, seconds=episode))
            videos.append({
                'sn': str(sn),
                'title': '%s[%d]' % (anime, episode),
                'anime_name': anime,
                'episode': str(episode),
                'resolution': 1080 if episode % 2 else 720,
                'path': os.path.join('bangumi', anime, '%s[%d][1080P].mp4' % (anime, episode)),
                'source': 'baha',
                'timestamp': int(stamp.timestamp()),
                'danmu_path': os.path.join('bangumi', anime, '%s[%d].ass' % (anime, episode)),
                'danmu': True,
            })
    return {'videos': videos}


VIDEO_LIST = build_video_list()
FIRST_SN = VIDEO_LIST['videos'][0]['sn']
# One title whose file is missing, so /thumbnail.jpg has something to 404 on.
NO_THUMBNAIL_SN = VIDEO_LIST['videos'][-1]['sn']

# Written by /watch/time and read back by the home page, exactly like the real
# server's per-user ``videotimes`` map.
WATCH_TIMES = {
    VIDEO_LIST['videos'][1]['sn']: {
        'time': 420,
        'ended': False,
        'timestamp': int(time.time()) - 600,
        'duration': 1440,
    },
    VIDEO_LIST['videos'][5]['sn']: {
        'time': 90,
        'ended': False,
        'timestamp': int(time.time()) - 4000,
        'duration': 1500,
    },
}


# --- 動畫瘋 catalogue -------------------------------------------------------
#
# Mirrors ``Catalog.parse_index`` and the ``/catalog/*`` routes in
# ``Dashboard/Server.py``. Covers point at /thumbnail.jpg so the fixture image
# stands in for p2.bahamut.com.tw and the suite never touches the network.

CATALOG_PAGE_SIZE = 28
CATALOG_COVER = '/thumbnail.jpg?id=%s' % FIRST_SN
WEEKDAYS = ['週一', '週二', '週三', '週四', '週五', '週六', '週日']


def catalog_card(index, title):
    return {
        'animeSn': str(200000 + index),
        'acgSn': str(9000 + index),
        'videoSn': str(300000 + index),
        'title': title,
        'cover': CATALOG_COVER,
        'info': '2026 年 07 月',
        'volume': '第 %d 集' % (index % 12 + 1),
        'popular': '%d.%d萬' % (index % 40 + 1, index % 10),
    }


CATALOG_SEASON = [catalog_card(i, '本季新番 %02d' % i) for i in range(1, 7)]
CATALOG_HOT = [catalog_card(50 + i, '近期熱播 %02d' % i) for i in range(1, 6)]
CATALOG_NEW_ADDED = [catalog_card(70 + i, '最新上架 %02d' % i) for i in range(1, 5)]
# 70 titles is three pages at the real server's page size, which is what makes
# 上一頁/下一頁 and the "第 N / M 頁" readout worth asserting on.
CATALOG_ALL = [catalog_card(100 + i, '所有動畫 %02d' % i) for i in range(1, 71)]


def build_catalog_schedule():
    """Weekday rows, including the two shapes the page has to tell apart."""
    days = []
    for index, label in enumerate(WEEKDAYS, start=1):
        rows = []
        # 週日 stays empty so the "no broadcast today" copy is covered.
        if index < 7:
            for slot, card in enumerate(CATALOG_SEASON[:index]):
                rows.append({
                    'videoSn': card['videoSn'],
                    # The first row of 週一 is a title 本季新番 does not list, so
                    # it has no animeSn and must render as text, not a link.
                    'animeSn': '' if (index == 1 and slot == 0) else card['animeSn'],
                    'cover': '' if (index == 1 and slot == 0) else card['cover'],
                    'title': card['title'],
                    'time': '%02d:00' % (18 + slot % 6),
                    'volume': card['volume'],
                })
        days.append({'weekday': index, 'label': label, 'episodes': rows})
    return days


CATALOG_SCHEDULE = build_catalog_schedule()

CATALOG_INDEX = {
    'season': CATALOG_SEASON,
    'schedule': CATALOG_SCHEDULE,
    'hot': CATALOG_HOT,
    'newAdded': CATALOG_NEW_ADDED,
}

# The one title with an episode already on disk, so the sheet's 立即觀看 button
# and the local-episode marker have something to render against.
CATALOG_LOCAL_SN = CATALOG_ALL[0]['animeSn']
# A second title whose downloaded episode is the one the sheet lands on. That is
# the only shape where 邊看邊下載 belongs hidden -- one local episode elsewhere in
# the series says nothing about the episode the button would stream.
CATALOG_LANDING_LOCAL_SN = CATALOG_ALL[1]['animeSn']


def catalog_detail(anime_sn):
    card = None
    for item in CATALOG_SEASON + CATALOG_HOT + CATALOG_NEW_ADDED + CATALOG_ALL:
        if item['animeSn'] == anime_sn:
            card = item
            break
    if card is None:
        return None
    local = anime_sn == CATALOG_LOCAL_SN
    landing_local = anime_sn == CATALOG_LANDING_LOCAL_SN
    episodes = []
    for number in range(1, 131):
        on_disk = (local and number == 2) or (landing_local and number == 1)
        episodes.append({
            # 動畫瘋 gives the anime page and its first episode the same sn:
            # open 番組頁 and you are already standing on episode 1. Numbering
            # from card['videoSn'] + 1 made the sn the sheet lands on one that
            # appears in no episode list, which no real title does.
            'videoSn': str(int(card['videoSn']) + number - 1),
            'episode': str(number),
            'cover': CATALOG_COVER,
            'local': on_disk,
            'resolution': 1080 if on_disk else 0,
        })
    if local:
        # Point the one downloaded episode at a real fixture, so following the
        # sheet's play link lands on a watch page that can actually play.
        episodes[1]['videoSn'] = FIRST_SN
    if landing_local:
        episodes[0]['videoSn'] = FIRST_SN
    dubbed = [{
        'videoSn': str(int(card['videoSn']) + 500 + number),
        'episode': str(number),
        'cover': CATALOG_COVER,
        'local': False,
        'resolution': 0,
    } for number in range(1, 4)]
    return {
        'animeSn': anime_sn,
        # Follows the first episode, exactly as it does upstream.
        'videoSn': episodes[0]['videoSn'],
        'title': card['title'],
        'cover': CATALOG_COVER,
        # Long enough to trip the sheet's synopsis clamp.
        'content': '測試用的作品介紹。' * 40,
        'tags': ['奇幻', '冒險'],
        'director': '測試導演',
        'publisher': '測試代理商',
        'score': '4.8',
        'seasonStart': '2026/07/03',
        'popular': '12.4萬',
        'totalEpisode': '130',
        'groups': [
            {'name': '本篇', 'episodes': episodes},
            {'name': '中文配音', 'episodes': dubbed},
        ],
    }


# --------------------------------------------------------------- 邊看邊下載
# The player side of watch-while-downloading is the one part of this feature a
# unit test cannot reach: it lives in hls.js's transmuxer and in the browser's
# media pipeline. So the harness ships a genuine encrypted HLS stream -- built
# once with ffmpeg, encrypted here -- and serves it through the same four routes
# Dashboard/Server.py exposes. What the tests then prove is that the protocol
# those routes speak is one a real browser will actually play.

HLS_DIR = os.path.join(FIXTURES, 'hls')
# The videoSn of 本季新番 01, so the catalog sheet's 邊看邊下載 button lands on a
# watch page that really streams rather than on a stub.
HLS_SN = CATALOG_SEASON[0]['videoSn']
HLS_ANIME = CATALOG_SEASON[0]['title']
HLS_KEY = bytes(bytearray(range(16)))
HLS_SEGMENT_SECONDS = 2
HLS_SEGMENTS = 6
HLS_TOTAL_SECONDS = HLS_SEGMENT_SECONDS * HLS_SEGMENTS
# Chunk names have to match Anime.py's r'media_b.+ts', because that expression is
# what the real server stats the temp directory with.
HLS_SEGMENT_NAME = 'media_b1875000_%d.ts'

# Mutated straight from the tests -- the harness runs on a thread in the same
# process, so there is no need for a control endpoint to fake progress with.
# 'pending' is not a wire value: it stands for the seconds between /manualTask
# answering and the download thread creating its progress entry, which the real
# server can only report as 'none'. 'bootstrap' False reproduces the same gap on
# the page-render side, where _hls_bootstrap_entry refuses without streaming=1.
HLS_STATE = {'ready': 2, 'mode': 'streaming', 'bootstrap': True}
HLS_STATE_DEFAULT = dict(HLS_STATE)


def _hls_encrypt(plain, index):
    """AES-128-CBC with the segment index as the IV, PKCS#7 padded.

    That is the HLS default when #EXT-X-KEY carries no IV= of its own, which is
    exactly the shape 動畫瘋 sends -- and the reason the real renderer must never
    renumber a segment.
    """
    from Crypto.Cipher import AES
    pad = 16 - (len(plain) % 16)
    cipher = AES.new(HLS_KEY, AES.MODE_CBC, index.to_bytes(16, 'big'))
    return cipher.encrypt(plain + bytes(bytearray([pad]) * pad))


def build_hls_fixture():
    """Return the per-segment durations, or None when the stream cannot be built.

    ffmpeg is what produces the H.264/AAC transport stream; there is no way to
    hand-roll one a browser will decode. It is already a hard requirement of
    aniGamerPlus itself, so needing it here costs nothing -- but the tests skip
    rather than fail when it is missing, since a machine without it cannot run
    the downloader either.
    """
    marker = os.path.join(HLS_DIR, 'ready.json')
    if os.path.isfile(marker):
        with open(marker, encoding='utf-8') as handle:
            return json.load(handle)

    ffmpeg = shutil.which('ffmpeg')
    if not ffmpeg:
        return None
    try:
        from Crypto.Cipher import AES  # noqa: F401
    except ImportError:
        return None

    if os.path.isdir(HLS_DIR):
        shutil.rmtree(HLS_DIR, ignore_errors=True)
    os.makedirs(HLS_DIR)
    # Plain segments first: ffmpeg's own -hls_key_info_file writes a single IV=
    # into the playlist for every segment, which is not the shape being tested.
    subprocess.check_call([
        ffmpeg, '-v', 'error', '-y',
        '-f', 'lavfi', '-i', 'testsrc=size=320x180:rate=15:duration=%d' % HLS_TOTAL_SECONDS,
        '-f', 'lavfi', '-i', 'sine=frequency=440:duration=%d' % HLS_TOTAL_SECONDS,
        '-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p', '-g', '30',
        '-c:a', 'aac', '-ar', '44100',
        '-hls_time', str(HLS_SEGMENT_SECONDS), '-hls_list_size', '0',
        '-hls_segment_filename', os.path.join(HLS_DIR, HLS_SEGMENT_NAME),
        '-hls_playlist_type', 'vod', os.path.join(HLS_DIR, 'plain.m3u8'),
    ])

    durations = []
    for index in range(HLS_SEGMENTS):
        path = os.path.join(HLS_DIR, HLS_SEGMENT_NAME % index)
        with open(path, 'rb') as handle:
            plain = handle.read()
        with open(path, 'wb') as handle:
            handle.write(_hls_encrypt(plain, index))
        durations.append(float(HLS_SEGMENT_SECONDS))

    with open(os.path.join(HLS_DIR, 'key.bin'), 'wb') as handle:
        handle.write(HLS_KEY)
    with open(marker, 'w', encoding='utf-8') as handle:
        json.dump(durations, handle)
    return durations


HLS_DURATIONS = build_hls_fixture()


def hls_playlist_body():
    """The same wire format Dashboard/Server.py's _hls_render emits."""
    ready = min(int(HLS_STATE['ready']), HLS_SEGMENTS)
    lines = [
        '#EXTM3U',
        '#EXT-X-VERSION:3',
        '#EXT-X-TARGETDURATION:%d' % HLS_SEGMENT_SECONDS,
        '#EXT-X-MEDIA-SEQUENCE:0',
        '#EXT-X-PLAYLIST-TYPE:EVENT',
        '#EXT-X-START:TIME-OFFSET=0,PRECISE=YES',
        '#EXT-X-KEY:METHOD=AES-128,URI="key.bin?id=%s"' % HLS_SN,
    ]
    for index in range(ready):
        lines.append('#EXTINF:%.3f,' % HLS_DURATIONS[index])
        lines.append('segment.ts?id=%s&n=%d' % (HLS_SN, index))
    if HLS_STATE['mode'] == 'finalising':
        lines.append('#EXT-X-ENDLIST')
    return '\n'.join(lines) + '\n'


def hls_status_body():
    ready = min(int(HLS_STATE['ready']), HLS_SEGMENTS)
    mode = HLS_STATE['mode']
    return {
        'mode': 'none' if mode == 'pending' else mode,
        'ready': ready,
        'total': HLS_SEGMENTS,
        'readyDuration': round(sum(HLS_DURATIONS[:ready]), 3),
        'totalDuration': round(sum(HLS_DURATIONS), 3),
        'targetDuration': HLS_SEGMENT_SECONDS,
        'playlistId': 'harness-%d' % HLS_SEGMENTS,
        'rate': round(100.0 * ready / HLS_SEGMENTS, 1),
        'status': '下載完成' if mode == 'finalising' else '正在下載',
        'resolution': 1080,
        'danmu': mode == 'file',
        'videoUrl': './get_video.mp4?id=%s' % HLS_SN if mode == 'file' else None,
    }


def hls_video_entry():
    """A video_list-shaped entry for the episode that is still downloading.

    _hls_bootstrap_entry builds the real one; the point of matching its shape is
    that watch.js must not need to know which of the two it got.
    """
    return {
        'sn': HLS_SN,
        'title': '第 1 集',
        'anime_name': HLS_ANIME,
        'episode': '1',
        'resolution': 1080,
        'path': '',
        'source': 'bahamut',
        'timestamp': int(time.time()),
        'danmu_path': None,
        'danmu': False,
        'streaming': True,
        'pending': not _hls_registered(),
    }


def _hls_registered():
    return HLS_STATE['bootstrap'] and HLS_STATE['mode'] != 'pending'


# --- 作品資料 --------------------------------------------------------------
#
# What /watch/series.json returns: the official cover, the official synopsis and
# the whole episode table, keyed on any one episode's videoSn. Mirrors the
# ``watch_series`` route in ``Dashboard/Server.py``.

# How many episodes 動畫瘋 lists beyond what the library has. Any number > 0
# reproduces the bug this route exists to fix, where 選集 showed 共 1 集.
WATCH_SERIES_EXTRA = 3
# Deliberately unlike anything the page could synthesise from video_list.json,
# so "showed the real 作品介紹" is assertable rather than merely plausible.
# Long on purpose: 巴哈's own 作品介紹 runs to a few hundred characters
# because the staff credits are tacked onto the end of it, and the page folds
# that away. A synopsis short enough to fit takes a different branch.
WATCH_SYNOPSIS = '這是動畫瘋寫的作品介紹，講的是這部作品在演什麼。' * 30
# The last title has no official data at all -- a file that came from somewhere
# other than 動畫瘋, which the library is free to hold.
NO_SERIES_INFO_ANIME = ANIMES[-1][0]


def build_watch_series():
    series = {}
    remote_sn = 900000
    for index, (anime, count) in enumerate(ANIMES):
        if anime == NO_SERIES_INFO_ANIME:
            continue
        local = [v for v in VIDEO_LIST['videos'] if v['anime_name'] == anime]
        episodes = [{
            'videoSn': video['sn'],
            'episode': video['episode'],
            'cover': CATALOG_COVER,
            'local': True,
            'resolution': video['resolution'],
        } for video in local]
        for extra in range(1, WATCH_SERIES_EXTRA + 1):
            remote_sn += 1
            episodes.append({
                'videoSn': str(remote_sn),
                'episode': str(count + extra),
                'cover': CATALOG_COVER,
                'local': False,
                'resolution': 0,
            })
        groups = [{'name': '本篇', 'episodes': episodes}]
        if index == 0:
            # 動畫瘋 files dubs under their own tab, so the page has to label
            # groups rather than run them together into one numbered strip.
            dubbed = []
            for number in range(1, 3):
                remote_sn += 1
                dubbed.append({
                    'videoSn': str(remote_sn),
                    'episode': str(number),
                    'cover': CATALOG_COVER,
                    'local': False,
                    'resolution': 0,
                })
            groups.append({'name': '中文配音', 'episodes': dubbed})
        detail = {
            'animeSn': str(400000 + index),
            'videoSn': local[0]['sn'],
            'title': anime,
            # A different path from ./thumbnail.jpg on purpose: the cover the
            # page ends up with says which of the two it chose.
            'cover': '/cover.jpg?anime=%d' % index,
            'content': WATCH_SYNOPSIS,
            'tags': ['奇幻', '冒險'],
            'director': '測試導演',
            'publisher': '測試代理商',
            'score': '4.7',
            'seasonStart': '2026/07/03',
            'popular': '12.4萬',
            'totalEpisode': str(count + WATCH_SERIES_EXTRA),
            'groups': groups,
        }
        for group in groups:
            for episode in group['episodes']:
                series[episode['videoSn']] = detail
    return series


WATCH_SERIES = build_watch_series()
# The episode that is still downloading belongs to a catalogue title, and the
# real server answers for it out of the same cached 作品資料 -- that is the case
# the user hit: 邊看邊下載 and then 共 1 集.
WATCH_SERIES_STREAMING = catalog_detail(CATALOG_SEASON[0]['animeSn'])
WATCH_SERIES_LOCAL_SN = VIDEO_LIST['videos'][0]['sn']
WATCH_SERIES_TOTAL = sum(len(g['episodes']) for g in WATCH_SERIES[WATCH_SERIES_LOCAL_SN]['groups'])


# Every task the page queues is kept so a test can assert on the payload rather
# than on a toast that only says something happened.
MANUAL_TASKS = []


def create_app(logged_in=True, catalog=True, hls=True):
    app = FastAPI(docs_url=None, redoc_url=None, openapi_url=None)
    app.mount('/static', StaticFiles(directory=STATIC_PATH), name='static')
    templates = Jinja2Templates(directory=TEMPLATE_PATH)

    @app.middleware('http')
    async def add_accept_ranges(request: Request, call_next):
        response = await call_next(request)
        if 'accept-ranges' not in response.headers:
            response.headers['Accept-Ranges'] = 'bytes'
        return response

    def dashboard_bootstrap():
        return {
            'serverInfo': {
                'online_watch': True,
                'user_control': logged_in,
                'online_watch_requires_login': False,
            },
            'loggedIn': logged_in,
            'currentUser': {'username': 'tester', 'role': 'admin'} if logged_in else None,
        }

    def watch_bootstrap(request: Request):
        requested_sn = str(request.query_params.get('id') or '').strip()
        requested_resolution = str(request.query_params.get('res') or '').strip()
        bootstrap = {
            'requestedVideoId': requested_sn or None,
            'requestedResolution': requested_resolution or None,
            'initialVideoData': None,
            'initialVideoSeries': [],
            'resumeTime': 0,
            'streaming': False,
        }
        if not requested_sn:
            return bootstrap
        initial = None
        for video in VIDEO_LIST['videos']:
            if str(video['sn']) == requested_sn:
                initial = dict(video)
                break
        if not initial and hls and HLS_DURATIONS and requested_sn == HLS_SN:
            # Downloading, so not in video_list.json -- but the page still gets
            # something the right shape, exactly as the real bootstrap does.
            if not _hls_registered() and not request.query_params.get('streaming'):
                return bootstrap
            initial = hls_video_entry()
            bootstrap['streaming'] = True
        if not initial:
            return bootstrap
        if requested_resolution.isdigit():
            initial['resolution'] = requested_resolution
        bootstrap['initialVideoData'] = initial
        bootstrap['initialVideoSeries'] = [
            video for video in VIDEO_LIST['videos']
            if video['anime_name'] == initial['anime_name']
        ]
        entry = WATCH_TIMES.get(requested_sn, {})
        if logged_in and not entry.get('ended'):
            bootstrap['resumeTime'] = int(entry.get('time', 0) or 0)
        return bootstrap

    def render(request: Request, name, context=None):
        merged = {'request': request, 'dashboard_bootstrap': dashboard_bootstrap()}
        if context:
            merged.update(context)
        return templates.TemplateResponse(request, name, merged)

    @app.get('/')
    def home(request: Request):
        return render(request, 'index.html')

    @app.get('/watch')
    def watch(request: Request):
        return render(request, 'watch.html', {'watch_bootstrap': watch_bootstrap(request)})

    @app.get('/control')
    def control():
        return Response('<!doctype html><title>control</title><p>control stub</p>',
                        media_type='text/html')

    @app.get('/video_list.json')
    def video_list():
        return JSONResponse(VIDEO_LIST)

    @app.get('/watch/series.json')
    def watch_series(request: Request):
        sn = str(request.query_params.get('id') or '')
        detail = WATCH_SERIES.get(sn)
        if detail is None and hls and sn == HLS_SN:
            detail = WATCH_SERIES_STREAMING
        if detail is None:
            # 404 is what the real route says for anything it cannot look up,
            # and the page has to keep working on it.
            return JSONResponse({'error': 'video not found'}, status_code=404)
        return JSONResponse(detail)

    @app.get('/cover.jpg')
    def cover():
        return FileResponse(os.path.join(FIXTURES, 'sample-thumb.jpg'), media_type='image/jpeg')

    # The real routes live behind ``if settings['dashboard']['online_watch']``
    # and simply do not exist when it is off; catalog=False reproduces that, so
    # the page's degrade-to-片庫-only path stays covered.
    if catalog:
        @app.get('/catalog/index.json')
        def catalog_index():
            return JSONResponse(CATALOG_INDEX)

        @app.get('/catalog/all.json')
        def catalog_all(request: Request):
            query = (request.query_params.get('q') or '').strip().lower()
            items = [item for item in CATALOG_ALL if query in item['title'].lower()]
            try:
                page = max(1, int(request.query_params.get('page') or 1))
            except ValueError:
                page = 1
            pages = max(1, -(-len(items) // CATALOG_PAGE_SIZE))
            page = min(page, pages)
            start = (page - 1) * CATALOG_PAGE_SIZE
            return JSONResponse({
                'items': items[start:start + CATALOG_PAGE_SIZE],
                'page': page,
                'pages': pages,
                'total': len(items),
            })

        @app.get('/catalog/anime.json')
        def catalog_anime(request: Request):
            detail = catalog_detail(str(request.query_params.get('sn') or ''))
            if detail is None:
                return JSONResponse({'error': 'unknown'}, status_code=404)
            return JSONResponse(detail)

    # The real routes only exist while a download is running; HLS_STATE['mode']
    # == 'none' is what stands in for "nothing is downloading" here.
    if hls and HLS_DURATIONS:
        @app.get('/hls/status.json')
        def hls_status():
            response = JSONResponse(hls_status_body())
            response.headers['Cache-Control'] = 'no-store'
            return response

        @app.get('/hls/playlist.m3u8')
        def hls_playlist():
            if HLS_STATE['mode'] in ('none', 'file', 'parsing', 'pending'):
                return JSONResponse({'error': 'not ready'}, status_code=404)
            response = Response(hls_playlist_body(),
                                media_type='application/vnd.apple.mpegurl')
            response.headers['Cache-Control'] = 'no-store'
            return response

        @app.get('/hls/key.bin')
        def hls_key():
            return FileResponse(os.path.join(HLS_DIR, 'key.bin'),
                                media_type='application/octet-stream')

        @app.get('/hls/segment.ts')
        def hls_segment(request: Request):
            try:
                index = int(request.query_params.get('n'))
            except (TypeError, ValueError):
                return JSONResponse({'error': 'invalid segment'}, status_code=400)
            # Refusing anything past the published prefix is the server's real
            # behaviour, and the only way a test can tell a player that respects
            # the playlist from one that guesses ahead.
            if index < 0 or index >= min(int(HLS_STATE['ready']), HLS_SEGMENTS):
                return JSONResponse({'error': 'segment not ready'}, status_code=404)
            return FileResponse(os.path.join(HLS_DIR, HLS_SEGMENT_NAME % index),
                                media_type='video/mp2t')

    @app.post('/manualTask')
    async def manual_task(request: Request):
        try:
            body = await request.json()
        except Exception:
            body = {}
        MANUAL_TASKS.append(body if isinstance(body, dict) else {})
        return Response('{"status":"200"}', media_type='text/html')

    @app.get('/manualTask/_seen')
    def manual_tasks_seen():
        return JSONResponse(MANUAL_TASKS)

    @app.get('/get_server_info')
    def server_info():
        return JSONResponse(dashboard_bootstrap()['serverInfo'])

    @app.api_route('/watch/time', methods=['GET', 'POST'])
    async def watch_time(request: Request):
        if request.method == 'GET':
            data = dict(request.query_params)
        else:
            try:
                body = await request.json()
            except Exception:
                body = None
            if isinstance(body, dict) and body:
                data = body
            else:
                try:
                    data = dict(await request.form())
                except Exception:
                    data = {}
        kind = data.get('type')
        sn = data.get('sn')
        if kind == 'set':
            entry = {
                'time': int(float(data.get('time') or 0)),
                'ended': str(data.get('ended', 'false')).lower() == 'true',
                'timestamp': int(time.time()),
            }
            try:
                duration = int(float(data.get('duration')))
                if duration > 0:
                    entry['duration'] = duration
            except (TypeError, ValueError):
                pass
            WATCH_TIMES[sn] = entry
            return Response('{"status":"200"}', media_type='text/html')
        if kind == 'del':
            WATCH_TIMES.pop(sn, None)
            return Response('{"status":"200"}', media_type='text/html')
        if kind == 'get':
            if not sn:
                return JSONResponse(WATCH_TIMES)
            return JSONResponse(WATCH_TIMES.get(sn, {'time': 0, 'ended': False}))
        return Response('{"status":"404", "msg":"Invalid type"}', media_type='text/html')

    @app.get('/get_video.mp4')
    def get_video():
        # The fixture is VP9/Opus rather than H.264: Playwright's bundled
        # Chromium ships without the proprietary codecs, and the browser goes by
        # the Content-Type here, not by the route's .mp4 name. FileResponse
        # handles the Range requests the player issues while seeking.
        return FileResponse(os.path.join(FIXTURES, 'sample.webm'), media_type='video/webm')

    @app.get('/thumbnail.jpg')
    def thumbnail(request: Request):
        # The real server grabs this frame out of the downloaded episode with
        # ffmpeg and 404s when there is no file to grab from; NO_THUMBNAIL_SN
        # stands in for that case so the gradient fallback stays covered.
        sn = request.query_params.get('id')
        if not sn or sn == NO_THUMBNAIL_SN:
            return JSONResponse({'error': 'thumbnail unavailable'}, status_code=404)
        return FileResponse(os.path.join(FIXTURES, 'sample-thumb.jpg'), media_type='image/jpeg')

    @app.get('/get_danmu.ass')
    def get_danmu():
        response = FileResponse(os.path.join(FIXTURES, 'sample.ass'))
        response.headers['Content-Type'] = 'text/plain; charset=utf-8'
        return response

    @app.get('/manifest.webmanifest')
    def manifest():
        response = FileResponse(os.path.join(STATIC_PATH, 'manifest.webmanifest'))
        response.headers['Content-Type'] = 'application/manifest+json; charset=utf-8'
        return response

    @app.get('/sw.js')
    def service_worker():
        response = FileResponse(os.path.join(STATIC_PATH, 'sw.js'))
        response.headers['Content-Type'] = 'application/javascript; charset=utf-8'
        response.headers['Service-Worker-Allowed'] = '/'
        return response

    @app.get('/favicon.ico')
    def favicon():
        return FileResponse(os.path.join(STATIC_PATH, 'img', 'aniGamerPlus.ico'))

    @app.get('/apple-touch-icon.png')
    @app.get('/apple-touch-icon-precomposed.png')
    def apple_touch_icon():
        return FileResponse(os.path.join(STATIC_PATH, 'img', 'pwa', 'apple-touch-icon.png'))

    return app


def _free_port():
    import socket
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.bind(('127.0.0.1', 0))
    port = sock.getsockname()[1]
    sock.close()
    return port


class HarnessServer(object):
    """Runs the harness on a background thread and exposes its base URL."""

    def __init__(self, logged_in=True, catalog=True, hls=True):
        self.port = _free_port()
        config = uvicorn.Config(create_app(logged_in, catalog, hls),
                                host='127.0.0.1', port=self.port, log_level='error')
        self.server = uvicorn.Server(config)
        self.thread = threading.Thread(target=self.server.run, daemon=True)

    @property
    def url(self):
        return 'http://127.0.0.1:%d' % self.port

    def __enter__(self):
        self.thread.start()
        deadline = time.time() + 15
        while not self.server.started:
            if time.time() > deadline:
                raise RuntimeError('harness did not start in time')
            time.sleep(0.05)
        return self

    def __exit__(self, *exc):
        self.server.should_exit = True
        self.thread.join(timeout=10)


def head_of(path):
    """Read a template/static file for assertions that do not need a browser."""
    with open(os.path.join(ROOT, path), encoding='utf-8') as handle:
        return handle.read()


ASSET_REF = re.compile(r'(?:href|src)="\./(static/[^"?]+)')


def referenced_static_assets(html):
    return sorted(set(ASSET_REF.findall(html)))


if __name__ == '__main__':
    with HarnessServer() as server:
        print('harness on %s (sample sn=%s)' % (server.url, FIRST_SN))
        try:
            while True:
                time.sleep(1)
        except KeyboardInterrupt:
            pass
