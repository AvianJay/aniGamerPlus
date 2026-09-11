"""FastAPI/ASGI migration coverage for ``Dashboard/Server.py``.

Written before the migration (strict vertical-slice TDD): every test below
pins externally observable behaviour of the Flask/gevent server -- URLs,
methods, status codes, response bodies, cookies, and streaming/cache headers --
against the FastAPI app. They fail until the migration lands, then guard it.

Run with::

    PYTHONPATH=/tmp/agp_testdeps python3 -m pytest tests/test_fastapi_server.py

Only local files are touched; nothing here needs Bahamut, a browser, or the
operator's real config: settings/userdata/video paths are all stubbed with
``monkeypatch``.
"""

import copy
import io
import json
import os
import sys
import time

import pytest

import Dashboard.Server as server
from fastapi import FastAPI
from fastapi.testclient import TestClient


# ------------------------------------------------------------------ fixtures

def make_settings(**over):
    """Only keys the server reads, but complete enough for /data/config.json
    (which iterates the dashboard's ``id_list`` verbatim)."""
    settings = {
        'bangumi_dir': '/tmp/agp-bangumi',
        'temp_dir': '/tmp/agp-temp',
        'classify_bangumi': True,
        'lock_resolution': False,
        'segment_download_mode': True,
        'add_bangumi_name_to_video_filename': True,
        'add_resolution_to_video_filename': True,
        'download_resolution': '1080',
        'default_download_mode': 'latest',
        'check_frequency': 5,
        'multi-thread': 1,
        'multi_downloading_segment': 2,
        'customized_video_filename_prefix': '',
        'customized_video_filename_suffix': '',
        'ua': 'test-agent',
        'use_mobile_api': False,
        'danmu': False,
        'use_proxy': False,
        'proxy': '',
        'browser_fingerprint': {'ja3': '', 'akamai': ''},
        'check_latest_version': False,
        'read_sn_list_when_checking_update': True,
        'read_config_when_checking_update': True,
        'save_logs': False,
        'quantity_of_logs': 7,
        'download_cd': 0,
        'parse_sn_cd': 3,
        'm3u8': False,
        'auto_update_danmu': False,
        'plugins': {'enabled': []},
        'dashboard': {
            'host': '127.0.0.1',
            'port': 5000,
            'SSL': False,
            'online_watch': True,
            'online_watch_requires_login': False,
            'user_control': {
                'enabled': False,
                'allow_register': False,
                'default_user': [
                    {'username': 'admin', 'password': 'admin', 'role': 'admin'},
                ],
            },
        },
    }
    settings.update(over)
    return settings


def make_userdata():
    # Plaintext legacy passwords verify on both the old (werkzeug) and the new
    # (hashlib) implementations via the legacy-compare path.
    return {"users": [
        {'username': 'admin', 'password': 'adminpw', 'token': 'admintoken123',
         'videotimes': {}, 'role': 'admin'},
        {'username': 'tester', 'password': 'testerpw', 'token': 'usertoken456',
         'videotimes': {}, 'role': 'user'},
    ]}


@pytest.fixture
def settings():
    return make_settings()


@pytest.fixture
def autouse_settings(monkeypatch, settings):
    """Every route reads settings through these two funnels; point both at the
    same throwaway dict so no test touches the operator's config.json."""
    monkeypatch.setattr(server, '_get_current_settings', lambda: settings)
    monkeypatch.setattr(server.Config, 'read_settings', lambda *a, **k: settings)
    return settings


@pytest.fixture
def userdata(monkeypatch):
    data = make_userdata()
    saved = {}

    def fake_save(new_data):
        # Snapshot first: callers mutate the loaded dict in place and then save
        # the same object, so clearing before copying would wipe the snapshot.
        snapshot = copy.deepcopy(new_data)
        saved.clear()
        saved.update(copy.deepcopy(snapshot))
        data.clear()
        data.update(snapshot)

    monkeypatch.setattr(server, 'load_user_data', lambda: data)
    monkeypatch.setattr(server, 'save_user_data', fake_save)
    return data


@pytest.fixture
def client():
    return TestClient(server.app, raise_server_exceptions=True)


def auth_client(client, token):
    client.cookies.set('token', token)
    return client


# ------------------------------------------------------- migration plumbing

def test_app_is_a_real_fastapi_app_without_flask_or_gevent():
    assert isinstance(server.app, FastAPI)
    assert not any(name.startswith('flask') or name.startswith('gevent')
                   or name.startswith('flask_sock') or name.startswith('geventwebsocket')
                   for name in sys.modules), 'Flask/gevent stack still imported'
    source = io.open(os.path.join('Dashboard', 'Server.py'), encoding='utf-8').read()
    import re
    for banned in ('flask', 'flask_sock', 'gevent', 'geventwebsocket', 'werkzeug'):
        pattern = re.compile(r'^\s*(from|import)\s+%s' % re.escape(banned), re.M)
        assert not pattern.search(source), 'Server.py still imports %r' % banned
    assert 'monkey.patch_all' not in source


