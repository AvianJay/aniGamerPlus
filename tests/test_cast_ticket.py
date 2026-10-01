"""投放票: 讓 Chromecast / Apple TV 不靠 cookie 也拿得到片子.

電視那一頭只有一條網址. 這裡釘住的是那條網址上的 ``ct``: 只認一集、會過期、
簽名跟著帳號的 token 走; HLS 清單裡的分片與金鑰要帶著同一張票; 而且只有票驗
過的請求才拿得到 CORS 標頭 (Chromecast 的接收器用 XHR 抓 HLS).
"""

import time

import pytest

from fastapi.testclient import TestClient

import Dashboard.Server as server
from aniGamerPlus import Config

from test_fastapi_server import make_settings, make_userdata
from test_hls_playlist import SN, remote_playlist, write_chunks, write_playlist


USER_TOKEN = 'usertoken456'


@pytest.fixture
def settings(monkeypatch, tmp_path):
    current = make_settings()
    current['temp_dir'] = str(tmp_path)
    current['dashboard']['online_watch_requires_login'] = True
    monkeypatch.setattr(server, '_get_current_settings', lambda: current)
    monkeypatch.setattr(server, '_hls_settings', lambda: current)
    monkeypatch.setattr(server.Config, 'read_settings', lambda *a, **k: current)
    return current


@pytest.fixture
def userdata(monkeypatch):
    data = make_userdata()
    monkeypatch.setattr(server, 'load_user_data', lambda: data)
    return data


@pytest.fixture
def client():
    return TestClient(server.app, raise_server_exceptions=True)


@pytest.fixture
def video_file(monkeypatch, tmp_path):
    path = tmp_path / 'episode[1080P].mp4'
    path.write_bytes(b'\0' * 1024)
    monkeypatch.setattr(server, '_find_video_path', lambda sn, res=None: str(path))
    return str(path)


@pytest.fixture
def streaming(monkeypatch, tmp_path):
    """一集正在邊看邊下載, 已經落地兩片."""
    monkeypatch.setattr(server, '_find_video_entry', lambda sn: None)
    temp_dir = tmp_path / (SN + server.HLS_TEMP_SUFFIX)
    temp_dir.mkdir()
    server._hls_playlist_cache.clear()
    Config.tasks_progress_rate[int(SN)] = {
        'rate': 40.0, 'filename': '《x》', 'status': '正在下載'}
    write_playlist(temp_dir, remote_playlist(5))
    write_chunks(temp_dir, [0, 1])
    with open(str(temp_dir / 'key.m3u8key'), 'wb') as f:
        f.write(b'0123456789abcdef')
    yield temp_dir
    Config.tasks_progress_rate.pop(int(SN), None)
    server._hls_playlist_cache.clear()


def ticket_for(client, sn, token=USER_TOKEN):
    response = client.get('/cast/ticket?id=%s' % sn, cookies={'token': token})
    assert response.status_code == 200
    assert response.headers['Cache-Control'] == 'no-store'
    return response.json()['ticket']


# ------------------------------------------------------------------ 發票

def test_ticket_needs_a_login_when_the_library_does(client, settings, userdata):
    assert client.get('/cast/ticket?id=123').status_code == 403
    assert client.get('/cast/ticket?id=123', cookies={'token': 'nope'}).status_code == 403


def test_ticket_rejects_a_non_numeric_sn(client, settings, userdata):
    response = client.get('/cast/ticket?id=../x', cookies={'token': USER_TOKEN})
    assert response.status_code == 400


def test_ticket_never_carries_the_token_itself(client, settings, userdata):
    ticket = ticket_for(client, '123')
    assert USER_TOKEN not in ticket
    assert server._cast_ticket_user(ticket, '123')['username'] == 'tester'


def test_open_library_hands_out_the_open_ticket(client, settings, userdata):
    settings['dashboard']['online_watch_requires_login'] = False
    response = client.get('/cast/ticket?id=123')
    assert response.status_code == 200
    assert response.json()['ticket'] == server.CAST_TICKET_OPEN


def test_ticket_route_follows_the_online_watch_switch(client, settings, userdata):
    settings['dashboard']['online_watch'] = False
    assert client.get('/cast/ticket?id=123', cookies={'token': USER_TOKEN}).status_code == 404


# ------------------------------------------------------------------ 驗票

