"""Exercise real Dashboard routes with mocked account, media and Discord data."""
import copy
import json
import re
from types import SimpleNamespace
from urllib.parse import parse_qs, urlsplit

import pytest
from fastapi.testclient import TestClient

import Dashboard.Server as server
from Dashboard import discord_activity as activity


@pytest.fixture
def env(monkeypatch, tmp_path):
    settings = {'danmu': False, 'segment_download_mode': True,
                'dashboard': {'online_watch': True, 'online_watch_requires_login': True,
                             'user_control': {'enabled': True, 'allow_register': False},
                             'discord_activity': {'client_id': '12345', 'client_secret': 'fake-secret',
                                                  'bot_token': 'fake-bot-token'}}}
    users = {'users': [
        {'username': 'alice', 'password': 'alicepw', 'token': 'alice-token',
         'role': 'user', 'videotimes': {}, 'discord_account': {'id': '111', 'username': 'discord-alice'}},
        {'username': 'admin', 'password': 'adminpw', 'token': 'admin-token',
         'role': 'admin', 'videotimes': {}}]}
    clock = [1000.0]
    monkeypatch.setattr(activity, '_now', lambda: clock[0])
    monkeypatch.setattr(server, '_get_current_settings', lambda: settings)
    monkeypatch.setattr(server.Config, 'read_settings', lambda *args, **kwargs: settings)
    monkeypatch.setattr(server.Config, 'get_working_dir', lambda: str(tmp_path))
    monkeypatch.setattr(server, 'load_user_data', lambda: copy.deepcopy(users))
    def save(data):
        users.clear()
        users.update(copy.deepcopy(data))
    monkeypatch.setattr(server, 'save_user_data', save)
    monkeypatch.setattr(server.discord_activity, 'sessions', {})
    monkeypatch.setattr(server.discord_activity, 'rooms', {})
    monkeypatch.setattr(server.discord_activity, 'memberships', {})
    monkeypatch.setattr(server.discord_activity, 'login_attempts', {})
    if hasattr(server.discord_activity, 'grants'):
        monkeypatch.setattr(server.discord_activity, 'grants', {})
    def discord_request(method, path, **kwargs):
        if path == '/oauth2/token':
            code = kwargs['data']['code']
            return {'access_token': 'fake-access-' + ('111' if code == 'fake-code' else code), 'expires_in': 3600}
        if path == '/users/@me':
            uid = kwargs['headers']['Authorization'].split('fake-access-')[1]
            return {'id': uid, 'username': 'discord-' + uid,
                    'global_name': 'Alice' if uid == '111' else 'Guest ' + uid}
        instance = path.rsplit('/', 1)[-1]
        return {'application_id': '12345', 'instance_id': instance,
                'users': ['111', '222', '333'] if instance == 'room-one' else ['222']}
    monkeypatch.setattr(server.discord_activity, '_discord_request', discord_request)
    monkeypatch.setattr(server, '_sync_plugin_manager', lambda *args, **kwargs: settings)
    monkeypatch.setattr(server, 'plugin_manager', type('Plugins', (), {'resolve_playback_source': lambda *args: None})())
    video_path = tmp_path / 'fixture.mp4'
    video_path.write_bytes(b'activity-video-fixture')
    monkeypatch.setattr(server, '_find_video_path', lambda *args, **kwargs: str(video_path))
    video_list = {'videos': [
        {'sn': '101', 'title': 'Test episode', 'anime_name': 'Test series', 'episode': '1', 'resolution': 1080},
        {'sn': '102', 'title': 'Other episode', 'anime_name': 'Test series', 'episode': '2', 'resolution': 1080}]}
    monkeypatch.setattr(server, '_find_video_entry',
                        lambda sn: next((dict(video) for video in video_list['videos'] if video['sn'] == str(sn)), None))
    monkeypatch.setattr(server, '_get_anime_info', lambda sn: {
        'anime': {'animeSn': '900', 'title': 'Test series', 'episodes': {'0': [
            {'videoSn': '101', 'episode': '1'}, {'videoSn': '102', 'episode': '2'}]}},
        'video': {'videoSn': str(sn)}})
    (tmp_path / 'video_list.json').write_text(json.dumps(video_list), encoding='utf-8')
    c = TestClient(server.app, base_url='https://activity.test', follow_redirects=False)
    return c, settings, users, clock