def test_entry_points_survive_the_migration():
    assert callable(server.run)
    assert callable(server.checknow)
    assert hasattr(server, 'command_handler')
    assert isinstance(server.websocket_token, str) and server.websocket_token


def test_main_launcher_no_longer_monkey_patches_gevent():
    source = io.open('aniGamerPlus.py', encoding='utf-8').read()
    assert 'monkey.patch_all' not in source
    assert 'from gevent' not in source


# ------------------------------------------------------------------ server info

def test_get_server_info_reports_dashboard_flags(client, autouse_settings, settings):
    response = client.get('/get_server_info')
    assert response.status_code == 200
    assert response.json() == {
        'user_control': False,
        'user_control_allow_register': False,
        'online_watch': True,
        'online_watch_requires_login': False,
    }


def test_every_response_carries_accept_ranges_bytes(client, autouse_settings):
    for path in ('/get_server_info', '/favicon.ico', '/sw.js'):
        assert client.get(path).headers.get('Accept-Ranges') == 'bytes'


# ------------------------------------------------------------------ home page

def test_home_redirects_to_control_when_online_watch_is_off(client, autouse_settings, settings):
    settings['dashboard']['online_watch'] = False
    response = client.get('/', follow_redirects=False)
    assert response.status_code == 302
    assert response.headers['location'].endswith('/control')


def test_home_renders_index_when_online_watch_is_on(client, autouse_settings):
    response = client.get('/')
    assert response.status_code == 200
    assert 'agp-dashboard-bootstrap' in response.text


def test_home_sends_plain_users_to_watch(client, autouse_settings, settings, userdata):
    settings['dashboard']['user_control']['enabled'] = True
    response = client.get('/', cookies={'token': 'usertoken456'}, follow_redirects=False)
    assert response.status_code == 302
    assert response.headers['location'].endswith('/watch')


# ------------------------------------------------- static and root files

def test_favicon_is_served(client):
    response = client.get('/favicon.ico')
    assert response.status_code == 200
    assert len(response.content) > 0


def test_service_worker_headers(client):
    response = client.get('/sw.js')
    assert response.status_code == 200
    assert response.headers['Content-Type'].startswith('application/javascript')
    assert response.headers['Service-Worker-Allowed'] == '/'
    assert response.headers['Cache-Control'] == 'no-cache'


def test_manifest_content_type(client):
    response = client.get('/manifest.webmanifest')
    assert response.status_code == 200
    assert response.headers['Content-Type'].startswith('application/manifest+json')


@pytest.mark.parametrize('path', ['/apple-touch-icon.png', '/apple-touch-icon-precomposed.png'])
def test_apple_touch_icons(client, path):
    assert client.get(path).status_code == 200


def test_bundled_static_file_is_served(client):
    response = client.get('/static/js/settings_id_list.js')
    assert response.status_code == 200
    assert 'id_list' in response.text


# ------------------------------------------------- admin auth plumbing

def test_admin_api_needs_login_when_user_control_is_on(client, autouse_settings, settings, userdata):
    settings['dashboard']['user_control']['enabled'] = True
    response = client.get('/data/config.json')
    assert response.status_code == 401
    assert response.json() == {'success': False, 'message': 'login required'}


def test_admin_api_refuses_plain_users(client, autouse_settings, settings, userdata):
    settings['dashboard']['user_control']['enabled'] = True
    response = client.get('/data/config.json', cookies={'token': 'usertoken456'})
    assert response.status_code == 403
    assert response.json() == {'success': False, 'message': 'admin required'}


def test_admin_api_passes_admins_and_opens_up_when_disabled(
        client, autouse_settings, settings, userdata):
    settings['dashboard']['user_control']['enabled'] = True
    response = client.get('/data/config.json', cookies={'token': 'admintoken123'})
    assert response.status_code == 200
    assert response.json()['download_resolution'] == '1080'

    settings['dashboard']['user_control']['enabled'] = False
    assert client.get('/data/config.json').status_code == 200


def test_admin_pages_redirect_to_login(client, autouse_settings, settings, userdata):
    settings['dashboard']['user_control']['enabled'] = True
    for path in ('/control', '/monitor'):
        response = client.get(path, follow_redirects=False)
        assert response.status_code == 302
        assert response.headers['location'].endswith('./login?error=2')
    assert client.get('/control', cookies={'token': 'admintoken123'}).status_code == 200


# ------------------------------------------------- range streaming

@pytest.fixture
def video_file(tmp_path):
    path = tmp_path / 'episode[1080P].mp4'
    path.write_bytes(bytes(range(256)) * 4)  # 1024 bytes
    return str(path)


