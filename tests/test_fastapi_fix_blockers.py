"""Focused regression tests for the three FastAPI migration blockers.

Run with::

    PYTHONPATH=/tmp/agp_testdeps python3 -m pytest tests/test_fastapi_fix_blockers.py --noconftest -q
"""

import asyncio
import copy
import threading

import Dashboard.Server as server
import Loginer
from fastapi.testclient import TestClient


# ------------------------------------------------------------------ fixtures

def make_settings(**over):
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
                'default_user': [],
            },
        },
    }
    settings.update(over)
    return settings


def make_userdata():
    return {"users": [
        {'username': 'admin', 'password': 'adminpw', 'token': 'admintoken123',
         'videotimes': {}, 'role': 'admin'},
        {'username': 'tester', 'password': 'testerpw', 'token': 'usertoken456',
         'videotimes': {}, 'role': 'user'},
    ]}


import pytest


@pytest.fixture
def settings():
    return make_settings()


@pytest.fixture
def autouse_settings(monkeypatch, settings):
    monkeypatch.setattr(server, '_get_current_settings', lambda: settings)
    monkeypatch.setattr(server, '_sync_plugin_manager', lambda force=False: settings)
    monkeypatch.setattr(server.Config, 'read_settings', lambda *a, **k: settings)
    return settings


@pytest.fixture
def userdata(monkeypatch):
    data = make_userdata()
    saved = {}

    def fake_save(new_data):
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


# ---------------------------------------- Security review regression coverage

def test_request_body_larger_than_global_limit_is_rejected(client):
    payload = b'x' * (server.MAX_REQUEST_BODY_BYTES + 1)
    response = client.post('/login', content=payload,
                           headers={'content-type': 'application/json'})
    assert response.status_code == 413


@pytest.mark.parametrize('path', [
    '/uploadConfig',
    '/manualTask',
    '/console/command',
])
def test_admin_json_routes_authenticate_before_parsing_body(
        path, client, autouse_settings, settings, userdata, monkeypatch):
    settings['dashboard']['user_control']['enabled'] = True
    calls = 0

    async def forbidden_json(_request):
        nonlocal calls
        calls += 1
        return {}

    monkeypatch.setattr(server.Request, 'json', forbidden_json)
    response = client.post(path, content=b'{}',
                           headers={'content-type': 'application/json'})
    assert response.status_code == 401
    assert calls == 0


def test_sn_list_authenticates_before_reading_raw_body(
        client, autouse_settings, settings, userdata, monkeypatch):
    settings['dashboard']['user_control']['enabled'] = True
    calls = 0

    async def forbidden_body(_request):
        nonlocal calls
        calls += 1
        return b''

    monkeypatch.setattr(server.Request, 'body', forbidden_body)
    response = client.post('/sn_list', content=b'123')
    assert response.status_code == 401
    assert calls == 0


@pytest.mark.parametrize('path, parser_name, expected_status', [
    ('/usermanage', '_form_or_json', 302),
    ('/userinfo', '_form_or_json', 302),
    ('/watch/time', '_json_then_form', 200),
])
def test_user_routes_authenticate_before_parsing_body(
        path, parser_name, expected_status, client, autouse_settings, settings,
        userdata, monkeypatch):
    settings['dashboard']['user_control']['enabled'] = True
    calls = 0

    async def forbidden_parser(_request):
        nonlocal calls
        calls += 1
        return {}

    monkeypatch.setattr(server, parser_name, forbidden_parser)
    response = client.post(path, content=b'{}',
                           headers={'content-type': 'application/json'},
                           follow_redirects=False)
    assert response.status_code == expected_status
    assert calls == 0


def test_headless_chrome_keeps_sandbox_by_default(monkeypatch):
    monkeypatch.delenv('AGP_CHROME_NO_SANDBOX', raising=False)
    monkeypatch.setattr(Loginer.Config, 'read_settings',
                        lambda: {'auto_login': {'use_wdm': False}})
    monkeypatch.setattr(Loginer.webdriver, 'Chrome',
                        lambda *, options: options)

    options = Loginer.get_driver(headless=True)

    assert '--no-sandbox' not in options.arguments


