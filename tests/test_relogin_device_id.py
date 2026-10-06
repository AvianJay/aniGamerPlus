# -*- coding: utf-8 -*-
"""自動登入完的第一集不可以被打 code=1007 裝置驗證異常.

cookie 失效時, 是正在解析的那一集在 Anime.__request 裡收到 cookie 重置
(set-cookie: BAHARUNE=deleted), 當場自動登入換一份新 cookie. 舊寫法換完 cookie 之後,
把「帶著被拒絕的舊 cookie 換來的回應」原樣交回去: 在 getdeviceid.php 上那就是一個
不屬於新登入的 deviceid, 新登入拿它去 token.php 要 token → 1007, 這一集陪葬.
排在後面的集數是登入之後才建立的 Anime, 從頭到尾都是新登入, 所以都正常.
"""

import os
import sys
import types
from urllib.parse import parse_qs, urlparse

import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

for _name in ('pip_system_certs', 'pip_system_certs.wrapt_requests', 'selenium_recaptcha_solver'):
    if _name not in sys.modules:
        _stub = types.ModuleType(_name)
        if _name == 'selenium_recaptcha_solver':
            _stub.RecaptchaSolver = object
            _stub.StandardDelayConfig = object
        sys.modules[_name] = _stub

anime_module = pytest.importorskip('Anime')
Config = anime_module.Config

OLD_UA = 'Mozilla/5.0 舊設定的 UA'
NEW_UA = 'Mozilla/5.0 自動登入那個瀏覽器的 UA'
PLAYLIST = 'https://bahamut.akamaized.net/test/playlist_advance.m3u8'
CHUNKLIST = 'https://bahamut.akamaized.net/test/chunklist_b1.m3u8'


class FakeResponse:
    def __init__(self, body=None, reset=False, content=b''):
        self._body = body if body is not None else {}
        self.headers = {}
        if reset:
            self.headers['set-cookie'] = 'BAHARUNE=deleted; expires=Thu, 01-Jan-1970 00:00:01 GMT; Max-Age=0'
        self.content = content

    def json(self):
        return self._body


class FakeBahamut:
    """失效的 BAHARUNE 一律回 cookie 重置; deviceid 是哪一份登入拿的, 就只有那一份登入能拿它要 token."""

    def __init__(self, deviceid_checks_login):
        self.dead_tokens = {'old'}
        self.deviceid_checks_login = deviceid_checks_login  # False: getdeviceid.php 不驗登入, 到 token.php 才重置
        self.devices = {}  # deviceid -> 拿到它的 BAHARUNE
        self.calls = []  # (路徑, BAHARUNE, User-Agent)

    def get(self, url, headers=None, cookies=None, **kwargs):
        parsed = urlparse(url)
        token = (cookies or {}).get('BAHARUNE')
        self.calls.append((parsed.path, token, (headers or {}).get('User-Agent')))
        dead = token in self.dead_tokens

        if parsed.path.endswith('getdeviceid.php'):
            deviceid = 'dev%d' % len(self.devices)
            self.devices[deviceid] = token
            return FakeResponse({'deviceid': deviceid}, reset=dead and self.deviceid_checks_login)
        if parsed.path.endswith('token.php'):
            device = parse_qs(parsed.query)['device'][0]
            if dead or self.devices.get(device) != token:
                return FakeResponse({'error': {'code': 1007, 'message': '裝置驗證異常！'}}, reset=dead)
            return FakeResponse({'vip': True, 'time': 1})
        if parsed.path.endswith('video_src.php'):
            return FakeResponse({'data': {'srcUseCases': [{'src': {'playlist': PLAYLIST}}]}})
        if url == PLAYLIST:
            return FakeResponse(content=b'#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1,RESOLUTION=1920x1080\n'
                                        b'chunklist_b1.m3u8\n')
        return FakeResponse(reset=dead)


class FakeSession:
    def __init__(self, server):
        self._server = server
        self.cookies = {}

    def get(self, url, **kwargs):
        return self._server.get(url, **kwargs)


def _settings(ua):
    return {
        'working_dir': '.', 'bangumi_dir': '.', 'temp_dir': '.',
        'ua': ua, 'browser_fingerprint': {'ja3': '', 'akamai': ''},
        'use_mobile_api': False, 'use_proxy': False, 'only_use_vip': False,
        'ads_time': 25, 'mobile_ads_time': 3, 'download_resolution': '1080',
    }


@pytest.fixture
def expired_login(monkeypatch):
    """cookie.txt 裡的登入已經失效、開了自動登入. 回傳一個建立 Anime 的函式."""
    state = types.SimpleNamespace(cookie={'BAHAID': 'tester', 'BAHARUNE': 'old'}, ua=OLD_UA, logins=0, server=None)

    def auto_login():
        # Config.invalid_cookie() 的自動登入: 拿到新 cookie, Loginer 也順手把 UA 換成登入用的那個瀏覽器
        state.logins += 1
        state.cookie = {'BAHAID': 'tester', 'BAHARUNE': 'new'}
        state.ua = NEW_UA
        return True

    monkeypatch.setattr(Config, 'read_settings', lambda *a, **k: _settings(state.ua))
    monkeypatch.setattr(Config, 'read_cookie', lambda *a, **k: dict(state.cookie))
    monkeypatch.setattr(Config, 'invalid_cookie', auto_login)
    monkeypatch.setattr(Config, 'get_cookie_time', lambda: '2026-10-06 14:57:08')
    monkeypatch.setattr(Config, 'renew_cookies', lambda *a, **k: None)
    monkeypatch.setattr(Config, 'write_settings', lambda *a, **k: None)
    monkeypatch.setattr(anime_module, 'err_print', lambda *a, **k: None)
    monkeypatch.setattr(anime_module.time, 'sleep', lambda seconds: None)
    monkeypatch.setattr(anime_module.requests, 'session', lambda: FakeSession(state.server))
    monkeypatch.setattr(anime_module.curl_requests, 'Session', lambda *a, **k: FakeSession(state.server))

    def make(deviceid_checks_login=True):
        state.server = FakeBahamut(deviceid_checks_login)
        anime = anime_module.Anime(51813, debug_mode=True)  # 不連網, header 自己補
        anime._Anime__init_header()
        anime._title = '學生會也有洞！ [1]'
        return anime, state

    return make


def _assert_parsed_with_new_login(anime, state):
    assert state.logins == 1
    assert anime._m3u8_dict == {'1080': CHUNKLIST}
    after_login = [ua for _, token, ua in state.server.calls if token == 'new']
    assert after_login and set(after_login) == {NEW_UA}, '換了登入卻還頂著舊的 UA'


def test_first_episode_after_auto_login_gets_a_device_id_from_the_new_login(expired_login):
    """getdeviceid.php 收到 cookie 重置 → 自動登入 → deviceid 要用新登入重拿."""
    anime, state = expired_login()

    anime._Anime__get_m3u8_dict()  # 舊寫法在這裡 sys.exit(1): 收到錯誤 code=1007 裝置驗證異常！

    _assert_parsed_with_new_login(anime, state)


def test_device_id_is_fetched_again_when_login_changes_while_asking_for_token(expired_login):
    """getdeviceid.php 沒驗登入、到 token.php 才收到重置: 手上的 deviceid 是舊登入的, 也要重拿."""
    anime, state = expired_login(deviceid_checks_login=False)

    anime._Anime__get_m3u8_dict()

    _assert_parsed_with_new_login(anime, state)