def test_video_full_body_and_headers(client, autouse_settings, video_file, monkeypatch):
    monkeypatch.setattr(server, '_find_video_path', lambda sn, res=None: video_file)
    response = client.get('/get_video.mp4?id=123')
    assert response.status_code == 200
    assert len(response.content) == 1024
    assert response.headers['Accept-Ranges'] == 'bytes'
    assert response.headers['ETag']
    assert response.headers['Last-Modified']
    assert response.headers['Content-Disposition'].startswith('inline;')
    assert 'Cache-Control' in response.headers


def test_video_range_request_returns_206(client, autouse_settings, video_file, monkeypatch):
    monkeypatch.setattr(server, '_find_video_path', lambda sn, res=None: video_file)
    response = client.get('/get_video.mp4?id=123', headers={'Range': 'bytes=0-99'})
    assert response.status_code == 206
    assert response.headers['Content-Range'] == 'bytes 0-99/1024'
    assert response.headers['Content-Length'] == '100'
    assert len(response.content) == 100
    assert response.content == bytes(range(100))


def test_video_open_ended_range(client, autouse_settings, video_file, monkeypatch):
    monkeypatch.setattr(server, '_find_video_path', lambda sn, res=None: video_file)
    response = client.get('/get_video.mp4?id=123', headers={'Range': 'bytes=1000-'})
    assert response.status_code == 206
    assert response.headers['Content-Range'] == 'bytes 1000-1023/1024'
    assert len(response.content) == 24


def test_video_conditional_request_returns_304(client, autouse_settings, video_file, monkeypatch):
    monkeypatch.setattr(server, '_find_video_path', lambda sn, res=None: video_file)
    etag = client.get('/get_video.mp4?id=123').headers['ETag']
    response = client.get('/get_video.mp4?id=123', headers={'If-None-Match': etag})
    assert response.status_code == 304
    assert response.content == b''


def test_video_head_returns_headers_without_body(client, autouse_settings, video_file, monkeypatch):
    monkeypatch.setattr(server, '_find_video_path', lambda sn, res=None: video_file)
    response = client.head('/get_video.mp4?id=123')
    assert response.status_code == 200
    assert response.content == b''
    assert response.headers['ETag']


def test_video_404_for_unknown_sn(client, autouse_settings, monkeypatch):
    monkeypatch.setattr(server, '_find_video_path', lambda sn, res=None: None)
    response = client.get('/get_video.mp4?id=999')
    assert response.status_code == 404
    assert response.json() == {'error': 'video not found'}


def test_video_requires_login_when_configured(client, autouse_settings, settings, userdata,
                                               video_file, monkeypatch):
    settings['dashboard']['online_watch_requires_login'] = True
    monkeypatch.setattr(server, '_find_video_path', lambda sn, res=None: video_file)
    assert client.get('/get_video.mp4?id=123').status_code == 403
    assert client.get('/get_video.mp4?id=123', cookies={'token': 'nope'}).status_code == 403
    assert client.get('/get_video.mp4?id=123',
                      cookies={'token': 'usertoken456'}).status_code == 200


def test_video_redirects_to_plugin_playback_url(client, autouse_settings, settings, monkeypatch):
    monkeypatch.setattr(server.plugin_manager, 'resolve_playback_source',
                        lambda query: {'url': 'https://cdn.example/ep.mp4'})
    response = client.get('/get_video.mp4?id=123', follow_redirects=False)
    assert response.status_code == 302
    assert response.headers['location'] == 'https://cdn.example/ep.mp4'


# ------------------------------------------------- video list + thumbnails

def test_video_list_empty_when_no_library(client, autouse_settings, monkeypatch, tmp_path):
    monkeypatch.setattr(server.Config, 'get_working_dir', lambda: str(tmp_path))
    response = client.get('/video_list.json')
    assert response.status_code == 200
    assert response.json() == {'videos': []}


def test_video_list_etag_round_trip(client, autouse_settings, monkeypatch, tmp_path):
    monkeypatch.setattr(server.Config, 'get_working_dir', lambda: str(tmp_path))
    (tmp_path / 'video_list.json').write_text(json.dumps({'videos': []}), encoding='utf-8')
    first = client.get('/video_list.json')
    assert first.status_code == 200
    assert first.headers['ETag']
    second = client.get('/video_list.json', headers={'If-None-Match': first.headers['ETag']})
    assert second.status_code == 304


def test_video_list_requires_login_when_configured(client, autouse_settings, settings, userdata):
    settings['dashboard']['online_watch_requires_login'] = True
    assert client.get('/video_list.json').status_code == 403


def test_thumbnail_serves_cached_file_with_etag(client, autouse_settings, monkeypatch, tmp_path):
    cached = tmp_path / 'thumb.jpg'
    cached.write_bytes(b'\xff\xd8fakejpeg')
    monkeypatch.setattr(server, '_thumbnail_cache_path', lambda sn: str(cached))
    response = client.get('/thumbnail.jpg?id=123')
    assert response.status_code == 200
    assert response.headers['Content-Type'].startswith('image/jpeg')
    assert response.headers['ETag']
    again = client.get('/thumbnail.jpg?id=123', headers={'If-None-Match': response.headers['ETag']})
    assert again.status_code == 304