def test_headless_chrome_allows_explicit_no_sandbox_opt_in(monkeypatch):
    monkeypatch.setenv('AGP_CHROME_NO_SANDBOX', '1')
    monkeypatch.setattr(Loginer.Config, 'read_settings',
                        lambda: {'auto_login': {'use_wdm': False}})
    monkeypatch.setattr(Loginer.webdriver, 'Chrome',
                        lambda *, options: options)

    options = Loginer.get_driver(headless=True)

    assert '--no-sandbox' in options.arguments


@pytest.fixture
def hundred_byte_video(tmp_path, monkeypatch, autouse_settings):
    path = tmp_path / 'ep.mp4'
    path.write_bytes(b'0123456789' * 10)  # 100 bytes
    monkeypatch.setattr(server, '_find_video_path', lambda sn, res=None: str(path))
    return str(path)


# ------------------------------------------------- Blocker 1: werkzeug hashes

# Fixed vectors matching actual Werkzeug output semantics: the salt is a
# literal ASCII string and the digest is computed over salt.encode(),
# for both pbkdf2 and scrypt. Computed once with plain hashlib (never via
# the production hasher) and then hardcoded.
WERKZEUG_PBKDF2 = (
    'pbkdf2:sha256:1000$wX7aQ9mB2cDeFgH1$'
    '50c22dfbc508331654c5fc3ce0726db8d9a7767bcee02567c6368e136983193e'
)
WERKZEUG_PBKDF2_PASSWORD = 'secret12'

WERKZEUG_SCRYPT = (
    'scrypt:16384:8:1$sAltNaCl12345678$'
    '497ca9465d4633dc320d714a918d3764baf201e2a45fdf2a66e6d71a1a947779'
)
WERKZEUG_SCRYPT_PASSWORD = 'secret12'

# Real Werkzeug 3.1.3 default scrypt vector (generate_password_hash(...,
# method='scrypt') -> 'scrypt:32768:8:1$...'). Derived once with plain
# hashlib.scrypt(..., maxmem=132*n*r*p) exactly as Werkzeug's
# security._hash_internal does, then cross-checked with Werkzeug 3.1.3
# check_password_hash (True for the right password, False otherwise) --
# never via the production hasher. The salt is plain non-hex ASCII so the
# ASCII (not hex-fallback) path is exercised. Without maxmem, OpenSSL
# rejects these parameters ("memory limit exceeded"), so this test fails
# before the production fix and passes after it.
WERKZEUG_SCRYPT_DEFAULT = (
    'scrypt:32768:8:1$T3stSAltWerkzeug!$'
    'd7252f01e126111f87614f6d0c3fef884c2325a177e7984f10333e41ad79064a831d'
    '982a85e54407ce0e903a91365af3d4f84d4bae338ca8450e5ca1fb44a372'
)
WERKZEUG_SCRYPT_DEFAULT_PASSWORD = 'migration-test-password'

# A hash written by the migrated code (hex salt, digest over
# bytes.fromhex(salt)). Must keep verifying after the fix.
MIGRATED_PBKDF2 = (
    'pbkdf2:sha256:260000$9f3a4c1d7e2b4865a1c8f0d3e5b7a9c1$'
    '4dfbf22a861c02e005caba4cf7ee21be5286dd519386f21eb5ab9f4ddc403a96'
)
MIGRATED_PBKDF2_PASSWORD = 'secret12'


def test_werkzeug_pbkdf2_ascii_salt_verifies():
    user = {'username': 'u', 'password_hash': WERKZEUG_PBKDF2}
    assert server._verify_password(user, WERKZEUG_PBKDF2_PASSWORD) is True
    assert server._verify_password(user, 'wrong-password') is False