def authenticate(client, uid='111'):
    bootstrap = client.get('/discord/activity/config')
    assert bootstrap.status_code == 200
    client.headers['X-Activity-CSRF'] = bootstrap.json()['csrf_token']
    auth = client.post('/discord/activity/token', json={'code': uid})
    assert auth.status_code == 200
    if uid == '111':
        assert auth.json()['account']['username'] == 'alice'
    else:
        assert auth.json()['account'] is None
    joined = client.post('/discord/activity/join', json={'instance_id': 'room-one'})
    assert joined.status_code == 200
    return joined.json()


def test_sdk_launch_renders_activity_without_redirecting_away_from_context(env):
    c, _, _, _ = env
    context = {'frame_id': 'frame-1', 'instance_id': 'room-one', 'platform': 'desktop',
               'guild_id': '123', 'channel_id': '456', 'custom_id': 'hello world & friends'}
    response = c.get('/', params=context)
    assert response.status_code == 200
    assert 'location' not in response.headers
    assert 'id="activityPlayer"' in response.text
    assert response.headers['cache-control'] == 'no-store'


def test_activity_page_renders_local_assets_and_account_controls(env):
    c, _, _, _ = env
    response = c.get('/discord/activity')
    assert response.status_code == 200
    assert response.headers['cache-control'] == 'no-store'
    for fragment in ('static/js/vendor/discord-embedded-app-sdk.js', 'static/js/discord-activity.js',
                     'static/css/discord-activity.css', 'id="accountForm"', 'id="accountLink"',
                     'id="accountUnlink"', 'id="activityPlayer"'):
        assert fragment in response.text


def test_activity_bridge_grants_watch_and_media_only(env):
    c, _, _, _ = env
    assert c.get('/video_list.json').status_code == 403
    authenticate(c)
    assert c.cookies.get('token') is None
    assert c.get('/watch').status_code == 200
    listing = c.get('/video_list.json')
    assert listing.status_code == 200 and listing.json()['videos'][0]['sn'] == '101'
    assert listing.headers['cache-control'] == 'private, no-store'
    assert 'alice-token' not in listing.text
    media = c.get('/get_video.mp4?id=101')
    assert media.status_code == 200 and media.content == b'activity-video-fixture'
    assert c.get('/data/config.json').status_code == 401
    admin_page = c.get('/usermanage')
    assert admin_page.status_code == 302 and 'login' in admin_page.headers['location']
    admin_post = c.post('/usermanage', json={'action': 'get'})
    assert admin_post.status_code == 302 and 'login' in admin_post.headers['location']


@pytest.mark.parametrize('revocation', ['expiry', 'password_reset', 'unlink', 'not_joined'])
def test_invalid_activity_never_falls_back_to_regular_site_cookie(env, revocation):
    c, _, users, clock = env
    authenticate(c)
    # Deliberately valid ordinary admin cookie: Activity failure must still deny media.
    c.cookies.set('token', 'admin-token')
    if revocation == 'expiry':
        clock[0] += 3601
    elif revocation == 'password_reset':
        users['users'][0]['token'] = 'rotated-alice-token'
    elif revocation == 'unlink':
        users['users'][0].pop('discord_account')
    else:
        for session in server.discord_activity.sessions.values():
            session.pop('instance_id', None)
    assert c.get('/video_list.json').status_code == 403
    assert c.get('/get_video.mp4?id=101').status_code == 403
    assert c.get('/watch').status_code == 302
    assert c.post('/watch/time', json={'type': 'get'}, headers={'X-Activity-Playback': '1'}).status_code == 403