def test_thumbnail_404_for_unknown_sn(client, autouse_settings, monkeypatch, tmp_path):
    monkeypatch.setattr(server, '_thumbnail_cache_path', lambda sn: str(tmp_path / 'no.jpg'))
    monkeypatch.setattr(server, '_find_video_entry', lambda sn: None)
    monkeypatch.setattr(server, '_hls_task', lambda sn: None)
    assert client.get('/thumbnail.jpg?id=123').status_code == 404
    assert client.get('/thumbnail.jpg?id=x').status_code == 400


# ------------------------------------------------- watch page + series

def test_watch_page_renders_with_bootstrap(client, autouse_settings):
    response = client.get('/watch')
    assert response.status_code == 200
    assert 'agp-watch-bootstrap' in response.text
    assert '"requestedVideoId": null' in response.text


def test_watch_page_requires_login_when_configured(client, autouse_settings, settings):
    settings['dashboard']['online_watch_requires_login'] = True
    response = client.get('/watch', follow_redirects=False)
    assert response.status_code == 302
    assert response.headers['location'].endswith('./login?error=2')


def test_watch_page_embeds_initial_video(client, autouse_settings, monkeypatch):
    entry = {'sn': '123', 'title': 't[1]', 'anime_name': 't', 'episode': '1',
             'resolution': 1080, 'path': '/x.mp4', 'source': 'src',
             'timestamp': 1, 'danmu': False}
    monkeypatch.setattr(server, '_find_video_entry', lambda sn: entry if str(sn) == '123' else None)
    response = client.get('/watch?id=123')
    assert response.status_code == 200
    assert '"requestedVideoId": "123"' in response.text
    assert '"initialVideoData"' in response.text


def test_anime_info_proxies_library_entries(client, autouse_settings, monkeypatch):
    monkeypatch.setattr(server, '_find_video_entry', lambda sn: {'sn': sn})
    monkeypatch.setattr(server, '_get_anime_info', lambda sn: {'video': {'title': 't'}})
    response = client.get('/anime_info?id=123')
    assert response.status_code == 200
    assert response.json() == {'video': {'title': 't'}}
    assert client.get('/anime_info?id=x').status_code == 400
    monkeypatch.setattr(server, '_find_video_entry', lambda sn: None)
    assert client.get('/anime_info?id=123').status_code == 404


def test_series_json_serves_groups(client, autouse_settings, monkeypatch):
    info = {'anime': {'title': 'show', 'episodes': {'1': [{'videoSn': '123', 'episode': '1'}]}},
            'video': {}}
    monkeypatch.setattr(server, '_find_video_entry', lambda sn: {'sn': sn})
    monkeypatch.setattr(server, '_local_episode_map',
                        lambda: {'123': {'sn': '123', 'resolution': 1080}})
    monkeypatch.setattr(server, '_get_anime_info', lambda sn: info)
    response = client.get('/watch/series.json?id=123')
    assert response.status_code == 200
    body = response.json()
    assert body['title'] == 'show'
    assert body['groups'][0]['episodes'][0]['local'] is True


# ------------------------------------------------- catalog

def test_catalog_index_and_search(client, autouse_settings, monkeypatch):
    payload = {'season': [], 'hot': [], 'newAdded': []}
    items = [{'animeSn': '1', 'title': 'Alpha'}, {'animeSn': '2', 'title': 'Beta show'}]
    monkeypatch.setattr(server, '_get_catalog_index', lambda: payload)
    monkeypatch.setattr(server, '_get_catalog_all', lambda: items)
    assert client.get('/catalog/index.json').status_code == 200
    searched = client.get('/catalog/all.json?q=beta').json()
    assert searched['total'] == 1 and searched['items'][0]['title'] == 'Beta show'
    paged = client.get('/catalog/all.json?page=1').json()
    assert paged['page'] == 1 and paged['total'] == 2


def test_catalog_requires_login_when_configured(client, autouse_settings, settings, userdata):
    settings['dashboard']['online_watch_requires_login'] = True
    assert client.get('/catalog/index.json').status_code == 403


def test_catalog_anime_detail(client, autouse_settings, monkeypatch):
    monkeypatch.setattr(server, '_catalog_knows', lambda sn: True)
    monkeypatch.setattr(server, '_resolve_video_sn', lambda sn: '123')
    monkeypatch.setattr(server, '_get_anime_info',
                        lambda sn: {'anime': {'title': 'show'}, 'video': {}})
    response = client.get('/catalog/anime.json?sn=7')
    assert response.status_code == 200
    assert response.json()['videoSn'] == '123'
    assert client.get('/catalog/anime.json?sn=x').status_code == 400


# ------------------------------------------------- HLS routes