def test_werkzeug_scrypt_ascii_salt_verifies():
    user = {'username': 'u', 'password_hash': WERKZEUG_SCRYPT}
    assert server._verify_password(user, WERKZEUG_SCRYPT_PASSWORD) is True
    assert server._verify_password(user, 'wrong-password') is False


def test_werkzeug_scrypt_default_params_verifies():
    user = {'username': 'u', 'password_hash': WERKZEUG_SCRYPT_DEFAULT}
    assert server._verify_password(user, WERKZEUG_SCRYPT_DEFAULT_PASSWORD) is True
    assert server._verify_password(user, 'wrong-password') is False


def test_scrypt_malformed_params_return_false():
    # Malformed or absurd scrypt parameters must return False cleanly --
    # no exception, no unbounded memory allocation.
    assert server._check_hash('scrypt:0:8:1$salt$00', 'x') is False
    assert server._check_hash('scrypt:-1:8:1$salt$00', 'x') is False
    assert server._check_hash('scrypt:notanint:8:1$salt$00', 'x') is False
    assert server._check_hash('scrypt:32768:8$x', 'x') is False
    assert server._check_hash('scrypt:1073741824:8:1$salt$00', 'x') is False
    assert server._check_hash('notahash', 'x') is False


def test_migrated_hex_hash_still_verifies():
    user = {'username': 'u', 'password_hash': MIGRATED_PBKDF2}
    assert server._verify_password(user, MIGRATED_PBKDF2_PASSWORD) is True
    assert server._verify_password(user, 'wrong-password') is False


def test_new_hash_uses_canonical_werkzeug_compatible_format():
    import hashlib
    fresh = server._hash_password('secret12')
    method, _, rest = fresh.partition('$')
    salt, _, expected = rest.partition('$')
    assert method.startswith('pbkdf2:sha256:')
    # Canonical format: digest over the literal ASCII salt bytes.
    recomputed = hashlib.pbkdf2_hmac(
        'sha256', b'secret12', salt.encode('utf-8'),
        int(method.rsplit(':', 1)[1])).hex()
    assert recomputed == expected
    assert server._verify_password(
        {'username': 'u', 'password_hash': fresh}, 'secret12') is True
    assert server._verify_password(
        {'username': 'u', 'password_hash': fresh}, 'wrong') is False


# ------------------------------------------------- Blocker 2: Range handling

def test_range_start_at_size_is_416(hundred_byte_video, client):
    r = client.get('/get_video.mp4?id=1', headers={'Range': 'bytes=100-'})
    assert r.status_code == 416
    assert r.headers['Content-Range'] == 'bytes */100'


def test_range_reversed_is_416(hundred_byte_video, client):
    r = client.get('/get_video.mp4?id=1', headers={'Range': 'bytes=99-0'})
    assert r.status_code == 416
    assert r.headers['Content-Range'] == 'bytes */100'


def test_range_end_clamped(hundred_byte_video, client):
    r = client.get('/get_video.mp4?id=1', headers={'Range': 'bytes=0-999'})
    assert r.status_code == 206
    assert r.headers['Content-Range'] == 'bytes 0-99/100'
    assert r.headers['Content-Length'] == '100'
    assert len(r.content) == 100


def test_range_malformed_is_416(hundred_byte_video, client):
    for bad in ('garbage', 'bytes=abc', 'bytes=', 'bytes=--', 'bytes 0-10'):
        r = client.get('/get_video.mp4?id=1', headers={'Range': bad})
        assert r.status_code == 416, bad
        assert r.headers['Content-Range'] == 'bytes */100', bad


def test_range_multiple_is_416(hundred_byte_video, client):
    r = client.get('/get_video.mp4?id=1',
                   headers={'Range': 'bytes=0-10,20-30'})
    assert r.status_code == 416
    assert r.headers['Content-Range'] == 'bytes */100'


