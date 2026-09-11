"""Transactional userdata + atomic-write regression tests (TDD).

Run with::

    PYTHONPATH=/tmp/agp_testdeps python3 -m pytest tests/test_userdata_transactions.py --noconftest -q

Covers the FastAPI userdata blocker:
- concurrent watch-time updates for different users/SNs both survive
- concurrent registration/admin/password/watch updates do not lose changes
- readers never observe a concurrent write as empty/corrupt
- simulated write failure leaves userdata.json intact, no temp litter
- auth/login/hash behaviour stays compatible

Synchronisation uses barriers/events, not timing-only sleeps.
"""

import copy
import json
import os
import stat
import threading
import time

import pytest

import Dashboard.Server as server


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
                'enabled': True,
                'allow_register': True,
                'default_user': [],
            },
        },
    }
    settings.update(over)
    return settings


@pytest.fixture
def real_userdata_env(tmp_path, monkeypatch):
    """Point the real filesystem persistence at a tmp userdata.json."""
    settings = make_settings()
    data_path = tmp_path / 'userdata.json'
    monkeypatch.setattr(server, 'userdata_path', str(data_path))
    monkeypatch.setattr(server.Config, 'read_settings', lambda *a, **k: settings)
    monkeypatch.setattr(server, '_get_current_settings', lambda: settings)
    seed = {"users": [
        {'username': 'alice', 'password_hash': server._hash_password('alicepw1'),
         'token': 'alice-token', 'videotimes': {}, 'role': 'user'},
        {'username': 'bob', 'password_hash': server._hash_password('bobpw123'),
         'token': 'bob-token', 'videotimes': {}, 'role': 'user'},
    ]}
    server.save_user_data(copy.deepcopy(seed))
    return settings, str(data_path)


def _read_raw(path):
    with open(path, 'r', encoding='utf-8') as f:
        return json.load(f)


def test_transactional_api_exists():
    # The fix must expose a single-lock-scope read-modify-write entry point.
    # Fails on the pre-fix implementation (only bare load/save exist).
    assert hasattr(server, 'update_user_data') or hasattr(server, 'userdata_transaction'), \
        'missing transactional userdata API (update_user_data/userdata_transaction)'


def test_concurrent_watch_time_both_survive(real_userdata_env):
    _, path = real_userdata_env
    barrier = threading.Barrier(2)

    def set_time(token, sn, t):
        barrier.wait(timeout=10)
        return server._webtime_blocking(
            {'type': 'set', 'sn': sn, 'time': t, 'duration': 1400}, token)

    th1 = threading.Thread(target=set_time, args=('alice-token', 'SN-A', 11))
    th2 = threading.Thread(target=set_time, args=('bob-token', 'SN-B', 22))
    th1.start()
    th2.start()
    th1.join(timeout=15)
    th2.join(timeout=15)
    assert not th1.is_alive() and not th2.is_alive()

    data = _read_raw(path)
    by_name = {u['username']: u for u in data['users']}
    assert by_name['alice']['videotimes'].get('SN-A', {}).get('time') == 11
    assert by_name['bob']['videotimes'].get('SN-B', {}).get('time') == 22


def test_concurrent_register_and_watch_do_not_lose_changes(real_userdata_env, monkeypatch):
    settings, path = real_userdata_env
    barrier = threading.Barrier(2)
    outcomes = {}

    class FakeRequest:
        method = 'POST'
        cookies = {'token': 'alice-token'}
        query_params = {}
        state = type('S', (), {'current_user': {
            'username': 'alice', 'role': 'admin'}})()

    # Alice is admin for this test so usermanage add is permitted.
    with open(path, 'r', encoding='utf-8') as f:
        seed = json.load(f)
    for u in seed['users']:
        if u['username'] == 'alice':
            u['role'] = 'admin'
    server.save_user_data(seed)

    def do_register():
        barrier.wait(timeout=10)
        req = FakeRequest()
        req.state.current_user = {'username': 'alice', 'role': 'admin'}
        outcomes['register'] = server._register_blocking(
            req, {'username': 'carol1', 'pw1': 'secret12', 'pw2': 'secret12'})

    def do_watch():
        barrier.wait(timeout=10)
        outcomes['watch'] = server._webtime_blocking(
            {'type': 'set', 'sn': 'SN-W', 'time': 77, 'duration': 1400}, 'bob-token')

    th1 = threading.Thread(target=do_register)
    th2 = threading.Thread(target=do_watch)
    th1.start()
    th2.start()
    th1.join(timeout=15)
    th2.join(timeout=15)
    assert not th1.is_alive() and not th2.is_alive()

    data = _read_raw(path)
    names = {u['username'] for u in data['users']}
    assert 'carol1' in names, outcomes
    bob = next(u for u in data['users'] if u['username'] == 'bob')
    assert bob['videotimes'].get('SN-W', {}).get('time') == 77, outcomes