HLS_SN = '48502'
KEY_URI = 'https://i2.bahamut.com.tw/JUMP/ani.php?sn=48502&key=abc'


def remote_playlist(count=5):
    lines = ['#EXTM3U', '#EXT-X-VERSION:3', '#EXT-X-TARGETDURATION:10',
             '#EXT-X-MEDIA-SEQUENCE:0', '#EXT-X-PLAYLIST-TYPE:VOD',
             '#EXT-X-KEY:METHOD=AES-128,URI="%s"' % KEY_URI]
    for index in range(count):
        lines.append('#EXTINF:10.000,')
        lines.append('media_b1500000_%d.ts' % index)
    lines.append('#EXT-X-ENDLIST')
    return '\n'.join(lines) + '\n'


@pytest.fixture
def hls_env(monkeypatch, autouse_settings, settings, tmp_path):
    settings['temp_dir'] = str(tmp_path)
    temp_dir = tmp_path / (HLS_SN + server.HLS_TEMP_SUFFIX)
    temp_dir.mkdir()
    monkeypatch.setattr(server, '_find_video_entry', lambda sn: None)
    server._hls_playlist_cache.clear()
    server.Config.tasks_progress_rate.clear()
    yield temp_dir
    server._hls_playlist_cache.clear()
    server.Config.tasks_progress_rate.clear()


def write_hls(temp_dir, text, chunks=(), key=True):
    (temp_dir / (HLS_SN + '.m3u8')).write_text(text, encoding='utf-8')
    for index in chunks:
        (temp_dir / ('media_b1500000_%d.ts' % index)).write_bytes(b'\0' * 2048)
    if key:
        (temp_dir / 'key.m3u8key').write_bytes(b'0123456789abcdef')


def test_hls_status_200_when_idle(client, hls_env):
    response = client.get('/hls/status.json?id=' + HLS_SN)
    assert response.status_code == 200
    assert response.json()['mode'] == 'none'
    assert response.headers['Cache-Control'] == 'no-store'


def test_hls_playlist_prefix_and_segment_and_key(client, hls_env):
    server.Config.tasks_progress_rate[int(HLS_SN)] = {
        'rate': 40.0, 'filename': 'x', 'status': 'downloading'}
    write_hls(hls_env, remote_playlist(5), chunks=(0, 1))
    playlist = client.get('/hls/playlist.m3u8?id=' + HLS_SN)
    assert playlist.status_code == 200
    assert playlist.headers['Content-Type'].startswith('application/vnd.apple.mpegurl')
    assert playlist.text.count('#EXTINF') == 2
    assert '#EXT-X-ENDLIST' not in playlist.text

    segment = client.get('/hls/segment.ts?id=%s&n=1' % HLS_SN)
    assert segment.status_code == 200
    assert segment.headers['Content-Type'].startswith('video/mp2t')
    assert len(segment.content) == 2048

    key = client.get('/hls/key.bin?id=' + HLS_SN)
    assert key.status_code == 200
    assert key.content == b'0123456789abcdef'

    assert client.get('/hls/segment.ts?id=%s&n=4' % HLS_SN).status_code == 404


def test_hls_rejects_bad_sn_and_index(client, hls_env):
    assert client.get('/hls/status.json?id=../../etc/passwd').status_code == 400
    assert client.get('/hls/playlist.m3u8').status_code == 400
    server.Config.tasks_progress_rate[int(HLS_SN)] = {
        'rate': 40.0, 'filename': 'x', 'status': 'downloading'}
    write_hls(hls_env, remote_playlist(5), chunks=(0, 1))
    assert client.get('/hls/segment.ts?id=%s&n=x' % HLS_SN).status_code == 400


# ------------------------------------------------- stream (proxy) routes

CHUNKLIST = '\n'.join([
    '#EXTM3U', '#EXT-X-VERSION:3', '#EXT-X-TARGETDURATION:10',
    '#EXT-X-KEY:METHOD=AES-128,URI="enc.key?sig=1"',
    '#EXTINF:10.0,', 'chunk_0.ts?sig=1',
    '#EXTINF:10.0,', 'chunk_1.ts?sig=1',
    '#EXT-X-ENDLIST', '',
])


class FakeUpstream:
    def __init__(self, content):
        self.status_code = 200
        self.content = content
        self.text = content.decode('utf-8', 'replace')

    def json(self):
        return json.loads(self.text)


@pytest.fixture
def stream_env(monkeypatch, autouse_settings, settings, userdata):
    monkeypatch.setattr(server, '_find_video_entry', lambda sn: {'sn': sn})
    monkeypatch.setattr(server, '_stream_dict', lambda sn: {'720': 'https://cdn.example/c.m3u8?sig=1'})
    monkeypatch.setattr(server, '_bahamut_get', lambda *a, **k: FakeUpstream(CHUNKLIST.encode()))
    server._stream_dict_cache.clear()
    server._stream_media_cache.clear()
    yield
    server._stream_dict_cache.clear()
    server._stream_media_cache.clear()