def test_range_suffix_valid(hundred_byte_video, client):
    r = client.get('/get_video.mp4?id=1', headers={'Range': 'bytes=-10'})
    assert r.status_code == 206
    assert r.headers['Content-Range'] == 'bytes 90-99/100'
    assert r.content == (b'0123456789' * 10)[-10:]


def test_range_head_returns_same_headers_no_body(hundred_byte_video, client):
    get = client.get('/get_video.mp4?id=1', headers={'Range': 'bytes=0-9'})
    head = client.request('HEAD', '/get_video.mp4?id=1',
                          headers={'Range': 'bytes=0-9'})
    assert get.status_code == 206
    assert head.status_code == 206
    assert head.content == b''
    assert head.headers['Content-Range'] == get.headers['Content-Range']
    assert head.headers['Content-Length'] == get.headers['Content-Length']

    bad_head = client.request('HEAD', '/get_video.mp4?id=1',
                              headers={'Range': 'bytes=100-'})
    assert bad_head.status_code == 416
    assert bad_head.content == b''
    assert bad_head.headers['Content-Range'] == 'bytes */100'


def test_range_valid_fixed_and_open_ended(hundred_byte_video, client):
    fixed = client.get('/get_video.mp4?id=1', headers={'Range': 'bytes=0-9'})
    assert fixed.status_code == 206
    assert fixed.headers['Content-Range'] == 'bytes 0-9/100'
    assert len(fixed.content) == 10

    open_ended = client.get('/get_video.mp4?id=1',
                            headers={'Range': 'bytes=90-'})
    assert open_ended.status_code == 206
    assert open_ended.headers['Content-Range'] == 'bytes 90-99/100'
    assert len(open_ended.content) == 10


# ------------------------------------------------- Blocker 3: off event loop

def _wrap_to_record(monkeypatch, target, record, call_original=True):
    """Wrap target so calls record whether an event loop runs in that thread."""
    if isinstance(target, str):
        owner_name, attr = target.split(':')
        owner = server if owner_name == 'server' else None
        if owner_name == 'config':
            owner = server.Config
        original = getattr(owner, attr)
    else:
        raise AssertionError('use "owner:attr" string')

    def wrapper(*args, **kwargs):
        try:
            asyncio.get_running_loop()
            record['has_loop'] = True
        except RuntimeError:
            record['has_loop'] = False
        record['thread'] = threading.current_thread().name
        record['calls'] = record.get('calls', 0) + 1
        if call_original:
            return original(*args, **kwargs)
        return None

    monkeypatch.setattr(owner, attr, wrapper)
    return wrapper


def test_login_verify_off_event_loop(client, autouse_settings, settings,
                                     userdata, monkeypatch):
    settings['dashboard']['user_control']['enabled'] = True
    record = {}
    _wrap_to_record(monkeypatch, 'server:_verify_password', record)
    r = client.post('/login', data={'username': 'tester', 'password': 'testerpw'},
                    follow_redirects=False)
    assert r.status_code == 302
    assert record.get('calls', 0) >= 1
    assert record.get('has_loop') is False


def test_upload_config_off_event_loop(client, autouse_settings, settings,
                                      userdata, monkeypatch):
    settings['dashboard']['user_control']['enabled'] = True
    record = {}
    _wrap_to_record(monkeypatch, 'config:write_settings', record,
                    call_original=False)
    payload = {}
    for key in server.id_list:
        if key == 'browser_fingerprint':
            payload['browser_fingerprint_ja3'] = 'j'
            payload['browser_fingerprint_akamai'] = 'a'
        else:
            payload[key] = settings[key]
    r = client.post('/uploadConfig', json=payload,
                    cookies={'token': 'admintoken123'})
    assert r.text == '{"status":"200"}'
    assert record.get('calls', 0) >= 1
    assert record.get('has_loop') is False