def test_activity_history_mutation_requires_playback_header(env):
    c, _, users, _ = env
    authenticate(c)
    payload = {'type': 'set', 'sn': '101', 'time': 45, 'duration': 1440, 'ended': False}
    assert c.post('/watch/time', json=payload).status_code == 403
    assert c.get('/watch/time', params=payload).status_code == 403
    assert users['users'][0]['videotimes'] == {}
    saved = c.post('/watch/time', json=payload, headers={'X-Activity-Playback': '1'})
    assert saved.status_code == 200 and saved.json()['status'] == '200'
    assert 'alice-token' not in saved.text and 'admin-token' not in saved.text
    assert users['users'][0]['videotimes']['101']['time'] == 45
    read = c.get('/watch/time', params={'type': 'get', 'sn': '101'})
    assert read.status_code == 200 and read.json()['time'] == 45
    assert c.get('/watch/time?type=del&sn=101').status_code == 403
    deleted = c.get('/watch/time?type=del&sn=101', headers={'X-Activity-Playback': '1'})
    assert deleted.status_code == 200 and users['users'][0]['videotimes'] == {}
    # Ordinary website requests retain their existing login behavior.
    c.cookies.clear()
    c.cookies.set('token', 'alice-token')
    assert c.post('/watch/time', json=payload).status_code == 200


def granted_guest(env):
    host = env[0]
    authenticate(host)
    guest = TestClient(server.app, base_url='https://activity.test', follow_redirects=False)
    lobby = authenticate(guest, '222')
    assert lobby['can_watch'] is False and lobby['is_host'] is False
    selected = host.post('/discord/activity/control', json={
        'instance_id': 'room-one', 'action': 'select', 'sn': '101'})
    assert selected.status_code == 200
    granted = host.post('/discord/activity/grant', json={
        'instance_id': 'room-one', 'user_id': '222', 'sn': '101'})
    assert granted.status_code == 200
    state = guest.get('/discord/activity/state?instance_id=room-one')
    assert state.status_code == 200 and state.json()['can_watch'] is True
    token = state.json()['watch_token']
    assert isinstance(token, str) and token
    assert 'alice-token' not in token and 'admin-token' not in token
    assert guest.cookies.get('token') is None
    return host, guest, token


def test_automatic_grants_rotate_on_video_switch_and_stop_on_disable(env):
    host = env[0]
    authenticate(host)
    guest = TestClient(server.app, base_url='https://activity.test', follow_redirects=False)
    assert authenticate(guest, '222')['can_watch'] is False
    enabled = host.post('/discord/activity/auto-grant', json={'instance_id': 'room-one', 'enabled': True})
    assert enabled.status_code == 200 and enabled.json()['auto_grant'] is True
    assert host.post('/discord/activity/control', json={
        'instance_id': 'room-one', 'action': 'select', 'sn': '101'}).status_code == 200
    first = guest.get('/discord/activity/state?instance_id=room-one').json()['watch_token']
    assert guest.get('/get_video.mp4', params={'id': '101', 'ag': first}).status_code == 200
    assert guest.get('/get_video.mp4', params={'id': '102', 'ag': first}).status_code == 403
    assert host.post('/discord/activity/control', json={
        'instance_id': 'room-one', 'action': 'select', 'sn': '102'}).status_code == 200
    second = guest.get('/discord/activity/state?instance_id=room-one').json()['watch_token']
    assert second != first
    assert guest.get('/get_video.mp4', params={'id': '101', 'ag': first}).status_code == 403
    assert guest.get('/get_video.mp4', params={'id': '102', 'ag': first}).status_code == 403
    assert guest.get('/get_video.mp4', params={'id': '102', 'ag': second}).status_code == 200
    late_guest = TestClient(server.app, base_url='https://activity.test', follow_redirects=False)
    state = authenticate(late_guest, '333')
    assert state['can_watch'] is True and state['watch_token'] != second
    assert late_guest.get('/get_video.mp4', params={'id': '102', 'ag': state['watch_token']}).status_code == 200
    assert host.post('/discord/activity/auto-grant', json={
        'instance_id': 'room-one', 'enabled': False}).json()['auto_grant'] is False
    assert guest.get('/get_video.mp4', params={'id': '102', 'ag': second}).status_code == 403
    assert late_guest.get('/get_video.mp4', params={'id': '102', 'ag': state['watch_token']}).status_code == 403