def test_stream_sources_playlist_key_segment(client, stream_env):
    sources = client.get('/stream/sources.json?id=123')
    assert sources.status_code == 200
    assert sources.json() == {'sn': '123', 'resolutions': [720]}

    playlist = client.get('/stream/playlist.m3u8?id=123&res=720')
    assert playlist.status_code == 200
    assert 'key.bin?id=123&res=720' in playlist.text
    assert playlist.text.rstrip().endswith('#EXT-X-ENDLIST')

    key = client.get('/stream/key.bin?id=123&res=720')
    assert key.status_code == 200

    segment = client.get('/stream/segment.ts?id=123&res=720&n=0')
    assert segment.status_code == 200
    assert segment.headers['Content-Type'].startswith('video/mp2t')

    assert client.get('/stream/playlist.m3u8?id=123&res=1080').status_code == 404
    assert client.get('/stream/playlist.m3u8?id=123').status_code == 400


# ------------------------------------------------- danmu + watch time

def test_danmu_disabled_message(client, autouse_settings):
    assert client.get('/get_danmu.ass?id=1').text == 'Danmu is not enabled'


def test_danmu_serves_existing_file(client, autouse_settings, settings, monkeypatch, tmp_path):
    settings['danmu'] = True
    ass = tmp_path / 'ep.ass'
    ass.write_text('[Events]', encoding='utf-8')
    monkeypatch.setattr(server, '_find_video_entry', lambda sn: None)
    monkeypatch.setattr(server.Config, 'getpath', lambda sn, kind: str(ass))
    assert client.get('/get_danmu.ass?id=1').status_code == 200


def test_watch_time_round_trip(client, autouse_settings, userdata):
    assert client.post('/watch/time', json={
        'type': 'set', 'sn': '123', 'time': 42, 'duration': 1400,
    }, cookies={'token': 'usertoken456'}).text == '{"status":"200"}'
    stored = client.get('/watch/time?type=get&sn=123', cookies={'token': 'usertoken456'}).json()
    assert stored['time'] == 42 and stored['duration'] == 1400
    assert client.post('/watch/time', json={'type': 'del', 'sn': '123'},
                       cookies={'token': 'usertoken456'}).text == '{"status":"200"}'
    assert client.get('/watch/time?type=get&sn=123',
                      cookies={'token': 'usertoken456'}).json() == {'time': 0, 'ended': False}


def test_watch_time_rejects_bad_token_and_time(client, autouse_settings, userdata):
    assert '403' in client.get('/watch/time?type=get&sn=123',
                               cookies={'token': 'nope'}).text
    bad = client.post('/watch/time', json={'type': 'set', 'sn': '123', 'time': 'soon'},
                      cookies={'token': 'usertoken456'})
    assert bad.status_code == 400


# ------------------------------------------------- login / register / users

def test_login_page_shows_error_copy(client, autouse_settings, settings):
    settings['dashboard']['user_control']['enabled'] = True
    response = client.get('/login?error=1')
    assert response.status_code == 200
    assert '錯誤的密碼' in response.text


def test_login_form_sets_cookies_and_migrates_legacy_password(
        client, autouse_settings, settings, userdata):
    settings['dashboard']['user_control']['enabled'] = True
    settings['dashboard']['online_watch'] = True
    response = client.post('/login', data={'username': 'tester', 'password': 'testerpw'},
                           follow_redirects=False)
    assert response.status_code == 302
    assert response.headers['location'].endswith('./watch')
    assert 'token=usertoken456' in response.headers.get('set-cookie', '')
    # Legacy plaintext is upgraded to a hash on success.
    assert 'password_hash' in userdata['users'][1]
    assert 'password' not in userdata['users'][1]


def test_login_json_body_and_failed_login(client, autouse_settings, settings, userdata):
    settings['dashboard']['user_control']['enabled'] = True
    response = client.post('/login', json={'username': 'tester', 'password': 'testerpw'},
                           follow_redirects=False)
    assert response.status_code == 302
    failed = client.post('/login', data={'username': 'tester', 'password': 'wrong'},
                         follow_redirects=False)
    assert failed.status_code == 302
    assert failed.headers['location'].endswith('./login?error=1')


def test_logout_clears_cookies(client, autouse_settings, settings):
    settings['dashboard']['user_control']['enabled'] = True
    response = client.get('/logout', follow_redirects=False)
    assert response.status_code == 302
    assert response.headers['location'].endswith('./login')


def test_register_flow(client, autouse_settings, settings, userdata):
    settings['dashboard']['user_control']['enabled'] = True
    # Disabled by default.
    assert '註冊功能未啟用' in client.post('/register').text
    settings['dashboard']['user_control']['allow_register'] = True
    assert client.get('/register').status_code == 200
    mismatch = client.post('/register', data={'username': 'newone', 'pw1': 'secret12', 'pw2': 'other12'},
                           follow_redirects=False)
    assert mismatch.headers['location'].endswith('./register?error=2')
    created = client.post('/register', data={'username': 'newone', 'pw1': 'secret12', 'pw2': 'secret12'},
                          follow_redirects=False)
    assert created.headers['location'].endswith('./login?error=3')
    assert any(u['username'] == 'newone' for u in userdata['users'])