def test_manual_task_off_event_loop(client, autouse_settings, settings,
                                    userdata, monkeypatch):
    settings['dashboard']['user_control']['enabled'] = True
    record = {}
    _wrap_to_record(monkeypatch, 'config:read_settings', record)
    monkeypatch.setattr(server, 'cui', lambda *a, **k: None)
    r = client.post('/manualTask', json={
        'sn': '123', 'resolution': '720', 'mode': 'single',
        'thread': 1, 'classify': True, 'danmu': False,
    }, cookies={'token': 'admintoken123'})
    assert r.text == '{"status":"200"}'
    assert record.get('calls', 0) >= 1
    assert record.get('has_loop') is False


def test_sn_list_off_event_loop(client, autouse_settings, settings,
                                userdata, monkeypatch):
    settings['dashboard']['user_control']['enabled'] = True
    record = {}
    _wrap_to_record(monkeypatch, 'config:write_sn_list', record,
                    call_original=False)
    r = client.post('/sn_list', content='111 all',
                    cookies={'token': 'admintoken123'})
    assert r.text == '{"status":"200"}'
    assert record.get('calls', 0) >= 1
    assert record.get('has_loop') is False


def test_console_command_off_event_loop(client, autouse_settings, settings,
                                        userdata, monkeypatch):
    settings['dashboard']['user_control']['enabled'] = True
    record = {}

    def fake_handler(raw, show_detail=True):
        try:
            asyncio.get_running_loop()
            record['has_loop'] = True
        except RuntimeError:
            record['has_loop'] = False
        record['calls'] = record.get('calls', 0) + 1
        return {'success': True, 'message': 'ok:' + raw}

    monkeypatch.setattr(server, 'command_handler', fake_handler)
    r = client.post('/console/command', json={'command': 'help'},
                    cookies={'token': 'admintoken123'})
    assert r.status_code == 200
    assert record.get('calls', 0) >= 1
    assert record.get('has_loop') is False


def test_watch_time_off_event_loop(client, autouse_settings, userdata,
                                   monkeypatch):
    record = {}
    _wrap_to_record(monkeypatch, 'server:save_user_data', record)
    r = client.post('/watch/time', json={
        'type': 'set', 'sn': '123', 'time': 42, 'duration': 1400,
    }, cookies={'token': 'usertoken456'})
    assert r.text == '{"status":"200"}'
    assert record.get('calls', 0) >= 1
    assert record.get('has_loop') is False


def test_register_off_event_loop(client, autouse_settings, settings,
                                 userdata, monkeypatch):
    settings['dashboard']['user_control']['enabled'] = True
    settings['dashboard']['user_control']['allow_register'] = True
    record = {}
    _wrap_to_record(monkeypatch, 'server:_hash_password', record)
    r = client.post('/register', data={'username': 'newoff', 'pw1': 'secret12',
                                       'pw2': 'secret12'},
                    follow_redirects=False)
    assert r.status_code == 302
    assert record.get('calls', 0) >= 1
    assert record.get('has_loop') is False


def test_usermanage_off_event_loop(client, autouse_settings, settings,
                                   userdata, monkeypatch):
    settings['dashboard']['user_control']['enabled'] = True
    record = {}
    _wrap_to_record(monkeypatch, 'server:save_user_data', record)
    r = client.post('/usermanage', json={'action': 'add', 'username': 'extra2',
                                         'password': 'extrapw1', 'role': 'user'},
                    cookies={'token': 'admintoken123'})
    assert r.json()['status'] == '200'
    assert record.get('calls', 0) >= 1
    assert record.get('has_loop') is False


def test_userinfo_off_event_loop(client, autouse_settings, settings,
                                 userdata, monkeypatch):
    settings['dashboard']['user_control']['enabled'] = True
    record = {}
    _wrap_to_record(monkeypatch, 'server:_verify_password', record)
    r = client.post('/userinfo', json={'action': 'changepassword',
                                       'original_password': 'testerpw',
                                       'new_password1': 'newsecret1',
                                       'new_password2': 'newsecret1'},
                    cookies={'token': 'usertoken456'})
    assert r.json()['status'] == '200'
    assert record.get('calls', 0) >= 1
    assert record.get('has_loop') is False