def test_manual_revoke_overrides_auto_grant_for_the_current_episode(env):
    host, guest, manual = granted_guest(env)
    assert host.post('/discord/activity/auto-grant', json={
        'instance_id': 'room-one', 'enabled': True}).status_code == 200
    assert guest.post('/discord/activity/auto-grant', json={
        'instance_id': 'room-one', 'enabled': False}).status_code == 403
    assert host.post('/discord/activity/revoke', json={
        'instance_id': 'room-one', 'user_id': '222', 'sn': '101'}).status_code == 200
    for _ in range(2):
        assert guest.get('/discord/activity/state?instance_id=room-one').json()['can_watch'] is False
    assert guest.get('/get_video.mp4', params={'id': '101', 'ag': manual}).status_code == 403
    assert host.post('/discord/activity/control', json={
        'instance_id': 'room-one', 'action': 'select', 'sn': '102'}).status_code == 200
    state = guest.get('/discord/activity/state?instance_id=room-one').json()
    assert state['can_watch'] is True
    assert guest.get('/get_video.mp4', params={'id': '102', 'ag': state['watch_token']}).status_code == 200


def test_presence_permission_upgrade_does_not_revoke_automatic_guest_watch(env, monkeypatch):
    host, guest, _ = granted_guest(env)
    host.post('/discord/activity/auto-grant', json={'instance_id': 'room-one', 'enabled': True})
    original = server.discord_activity._discord_request
    def discord_request(method, path, **kwargs):
        if path == '/oauth2/token':
            return {'access_token': 'upgraded-sdk-access', 'scope': 'identify rpc.activities.write', 'expires_in': 99999}
        if path == '/users/@me':
            return {'id': '111'}
        return original(method, path, **kwargs)
    monkeypatch.setattr(server.discord_activity, '_discord_request', discord_request)
    response = host.post('/discord/activity/presence-token', json={'code': 'upgraded-sdk-code'})
    assert response.status_code == 200 and response.json() == {'access_token': 'upgraded-sdk-access'}
    state = guest.get('/discord/activity/state?instance_id=room-one').json()
    assert state['auto_grant'] is True and state['can_watch'] is True
    assert guest.get('/get_video.mp4', params={'id': '101', 'ag': state['watch_token']}).status_code == 200


def test_host_grant_opens_only_one_video_without_lending_account_identity(env):
    host, guest, token = granted_guest(env)
    params = {'id': '101', 'ag': token}
    page = guest.get('/watch', params=params)
    assert page.status_code == 200
    assert page.headers['referrer-policy'] == 'no-referrer'
    assert 'alice-token' not in page.text and 'admin-token' not in page.text
    listing = guest.get('/video_list.json', params=params)
    assert listing.status_code == 200
    assert [row['sn'] for row in listing.json()['videos']] == ['101']
    assert listing.headers['cache-control'] == 'private, no-store'
    media = guest.get('/get_video.mp4', params=params)
    assert media.status_code == 200 and media.content == b'activity-video-fixture'
    assert media.headers['cache-control'] == 'private, no-store'
    assert media.headers['referrer-policy'] == 'no-referrer'
    ranged = guest.get('/get_video.mp4', params=params, headers={'Range': 'bytes=0-7'})
    assert ranged.status_code == 206 and ranged.content == b'activity'
    assert guest.head('/get_video.mp4', params=params).status_code == 200
    series = guest.get('/watch/series.json', params=params)
    assert series.status_code == 200
    assert '102' not in series.text
    assert guest.get('/get_danmu.ass', params=params).status_code == 200
    assert guest.get('/watch/skip.json', params={**params, 'duration': 1440}).status_code == 200
    # A grant is playback access, not a website login or a host-control ticket.
    assert guest.get('/data/config.json', params=params).status_code == 403
    assert guest.get('/thumbnails.json', params=params).status_code == 403
    assert guest.get('/catalog/all.json', params=params).status_code == 403
    assert guest.get('/cast/ticket', params=params).status_code in (401, 403)
    assert guest.post('/watch/time', params=params, json={'type': 'set', 'sn': '101', 'time': 8},
                      headers={'X-Activity-Playback': '1'}).status_code == 403
    assert guest.post('/discord/activity/control', json={
        'instance_id': 'room-one', 'action': 'play', 'position': 0}).status_code == 403
    assert guest.post('/discord/activity/grant', json={
        'instance_id': 'room-one', 'user_id': '333', 'sn': '101'}).status_code == 403
    assert token not in host.get('/discord/activity/state?instance_id=room-one').text