def test_usermanage_json_and_add_delete(client, autouse_settings, settings, userdata):
    settings['dashboard']['user_control']['enabled'] = True
    admin = {'token': 'admintoken123'}
    listed = client.get('/usermanage?format=json', cookies=admin).json()
    assert listed['status'] == '200'
    assert {u['username'] for u in listed['users']} == {'admin', 'tester'}
    page = client.get('/usermanage', cookies=admin)
    assert page.status_code == 200
    assert 'tester' in page.text

    added = client.post('/usermanage', json={'action': 'add', 'username': 'extra',
                                             'password': 'extrapw1', 'role': 'user'},
                        cookies=admin).json()
    assert added['status'] == '200'
    # No self-delete.
    refused = client.post('/usermanage', json={'action': 'delete', 'username': 'admin'},
                          cookies=admin)
    assert refused.status_code == 403
    deleted = client.post('/usermanage', json={'action': 'delete', 'username': 'extra'},
                          cookies=admin).json()
    assert deleted['status'] == '200'


def test_userinfo_get_and_password_change(client, autouse_settings, settings, userdata):
    settings['dashboard']['user_control']['enabled'] = True
    user = {'token': 'usertoken456'}
    info_page = client.get('/userinfo', cookies=user)
    assert info_page.status_code == 200
    assert 'tester' in info_page.text
    fetched = client.post('/userinfo', json={'action': 'get'}, cookies=user).json()
    assert fetched['username'] == 'tester' and 'token' not in fetched

    wrong = client.post('/userinfo', json={'action': 'changepassword',
                                           'original_password': 'nope',
                                           'new_password1': 'x', 'new_password2': 'x'},
                        cookies=user)
    assert wrong.status_code == 403
    changed = client.post('/userinfo', json={'action': 'changepassword',
                                             'original_password': 'testerpw',
                                             'new_password1': 'newsecret1',
                                             'new_password2': 'newsecret1'},
                          cookies=user).json()
    assert changed['status'] == '200' and changed['logout'] is True


def test_password_hash_accepts_werkzeug_style_hashes():
    """Old userdata.json entries were written by werkzeug's generate_password_hash.

    werkzeug is gone, but those users must still log in. These vectors are built
    with plain hashlib (not via the server's own hasher) so they pin the parsing
    of werkzeug's ``pbkdf2:sha256:iters$salt$hash`` and ``scrypt:n:r:p$salt$hash``
    string formats rather than a round-trip.
    """
    import hashlib
    salt = b'\x01' * 16
    digest = hashlib.pbkdf2_hmac('sha256', b'secret12', salt, 1000)
    legacy_pbkdf2 = {'username': 'u', 'password_hash':
                     'pbkdf2:sha256:1000$%s$%s' % (salt.hex(), digest.hex())}
    assert server._verify_password(legacy_pbkdf2, 'secret12') is True
    assert server._verify_password(legacy_pbkdf2, 'wrong') is False

    scrypt_digest = hashlib.scrypt(b'secret12', salt=salt, n=2 ** 14, r=8, p=1, dklen=32)
    legacy_scrypt = {'username': 'u', 'password_hash':
                     'scrypt:16384:8:1$%s$%s' % (salt.hex(), scrypt_digest.hex())}
    assert server._verify_password(legacy_scrypt, 'secret12') is True
    assert server._verify_password(legacy_scrypt, 'wrong') is False

    fresh = server._hash_password('secret12')
    assert server._verify_password({'username': 'u', 'password_hash': fresh}, 'secret12') is True


# ------------------------------------------------- admin actions

def test_manual_task_queues_cui_thread(client, autouse_settings, settings, userdata, monkeypatch):
    settings['dashboard']['user_control']['enabled'] = True
    calls = []
    monkeypatch.setattr(server, 'cui', lambda *a, **k: calls.append((a, k)))
    response = client.post('/manualTask', json={
        'sn': '123', 'resolution': '720', 'mode': 'single',
        'thread': 1, 'classify': True, 'danmu': False,
    }, cookies={'token': 'admintoken123'})
    assert response.text == '{"status":"200"}'
    deadline = time.time() + 5
    while not calls and time.time() < deadline:
        time.sleep(0.05)
    assert calls and calls[0][0][0] == '123'