def test_readers_never_see_empty_or_corrupt_during_writes(real_userdata_env):
    _, path = real_userdata_env
    stop = threading.Event()
    start = threading.Event()
    errors = []

    def writer():
        start.wait(timeout=10)
        for i in range(50):
            if stop.is_set():
                return
            data = server.load_user_data()
            for u in data['users']:
                if u['username'] == 'alice':
                    u['videotimes']['SN-R'] = {'time': i, 'ended': False,
                                              'timestamp': 1}
            server.save_user_data(data)

    def reader():
        start.wait(timeout=10)
        for _ in range(200):
            if stop.is_set():
                break
            try:
                with open(path, 'r', encoding='utf-8') as f:
                    raw = f.read()
                if not raw.strip():
                    errors.append('empty file observed')
                    return
                parsed = json.loads(raw)
                users = parsed.get('users')
                if not isinstance(users, list) or len(users) < 2:
                    errors.append('users missing during concurrent write: %r' % (raw[:80],))
                    return
            except json.JSONDecodeError as e:
                errors.append('corrupt JSON observed: %s' % e)
                return
            except OSError as e:
                errors.append('read error: %s' % e)
                return

    wt = threading.Thread(target=writer)
    readers = [threading.Thread(target=reader) for _ in range(3)]
    wt.start()
    for t in readers:
        t.start()
    start.set()
    wt.join(timeout=30)
    stop.set()
    for t in readers:
        t.join(timeout=15)
    assert not errors, errors[:3]


def test_write_failure_leaves_original_intact_and_cleans_tmp(real_userdata_env, monkeypatch):
    _, path = real_userdata_env
    before = _read_raw(path)
    before_text = open(path, 'r', encoding='utf-8').read()
    d = os.path.dirname(path)

    real_dump = json.dump

    def boom(*a, **k):
        raise OSError('simulated disk failure')

    monkeypatch.setattr(server.json, 'dump', boom)
    with pytest.raises(OSError):
        server.save_user_data({'users': [{'username': 'mallory'}]})
    monkeypatch.setattr(server.json, 'dump', real_dump)

    after_text = open(path, 'r', encoding='utf-8').read()
    assert after_text == before_text
    assert _read_raw(path) == before
    leftovers = [n for n in os.listdir(d)
                 if n.startswith('.userdata-') or n.endswith('.tmp')]
    assert leftovers == [], leftovers


def test_atomic_replace_is_followed_by_directory_fsync(real_userdata_env, monkeypatch):
    """Persist the rename itself, not only the temporary file."""
    _, path = real_userdata_env
    events = []
    real_fsync = os.fsync
    real_replace = os.replace

    def tracking_fsync(fd):
        is_directory = stat.S_ISDIR(os.fstat(fd).st_mode)
        events.append('directory_fsync' if is_directory else 'file_fsync')
        return real_fsync(fd)

    def tracking_replace(src, dst):
        events.append('replace')
        return real_replace(src, dst)

    monkeypatch.setattr(server.os, 'fsync', tracking_fsync)
    monkeypatch.setattr(server.os, 'replace', tracking_replace)

    server.save_user_data({'users': [{'username': 'durable'}]})

    assert events.index('file_fsync') < events.index('replace')
    assert events.index('replace') < events.index('directory_fsync')
    assert _read_raw(path)['users'][0]['username'] == 'durable'


def test_auth_hash_compat_and_login_migration(real_userdata_env):
    settings, path = real_userdata_env
    # Werkzeug-format hashes keep verifying.
    legacy = {'username': 'u', 'password_hash':
              'pbkdf2:sha256:1000$wX7aQ9mB2cDeFgH1$'
              '50c22dfbc508331654c5fc3ce0726db8d9a7767bcee02567c6368e136983193e'}
    assert server._verify_password(legacy, 'secret12') is True
    assert server._verify_password(legacy, 'wrong') is False

    fresh = server._hash_password('secret12')
    assert server._verify_password({'username': 'u', 'password_hash': fresh}, 'secret12') is True

    # Legacy plaintext password migrates to a hash on successful login.
    data = _read_raw(path)
    data['users'].append({'username': 'legacy1', 'password': 'legacypw',
                          'token': 'legacy-token', 'videotimes': {}, 'role': 'user'})
    server.save_user_data(data)

    class FakeRequest:
        method = 'POST'
        query_params = {}
        cookies = {}

    resp = server._login_blocking(FakeRequest(), {'username': 'legacy1', 'password': 'legacypw'})
    assert getattr(resp, 'status_code', 302) == 302
    migrated = {u['username']: u for u in _read_raw(path)['users']}['legacy1']
    assert 'password_hash' in migrated and 'password' not in migrated
    assert server._verify_password(migrated, 'legacypw') is True