def test_guest_capability_cannot_escape_through_external_plugin_redirect(env, monkeypatch):
    host, guest, token = granted_guest(env)
    external = 'https://invalid.example/provider-video.mp4'
    monkeypatch.setattr(server.plugin_manager, 'resolve_playback_source', lambda *args: {'url': external})
    denied = guest.get('/get_video.mp4', params={'id': '101', 'ag': token})
    assert denied.status_code == 403
    assert 'location' not in denied.headers and external not in denied.text
    assert denied.headers['referrer-policy'] == 'no-referrer'
    ordinary = host.get('/get_video.mp4?id=101')
    assert ordinary.status_code == 302 and ordinary.headers['location'] == external


def test_guest_opening_lookup_uses_server_metadata_and_keeps_episode_scope(env, monkeypatch):
    _, guest, token = granted_guest(env)
    monkeypatch.setattr(server, '_find_video_entry', lambda sn: {'sn': sn, 'source': server.BAHAMUT_SOURCE})
    monkeypatch.setattr(server, '_read_catalog_cache', lambda *args: None)
    monkeypatch.setattr(server, '_write_catalog_cache', lambda *args: None)
    monkeypatch.setattr(server.OpeningSkip, 'resolve_series', lambda *args: {'malId': 12345})
    calls = []
    def opening(series, episode, duration, *, anime_skip_fallback):
        calls.append((series['malId'], episode, duration, anime_skip_fallback))
        return {'interval': [40, 130], 'source': 'AniSkip'}
    monkeypatch.setattr(server.OpeningSkip, 'opening_op', opening)
    params = {'id': '101', 'ag': token, 'duration': 1440, 'anime_skip_fallback': '0'}
    result = guest.get('/watch/skip.json', params=params)
    assert result.status_code == 200
    assert result.json() == {'interval': [40, 130], 'source': 'AniSkip'}
    assert calls == [(12345, 1, 1440, False)]
    assert guest.get('/watch/skip.json', params={**params, 'id': '102'}).status_code == 403
    assert len(calls) == 1


@pytest.mark.parametrize('path', [
    '/watch', '/video_list.json', '/watch/series.json', '/anime_info',
    '/watch/skip.json', '/thumbnail.webp', '/get_video.mp4', '/get_danmu.ass',
    '/hls/status.json', '/hls/playlist.m3u8', '/hls/key.bin', '/hls/segment.ts',
    '/stream/sources.json', '/stream/playlist.m3u8', '/stream/key.bin', '/stream/segment.ts',
])
def test_guest_token_cannot_open_another_episode_on_any_viewing_route(env, path):
    _, guest, token = granted_guest(env)
    guest.cookies.set('token', 'admin-token')
    response = guest.get(path, params={'id': '102', 'ag': token, 'n': 0, 'res': 1080, 'duration': 1440})
    assert response.status_code == 403


def test_guest_token_requires_its_discord_identity_and_room(env):
    _, guest, token = granted_guest(env)
    outsider = TestClient(server.app, base_url='https://activity.test', follow_redirects=False)
    assert outsider.get('/get_video.mp4', params={'id': '101', 'ag': token}).status_code == 403
    authenticate(outsider, '333')
    assert outsider.get('/get_video.mp4', params={'id': '101', 'ag': token}).status_code == 403
    joined = guest.post('/discord/activity/join', json={'instance_id': 'room-two'})
    assert joined.status_code == 200
    assert guest.get('/get_video.mp4', params={'id': '101', 'ag': token}).status_code == 403