def test_upload_config_and_sn_list(client, autouse_settings, settings, userdata, monkeypatch):
    settings['dashboard']['user_control']['enabled'] = True
    written = {}
    monkeypatch.setattr(server.Config, 'write_settings', lambda cfg: written.update(cfg))
    payload = {}
    for key in server.id_list:
        if key == 'browser_fingerprint':
            payload['browser_fingerprint_ja3'] = 'j'
            payload['browser_fingerprint_akamai'] = 'a'
        else:
            payload[key] = settings[key]
    response = client.post('/uploadConfig', json=payload, cookies={'token': 'admintoken123'})
    assert response.text == '{"status":"200"}'
    assert written['download_resolution'] == '1080'

    sn_written = {}
    monkeypatch.setattr(server.Config, 'write_sn_list', lambda content: sn_written.setdefault('c', content))
    assert client.post('/sn_list', content='111 all', cookies={'token': 'admintoken123'}).text == \
        '{"status":"200"}'
    assert sn_written['c'] == '111 all'
    assert client.get('/data/sn_list', cookies={'token': 'admintoken123'}).status_code == 200


def test_checknow_and_console_command(client, autouse_settings, settings, userdata, monkeypatch):
    settings['dashboard']['user_control']['enabled'] = True
    admin = {'token': 'admintoken123'}
    triggered = []
    monkeypatch.setattr(server, 'checknow', lambda: triggered.append(True))
    assert client.get('/checknow', cookies=admin).text == '{"status":"200"}'
    assert triggered == [True]

    monkeypatch.setattr(server, 'command_handler',
                        lambda raw, show_detail=True: {'success': True, 'message': 'ok:' + raw})
    answered = client.post('/console/command', json={'command': 'help'}, cookies=admin)
    assert answered.status_code == 200
    assert answered.json()['message'] == 'ok:help'
    assert client.post('/console/command', json={'command': ''}, cookies=admin).status_code == 400

    monkeypatch.setattr(server, 'command_handler', None)
    assert client.post('/console/command', json={'command': 'help'}, cookies=admin).status_code == 503


def test_get_token_rotates(client, autouse_settings, settings, userdata):
    settings['dashboard']['user_control']['enabled'] = True
    admin = {'token': 'admintoken123'}
    first = client.get('/data/get_token', cookies=admin).json()
    second = client.get('/data/get_token', cookies=admin).json()
    assert first['legacy'] is True and second['legacy'] is True
    assert first['token'] != second['token']


# ------------------------------------------------- websocket progress

def test_tasks_progress_plain_http_needs_upgrade(client):
    response = client.get('/data/tasks_progress')
    assert response.status_code == 400
    assert response.json() == {'success': False, 'message': 'websocket required'}


def test_tasks_progress_streams_json_over_websocket(client, autouse_settings):
    server.Config.tasks_progress_rate.clear()
    server.Config.tasks_progress_rate[7] = {'rate': 1.0}
    try:
        with client.websocket_connect('/data/tasks_progress') as websocket:
            payload = json.loads(websocket.receive_text())
        assert payload['7']['rate'] == 1.0
    finally:
        server.Config.tasks_progress_rate.clear()


def test_tasks_progress_websocket_checks_admin_cookie(client, autouse_settings, settings, userdata):
    from starlette.websockets import WebSocketDisconnect
    settings['dashboard']['user_control']['enabled'] = True
    auth_client(client, 'admintoken123')
    with client.websocket_connect('/data/tasks_progress') as websocket:
        # The client cookie jar carries the admin token into the handshake.
        websocket.receive_text()
    client.cookies.clear()
    with pytest.raises(Exception):
        with client.websocket_connect('/data/tasks_progress') as websocket:
            websocket.receive_text()
    with pytest.raises(Exception):
        auth_client(client, 'usertoken456')
        with client.websocket_connect('/data/tasks_progress') as websocket:
            websocket.receive_text()


# ------------------------------------------------- run() entry point

def test_run_starts_uvicorn_with_configured_host_port(monkeypatch, tmp_path):
    settings = make_settings()
    monkeypatch.setattr(server.Config, 'read_settings', lambda *a, **k: settings)
    monkeypatch.setattr(server.Config, 'get_working_dir', lambda: str(tmp_path))
    calls = {}
    monkeypatch.setattr(server.uvicorn, 'run',
                        lambda *a, **k: calls.setdefault('args', (a, k)))
    server.run()
    assert calls['args'][1]['host'] == '127.0.0.1'
    assert calls['args'][1]['port'] == 5000
    assert 'ssl_certfile' not in calls['args'][1]


def test_run_disables_ssl_when_certs_are_missing(monkeypatch, tmp_path):
    settings = make_settings()
    settings['dashboard']['SSL'] = True
    monkeypatch.setattr(server.Config, 'read_settings', lambda *a, **k: settings)
    monkeypatch.setattr(server.Config, 'get_working_dir', lambda: str(tmp_path))
    calls = {}
    monkeypatch.setattr(server.uvicorn, 'run',
                        lambda *a, **k: calls.setdefault('args', (a, k)))
    server.run()
    assert settings['dashboard']['SSL'] is False
    assert 'ssl_certfile' not in calls['args'][1]