def test_ticket_opens_the_video_without_a_cookie(client, settings, userdata, video_file):
    ticket = ticket_for(client, '123')
    client.cookies.clear()
    response = client.get('/get_video.mp4?id=123&ct=' + ticket)
    assert response.status_code == 200
    assert response.headers['Access-Control-Allow-Origin'] == '*'


def test_ticket_only_opens_its_own_episode(client, settings, userdata, video_file):
    ticket = ticket_for(client, '123')
    client.cookies.clear()
    assert client.get('/get_video.mp4?id=124&ct=' + ticket).status_code == 403


def test_tampered_ticket_is_refused(client, settings, userdata, video_file):
    expires, tag, signature = ticket_for(client, '123').split('.')
    client.cookies.clear()
    longer = '%d.%s.%s' % (int(expires) + 3600, tag, signature)
    assert client.get('/get_video.mp4?id=123&ct=' + longer).status_code == 403
    assert client.get('/get_video.mp4?id=123&ct=garbage').status_code == 403
    assert client.get('/get_video.mp4?id=123&ct=' + server.CAST_TICKET_OPEN).status_code == 403


def test_expired_ticket_is_refused(settings, userdata):
    issued = server._issue_cast_ticket('123', userdata['users'][1],
                                       now=time.time() - server.CAST_TICKET_TTL - 5)
    assert server._cast_ticket_user(issued, '123') is None


def test_ticket_dies_with_the_token(client, settings, userdata, video_file):
    ticket = ticket_for(client, '123')
    userdata['users'][1]['token'] = 'rotated'
    client.cookies.clear()
    assert client.get('/get_video.mp4?id=123&ct=' + ticket).status_code == 403


def test_cookie_requests_get_no_cors_headers(client, settings, userdata, video_file):
    response = client.get('/get_video.mp4?id=123', cookies={'token': USER_TOKEN})
    assert response.status_code == 200
    assert 'Access-Control-Allow-Origin' not in response.headers


def test_open_library_marks_cast_requests_for_cors(client, settings, userdata, video_file):
    settings['dashboard']['online_watch_requires_login'] = False
    plain = client.get('/get_video.mp4?id=123')
    assert 'Access-Control-Allow-Origin' not in plain.headers
    cast = client.get('/get_video.mp4?id=123&ct=' + server.CAST_TICKET_OPEN)
    assert cast.headers['Access-Control-Allow-Origin'] == '*'


# ------------------------------------------------------------------ HLS

def test_hls_playlist_passes_the_ticket_to_segments_and_key(client, settings, userdata,
                                                            streaming):
    ticket = ticket_for(client, SN)
    client.cookies.clear()
    response = client.get('/hls/playlist.m3u8?id=%s&ct=%s' % (SN, ticket))
    assert response.status_code == 200
    assert response.headers['Access-Control-Allow-Origin'] == '*'
    body = response.text
    assert 'URI="key.bin?id=%s&ct=%s"' % (SN, ticket) in body
    assert 'segment.ts?id=%s&n=0&ct=%s' % (SN, ticket) in body
    assert 'segment.ts?id=%s&n=1&ct=%s' % (SN, ticket) in body

    segment = client.get('/hls/segment.ts?id=%s&n=1&ct=%s' % (SN, ticket))
    assert segment.status_code == 200
    assert segment.headers['Access-Control-Allow-Origin'] == '*'
    key = client.get('/hls/key.bin?id=%s&ct=%s' % (SN, ticket))
    assert key.content == b'0123456789abcdef'


def test_hls_playlist_without_a_ticket_stays_unchanged(client, settings, userdata, streaming):
    response = client.get('/hls/playlist.m3u8?id=' + SN, cookies={'token': USER_TOKEN})
    assert response.status_code == 200
    assert 'ct=' not in response.text
    assert 'Access-Control-Allow-Origin' not in response.headers


def test_hls_segments_refuse_a_ticket_for_another_episode(client, settings, userdata,
                                                          streaming):
    ticket = ticket_for(client, '1')
    client.cookies.clear()
    assert client.get('/hls/segment.ts?id=%s&n=0&ct=%s' % (SN, ticket)).status_code == 403


def test_stream_render_passes_the_ticket_along():
    parsed = server._stream_parse_media(remote_playlist(2))
    body = server._stream_render('123', '720', parsed, ticket='1.ab.cd')
    assert 'URI="key.bin?id=123&res=720&ct=1.ab.cd"' in body
    assert 'segment.ts?id=123&res=720&n=1&ct=1.ab.cd' in body
    assert 'ct=' not in server._stream_render('123', '720', parsed)