@pytest.mark.parametrize('source', ['hls', 'stream'])
def test_guest_hls_key_and_segments_keep_the_same_video_capability(env, monkeypatch, tmp_path, source):
    _, guest, token = granted_guest(env)
    parsed = {'target_duration': 10, 'key_line': '#EXT-X-KEY:METHOD=AES-128,URI="key.bin"',
              'segments': [{'name': '0.ts', 'uri': '0.ts', 'extinf': '#EXTINF:10.0,'}]}
    if source == 'hls':
        (tmp_path / 'key.m3u8key').write_bytes(b'0123456789abcdef')
        (tmp_path / '0.ts').write_bytes(b'guest-hls-segment')
        monkeypatch.setattr(server, '_hls_state', lambda *args: {
            'mode': 'streaming', 'parsed': parsed, 'ready': 1, 'temp_dir': str(tmp_path)})
    else:
        media = {'parsed': parsed, 'base': 'https://invalid.example/playlist.m3u8'}
        monkeypatch.setattr(server, '_stream_allowed', lambda sn: sn == '101')
        monkeypatch.setattr(server, '_stream_media', lambda *args: media)
        monkeypatch.setattr(server, '_stream_key', lambda *args: b'0123456789abcdef')
        monkeypatch.setattr(server, '_bahamut_get', lambda *args, **kwargs:
                            SimpleNamespace(status_code=200, content=b'guest-stream-segment'))
    base = '/' + source + '/'
    playlist = guest.get(base + 'playlist.m3u8', params={'id': '101', 'ag': token, 'res': 1080})
    assert playlist.status_code == 200
    urls = re.findall(r'URI="([^"]+)"', playlist.text)
    urls += [line for line in playlist.text.splitlines() if line and not line.startswith('#')]
    assert len(urls) == 2
    for url in urls:
        query = parse_qs(urlsplit(url).query)
        assert query['id'] == ['101'] and query['ag'] == [token]
        resource = guest.get(base + url)
        assert resource.status_code == 200
        assert resource.headers['cache-control'] == 'private, no-store'
        assert guest.get(base + url.replace('id=101', 'id=102')).status_code == 403


@pytest.mark.parametrize('revocation', [
    'revoke', 'select_other', 'reselect_same', 'host_leave', 'host_logout',
    'password_reset', 'unlink', 'guest_leave', 'expiry',
])
def test_guest_media_grant_is_revoked_as_soon_as_its_authority_changes(env, revocation):
    host, guest, token = granted_guest(env)
    _, _, users, clock = env
    if revocation == 'revoke':
        response = host.post('/discord/activity/revoke', json={
            'instance_id': 'room-one', 'user_id': '222', 'sn': '101'})
        assert response.status_code == 200
    elif revocation in ('select_other', 'reselect_same'):
        response = host.post('/discord/activity/control', json={
            'instance_id': 'room-one', 'action': 'select',
            'sn': '102' if revocation == 'select_other' else '101'})
        assert response.status_code == 200
    elif revocation == 'host_leave':
        assert host.post('/discord/activity/leave', json={'instance_id': 'room-one'}).status_code == 200
    elif revocation == 'host_logout':
        assert host.post('/discord/activity/logout', json={}).status_code == 200
    elif revocation == 'password_reset':
        users['users'][0]['token'] = 'new-alice-token'
    elif revocation == 'unlink':
        users['users'][0].pop('discord_account')
    elif revocation == 'guest_leave':
        assert guest.post('/discord/activity/leave', json={'instance_id': 'room-one'}).status_code == 200
    else:
        clock[0] += 7201
    response = guest.get('/get_video.mp4', params={'id': '101', 'ag': token})
    assert response.status_code == 403
