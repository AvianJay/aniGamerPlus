"""Activity OAuth, account linking, room isolation and authoritative playback."""
import copy
from types import SimpleNamespace
from urllib.parse import urlencode

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient
from starlette.requests import Request

from Dashboard import discord_activity as activity


@pytest.fixture
def env(monkeypatch):
    settings = {'dashboard': {'online_watch': True, 'online_watch_requires_login': False,
                             'user_control': {'enabled': True},
                             'discord_activity': {'client_id': '12345',
                                                  'client_secret': 'test-client-secret',
                                                  'bot_token': 'test-bot-token'}}}
    data = {'users': [
        {'username': 'alice', 'password': 'alicepw', 'token': 'alice-token', 'role': 'user'},
        {'username': 'bob', 'password': 'bobpw', 'token': 'bob-token', 'role': 'user'}]}
    clock = [1000.0]
    monkeypatch.setattr(activity, '_now', lambda: clock[0])
    def find_token(token, source=None):
        return next((u for u in (source or data)['users'] if u['token'] == token), None)
    def find_username(username):
        return next((u for u in data['users'] if u['username'] == username), None)
    def transaction(fn):
        snapshot = copy.deepcopy(data)
        result, dirty = fn(snapshot)
        if dirty:
            data.clear()
            data.update(snapshot)
        return result
    server = SimpleNamespace(app=FastAPI(), _get_current_settings=lambda: settings,
        find_user_by_token=find_token, find_user_by_username=find_username,
        _verify_password=lambda user, password: user['password'] == password,
        load_user_data=lambda: copy.deepcopy(data), update_user_data=transaction,
        _build_safe_user=lambda user: {'username': user['username'], 'role': user['role']} if user else None,
        _find_video_entry=lambda sn: {'sn': sn} if sn in ('101', '102') else None)
    backend = activity.install(server)
    calls = []
    members = {'room-one': ['111', '222'], 'room-two': ['333']}
    def discord_request(method, path, *, headers=None, data=None):
        calls.append((method, path))
        if path == '/oauth2/token':
            assert data['client_id'] == '12345'
            return {'access_token': 'access-' + data['code'], 'expires_in': 3600}
        if path == '/users/@me':
            uid = headers['Authorization'].split('access-')[1]
            return {'id': uid, 'username': 'discord-' + uid, 'global_name': None}
        instance = path.rsplit('/', 1)[1]
        return {'application_id': '12345', 'instance_id': instance, 'users': members.get(instance, [])}
    monkeypatch.setattr(backend, '_discord_request', discord_request)
    return SimpleNamespace(server=server, backend=backend, settings=settings, data=data,
                           clock=clock, members=members, calls=calls)


def client(env, uid='111'):
    result = TestClient(env.server.app, base_url='https://activity.test')
    bootstrap = result.get('/discord/activity/config')
    assert bootstrap.status_code == 200
    result.headers['X-Activity-CSRF'] = bootstrap.json()['csrf_token']
    token = result.post('/discord/activity/token', json={'code': uid})
    assert token.status_code == 200
    return result


def post(client, endpoint, **data):
    return client.post('/discord/activity/' + endpoint, json=data)


def join(client, room='room-one'):
    return post(client, 'join', instance_id=room)


def test_config_cookie_and_csrf_before_body(env, monkeypatch):
    c = TestClient(env.server.app, base_url='https://activity.test')
    response = c.get('/discord/activity/config')
    assert response.json()['configured'] is True
    assert 'client_secret' not in response.text and 'bot_token' not in response.text
    cookie = response.headers['set-cookie'].lower()
    assert all(part in cookie for part in ['secure', 'httponly', 'samesite=none', 'partitioned', 'path=/'])
    assert response.headers['cache-control'] == 'no-store'
    async def forbidden_parse(self):
        raise AssertionError('Unauthenticated JSON interpreted')
    monkeypatch.setattr(Request, 'json', forbidden_parse)
    assert post(c, 'token', code='111').status_code == 403
    c.cookies.clear()
    assert post(c, 'login', username='alice', password='alicepw').status_code == 401


def test_oauth_identity_comes_from_discord_and_errors_are_safe(env):
    c = client(env)
    me = c.get('/discord/activity/me').json()
    assert me['user']['id'] == '111' and me['account'] is None
    assert 'access_token' not in me
    assert env.calls[:2] == [('POST', '/oauth2/token'), ('GET', '/users/@me')]
    assert post(c, 'token', code='111', user={'id': '222'}).json()['user']['id'] == '111'


def test_login_required_allows_lobby_but_prevents_guest_control(env):
    c = client(env)
    env.settings['dashboard']['online_watch_requires_login'] = True
    lobby = join(c)
    assert lobby.status_code == 200
    assert lobby.json()['can_watch'] is False and lobby.json()['host_id'] is None
    assert post(c, 'login', username='alice', password='wrong').status_code == 401
    result = post(c, 'login', username='alice', password='alicepw')
    assert result.json()['account']['username'] == 'alice'
    assert 'alice-token' not in result.text
    assert join(c).status_code == 200
    env.data['users'][0]['token'] = 'revoked-token'
    assert c.get('/discord/activity/state?instance_id=room-one').json()['can_watch'] is False
    assert post(c, 'control', instance_id='room-one', action='select', sn='101').status_code == 403
    assert post(c, 'leave', instance_id='room-one').status_code == 200


def test_unique_binding_auto_login_and_unlink_revocation(env):
    alice = client(env)
    assert post(alice, 'link').status_code == 401
    assert post(alice, 'login', username='alice', password='alicepw').status_code == 200
    assert post(alice, 'link').json()['linked'] is True
    assert env.data['users'][0]['discord_account']['id'] == '111'
    next_session = client(env)
    assert next_session.get('/discord/activity/me').json()['account']['username'] == 'alice'
    assert post(next_session, 'login', username='bob', password='bobpw').status_code == 200
    assert post(next_session, 'link').status_code == 409
    assert 'discord_account' not in env.data['users'][1]
    assert post(alice, 'unlink').json()['account'] is None
    assert 'discord_account' not in env.data['users'][0]
    assert next_session.get('/discord/activity/me').json()['account'] is None
    assert client(env).get('/discord/activity/me').json()['account'] is None


def test_different_discord_cannot_replace_existing_binding(env):
    c = client(env)
    post(c, 'login', username='alice', password='alicepw')
    post(c, 'link')
    other = client(env, '222')
    post(other, 'login', username='alice', password='alicepw')
    assert post(other, 'link').status_code == 409
    assert post(other, 'unlink').status_code == 409
    assert env.data['users'][0]['discord_account']['id'] == '111'


def test_verified_room_membership_and_isolation(env):
    c = client(env)
    assert join(c, 'room-two').status_code == 403
    assert join(c, '../room-one').status_code == 400
    assert join(c).json()['host_id'] == '111'
    assert ('GET', '/applications/12345/activity-instances/room-one') in env.calls
    stranger = client(env, '333')
    assert join(stranger).status_code == 403
    assert join(stranger, 'room-two').json()['host_id'] == '333'
    assert stranger.get('/discord/activity/state?instance_id=room-one').status_code == 403
    env.members['room-one'] = []
    env.clock[0] += activity.MEMBERSHIP_TTL + 1
    assert c.get('/discord/activity/state?instance_id=room-one').status_code == 403


def test_host_controls_sync_and_explicit_handoff(env):
    host, viewer = client(env), client(env, '222')
    assert join(host).json()['is_host'] is True
    assert join(viewer).json()['is_host'] is False
    assert post(viewer, 'control', instance_id='room-one', action='select', sn='101').status_code == 403
    assert post(host, 'control', instance_id='room-one', action='select', sn='101').json()['sn'] == '101'
    state = post(host, 'control', instance_id='room-one', action='play', position=12, rate=1.5).json()
    assert state['paused'] is False and state['position'] == 12 and state['rate'] == 1.5
    env.clock[0] += 4
    state = viewer.get('/discord/activity/state?instance_id=room-one').json()
    assert state['position'] == 12 and state['server_time'] - state['updated_at'] == 4
    state = post(host, 'control', instance_id='room-one', action='pause').json()
    assert state['position'] == 18 and state['paused'] is True
    state = post(host, 'leave', instance_id='room-one').json()
    assert state['host_id'] == '222'
    assert post(viewer, 'control', instance_id='room-one', action='seek', position=90).json()['position'] == 90


def test_select_resets_previous_episode_snapshot(env):
    c = client(env)
    join(c)
    post(c, 'control', instance_id='room-one', action='select', sn='101')
    post(c, 'control', instance_id='room-one', action='play', position=240, rate=2)
    state = post(c, 'control', instance_id='room-one', action='select', sn='102',
                 position=240, rate=2, paused=False).json()
    assert state['sn'] == '102'
    assert state['position'] == 0 and state['paused'] is True and state['rate'] == 1


def test_queued_previous_episode_control_cannot_mutate_new_episode(env):
    c = client(env)
    join(c)
    post(c, 'control', instance_id='room-one', action='select', sn='101')
    selected = post(c, 'control', instance_id='room-one', action='select', sn='102').json()
    stale = post(c, 'control', instance_id='room-one', action='sync', expected_sn='101',
                 position=240, rate=2, paused=False)
    assert stale.status_code == 409 and stale.json()['error'] == 'stale_video'
    state = c.get('/discord/activity/state?instance_id=room-one').json()
    assert state['sn'] == '102' and state['position'] == 0 and state['paused'] is True
    assert state['revision'] == selected['revision']
    current = post(c, 'control', instance_id='room-one', action='play', expected_sn='102', position=1)
    assert current.status_code == 200 and current.json()['paused'] is False


def test_stale_host_is_replaced_and_rejoin_does_not_steal_control(env):
    host, viewer = client(env), client(env, '222')
    join(host)
    join(viewer)
    env.clock[0] += 15
    viewer.get('/discord/activity/state?instance_id=room-one')
    env.clock[0] += 6
    state = viewer.get('/discord/activity/state?instance_id=room-one').json()
    assert state['host_id'] == '222'
    assert join(host).json()['host_id'] == '222'


def test_last_tab_only_leaves_host_slot(env):
    host, same_user, viewer = client(env), client(env), client(env, '222')
    join(host)
    join(same_user)
    join(viewer)
    assert post(host, 'leave', instance_id='room-one').json()['host_id'] == '111'
    assert post(same_user, 'leave', instance_id='room-one').json()['host_id'] == '222'


@pytest.mark.parametrize('payload', [
    {'action': 'seek', 'position': -1}, {'action': 'seek', 'position': True},
    {'action': 'rate', 'rate': 0}, {'action': 'sync', 'paused': 'false'},
    {'action': 'seek'}, {'action': 'rate'}, {'action': 'invent'},
    {'action': 'select', 'sn': '999'}, {'action': 'select', 'sn': '../101'},
])
def test_invalid_control_never_changes_shared_state(env, payload):
    c = client(env)
    join(c)
    post(c, 'control', instance_id='room-one', action='select', sn='101')
    before = copy.deepcopy(env.backend.rooms['room-one'])
    response = post(c, 'control', instance_id='room-one', **payload)
    assert response.status_code in (400, 404)
    assert env.backend.rooms['room-one']['sn'] == before['sn']
    assert env.backend.rooms['room-one']['position'] == before['position']
    assert env.backend.rooms['room-one']['revision'] == before['revision']


def test_session_expiry_and_disabled_watch_are_enforced(env):
    c = client(env)
    join(c)
    env.settings['dashboard']['online_watch'] = False
    assert c.get('/discord/activity/state?instance_id=room-one').status_code == 404
    assert post(c, 'control', instance_id='room-one', action='select', sn='101').status_code == 404
    env.settings['dashboard']['online_watch'] = True
    env.clock[0] += 3601
    assert c.get('/discord/activity/me').status_code == 401


def test_auth_bridge_requires_join_and_revalidates_identity(env):
    c = client(env)
    post(c, 'login', username='alice', password='alicepw')
    post(c, 'link')
    cookie = c.cookies.get(activity.COOKIE_NAME)
    request = Request({'type': 'http', 'headers': [(b'cookie', (activity.COOKIE_NAME + '=' + cookie).encode())]})
    assert env.backend.auth_user(request) is None
    join(c)
    assert env.backend.auth_user(request)['username'] == 'alice'
    env.data['users'][0].pop('discord_account')
    assert env.backend.auth_user(request) is None


def test_discord_transport_failure_never_leaks_credentials(env, monkeypatch):
    backend = activity.ActivityBackend(env.server)
    def fail(*args, **kwargs):
        raise RuntimeError('secret credentials must never be serialized')
    monkeypatch.setattr(activity.requests, 'request', fail)
    with pytest.raises(activity.ActivityError) as error:
        backend._discord_request('GET', '/users/@me', headers={'Authorization': 'secret'})
    assert error.value.error == 'discord_unavailable'
    assert 'secret' not in error.value.message


def guest_request(client, token, sn='101'):
    return Request({'type': 'http', 'headers': [
        (b'cookie', (activity.COOKIE_NAME + '=' + client.cookies.get(activity.COOKIE_NAME)).encode())],
        'query_string': urlencode({'id': sn, 'ag': token}).encode()})


def guest_room(env):
    env.settings['dashboard']['online_watch_requires_login'] = True
    host, guest = client(env), client(env, '222')
    # Being first into the lobby does not make an unlogged guest the host.
    assert join(guest).json()['host_id'] is None
    post(host, 'login', username='alice', password='alicepw')
    post(host, 'link')
    assert join(host).json()['host_id'] == '111'
    post(host, 'control', instance_id='room-one', action='select', sn='101')
    return host, guest


def authorize(host, guest):
    result = post(host, 'grant', instance_id='room-one', user_id='222', sn='101')
    assert result.status_code == 200
    # Tokens never appear in the host's own response or another member object.
    assert result.json()['watch_token'] is None
    state = guest.get('/discord/activity/state?instance_id=room-one').json()
    assert state['can_watch'] is True and isinstance(state['watch_token'], str)
    return state['watch_token']


def test_guest_grant_is_one_episode_one_member_and_one_session(env):
    host, guest = guest_room(env)
    token = authorize(host, guest)
    access = env.backend.guest_access(guest_request(guest, token))
    assert access['sn'] == '101' and access['user_id'] == '222'
    assert 'token' not in access and 'alice-token' not in str(access)
    assert access['expires'] <= env.clock[0] + activity.GUEST_GRANT_TTL
    assert access['expires'] <= env.backend.sessions[host.cookies.get(activity.COOKIE_NAME)]['expires']
    assert env.backend.guest_access(guest_request(guest, token, '102')) is None
    assert env.backend.guest_access(guest_request(host, token)) is None
    assert env.backend.guest_access(guest_request(guest, token + 'wrong')) is None
    new_session = client(env, '222')
    join(new_session)
    assert env.backend.guest_access(guest_request(new_session, token)) is None
    assert new_session.get('/discord/activity/state?instance_id=room-one').json()['watch_token'] is None
    assert post(guest, 'control', instance_id='room-one', action='pause').status_code == 403
    assert post(guest, 'grant', instance_id='room-one', user_id='111', sn='101').status_code == 403


def test_grants_require_current_logged_in_host_and_current_joined_target(env):
    host, guest = guest_room(env)
    assert post(guest, 'grant', instance_id='room-one', user_id='111', sn='101').status_code == 403
    assert post(host, 'grant', instance_id='room-one', user_id='333', sn='101').status_code == 404
    assert post(host, 'grant', instance_id='room-one', user_id='222', sn='102').status_code == 409
    assert post(host, 'grant', instance_id='room-one', user_id='222').status_code == 400
    post(host, 'logout')
    assert post(host, 'grant', instance_id='room-one', user_id='222', sn='101').status_code == 403


def test_regrant_rotates_token_and_revoke_takes_effect_immediately(env):
    host, guest = guest_room(env)
    original = authorize(host, guest)
    replacement = authorize(host, guest)
    assert original != replacement
    assert env.backend.guest_access(guest_request(guest, original)) is None
    assert env.backend.guest_access(guest_request(guest, replacement)) is not None
    revoked = post(host, 'revoke', instance_id='room-one', user_id='222', sn='101')
    assert revoked.status_code == 200
    assert env.backend.guest_access(guest_request(guest, replacement)) is None
    state = guest.get('/discord/activity/state?instance_id=room-one').json()
    assert state['can_watch'] is False and state['watch_token'] is None
    assert next(m for m in state['members'] if m['id'] == '222')['requires_approval'] is True


@pytest.mark.parametrize('revocation', [
    'select', 'select_same_sn', 'host_leave', 'host_logout', 'host_password_reset',
    'host_unlink', 'host_change_account', 'guest_leave', 'guest_membership',
    'host_membership', 'grant_expiry', 'lease_expiry',
])
def test_guest_token_revocation_and_room_binding(env, revocation):
    host, guest = guest_room(env)
    token = authorize(host, guest)
    if revocation.startswith('select'):
        post(host, 'control', instance_id='room-one', action='select', sn='101' if revocation == 'select_same_sn' else '102')
    elif revocation == 'host_leave':
        post(host, 'leave', instance_id='room-one')
    elif revocation == 'host_logout':
        post(host, 'logout')
    elif revocation == 'host_password_reset':
        env.data['users'][0]['token'] = 'rotated-alice-token'
    elif revocation == 'host_unlink':
        post(host, 'unlink')
    elif revocation == 'host_change_account':
        post(host, 'login', username='bob', password='bobpw')
    elif revocation == 'guest_leave':
        post(guest, 'leave', instance_id='room-one')
    elif revocation in ('guest_membership', 'host_membership'):
        env.members['room-one'] = ['111'] if revocation == 'guest_membership' else ['222']
        env.clock[0] += activity.MEMBERSHIP_TTL + 1
    elif revocation == 'grant_expiry':
        env.backend.rooms['room-one']['grants']['222']['expires'] = env.clock[0] - 1
    else:
        env.clock[0] += activity.MEMBER_LEASE + 1
    assert env.backend.guest_access(guest_request(guest, token)) is None


def test_guest_does_not_inherit_host_and_handoff_revokes_existing_grant(env):
    host, guest = guest_room(env)
    token = authorize(host, guest)
    env.members['room-one'].append('333')
    next_host = client(env, '333')
    post(next_host, 'login', username='bob', password='bobpw')
    join(next_host)
    state = post(host, 'leave', instance_id='room-one').json()
    assert state['host_id'] == '333'
    assert env.backend.guest_access(guest_request(guest, token)) is None
    assert guest.get('/discord/activity/state?instance_id=room-one').json()['is_host'] is False
    assert post(next_host, 'control', instance_id='room-one', action='pause').status_code == 200


def test_guest_capability_cannot_move_between_rooms(env):
    host, guest = guest_room(env)
    token = authorize(host, guest)
    env.members['room-two'].append('222')
    assert join(guest, 'room-two').status_code == 200
    assert env.backend.guest_access(guest_request(guest, token)) is None


def test_logout_and_relogin_without_guest_poll_cannot_restore_old_capability(env):
    host, guest = guest_room(env)
    token = authorize(host, guest)
    post(host, 'logout')
    post(host, 'login', username='alice', password='alicepw')
    assert env.backend.guest_access(guest_request(guest, token)) is None
    assert guest.get('/discord/activity/state?instance_id=room-one').json()['can_watch'] is False


def test_guest_reauthentication_cannot_restore_prior_session_grant(env):
    host, guest = guest_room(env)
    token = authorize(host, guest)
    post(guest, 'token', code='222')
    join(guest)
    assert env.backend.guest_access(guest_request(guest, token)) is None


def toggle_auto(host, enabled=True):
    return post(host, 'auto-grant', instance_id='room-one', enabled=enabled)


def test_auto_grant_defaults_off_and_requires_a_logged_in_host(env):
    host, guest = guest_room(env)
    state = host.get('/discord/activity/state?instance_id=room-one').json()
    assert state['auto_grant'] is False and state['auto_grant_available'] is True
    assert guest.get('/discord/activity/state?instance_id=room-one').json()['auto_grant_available'] is False
    assert toggle_auto(guest).status_code == 403
    for value in ('true', 1, None, []):
        assert toggle_auto(host, value).status_code == 400
    no_csrf = host.post('/discord/activity/auto-grant', json={'instance_id': 'room-one', 'enabled': True},
                        headers={'X-Activity-CSRF': ''})
    assert no_csrf.status_code == 403
    post(host, 'logout')
    assert toggle_auto(host).status_code == 403


def test_auto_grant_covers_current_guests_future_guests_and_new_tabs_without_poll_rotation(env):
    host, guest = guest_room(env)
    enabled = toggle_auto(host)
    assert enabled.status_code == 200 and enabled.json()['auto_grant'] is True
    state = guest.get('/discord/activity/state?instance_id=room-one').json()
    token = state['watch_token']
    assert state['can_watch'] is True
    assert env.backend.guest_access(guest_request(guest, token)) is not None
    assert toggle_auto(host).json()['auto_grant'] is True
    assert guest.get('/discord/activity/state?instance_id=room-one').json()['watch_token'] == token
    assert token not in host.get('/discord/activity/state?instance_id=room-one').text
    extra_tab = client(env, '222')
    joined = join(extra_tab).json()
    assert joined['watch_token'] == token
    assert env.backend.guest_access(guest_request(extra_tab, token)) is not None
    env.members['room-one'].append('333')
    newcomer = client(env, '333')
    joined = join(newcomer).json()
    assert joined['can_watch'] is True and joined['watch_token'] != token
    assert env.backend.guest_access(guest_request(newcomer, joined['watch_token'])) is not None


def test_auto_grant_can_be_enabled_before_a_video_is_selected(env):
    env.settings['dashboard']['online_watch_requires_login'] = True
    host, guest = client(env), client(env, '222')
    post(host, 'login', username='alice', password='alicepw')
    join(host)
    join(guest)
    assert toggle_auto(host).json()['auto_grant'] is True
    assert guest.get('/discord/activity/state?instance_id=room-one').json()['watch_token'] is None
    post(host, 'control', instance_id='room-one', action='select', sn='101')
    assert guest.get('/discord/activity/state?instance_id=room-one').json()['can_watch'] is True


def test_auto_grant_issues_a_fresh_episode_capability_for_each_selection(env):
    host, guest = guest_room(env)
    toggle_auto(host)
    tokens = [guest.get('/discord/activity/state?instance_id=room-one').json()['watch_token']]
    for sn in ('102', '101', '101'):
        selected = post(host, 'control', instance_id='room-one', action='select', sn=sn)
        assert selected.json()['auto_grant'] is True
        state = guest.get('/discord/activity/state?instance_id=room-one').json()
        current = state['watch_token']
        assert state['can_watch'] is True and current not in tokens
        assert env.backend.guest_access(guest_request(guest, current, sn)) is not None
        for old in tokens:
            assert env.backend.guest_access(guest_request(guest, old, sn)) is None
        tokens.append(current)


def test_disabling_auto_grant_keeps_manual_access_but_removes_automatic_tabs_and_guests(env):
    host, guest = guest_room(env)
    manual = authorize(host, guest)
    toggle_auto(host)
    extra_tab = client(env, '222')
    assert join(extra_tab).json()['watch_token'] == manual
    env.members['room-one'].append('333')
    newcomer = client(env, '333')
    auto_token = join(newcomer).json()['watch_token']
    assert env.backend.guest_access(guest_request(newcomer, auto_token)) is not None
    disabled = toggle_auto(host, False)
    assert disabled.json()['auto_grant'] is False
    assert env.backend.guest_access(guest_request(guest, manual)) is not None
    assert env.backend.guest_access(guest_request(extra_tab, manual)) is None
    assert env.backend.guest_access(guest_request(newcomer, auto_token)) is None


def test_manual_revoke_suppresses_automatic_regrant_until_next_selection(env):
    host, guest = guest_room(env)
    toggle_auto(host)
    old = guest.get('/discord/activity/state?instance_id=room-one').json()['watch_token']
    post(host, 'revoke', instance_id='room-one', user_id='222', sn='101')
    for _ in range(3):
        state = guest.get('/discord/activity/state?instance_id=room-one').json()
        assert state['auto_grant'] is True and state['can_watch'] is False
    assert env.backend.guest_access(guest_request(guest, old)) is None
    toggle_auto(host, False)
    toggle_auto(host)
    assert guest.get('/discord/activity/state?instance_id=room-one').json()['can_watch'] is False
    post(host, 'control', instance_id='room-one', action='select', sn='102')
    assert guest.get('/discord/activity/state?instance_id=room-one').json()['can_watch'] is True


def test_explicit_manual_grant_clears_auto_grant_suppression(env):
    host, guest = guest_room(env)
    toggle_auto(host)
    post(host, 'revoke', instance_id='room-one', user_id='222', sn='101')
    manual = authorize(host, guest)
    toggle_auto(host, False)
    assert env.backend.guest_access(guest_request(guest, manual)) is not None


@pytest.mark.parametrize('revocation', [
    'logout', 'reauthenticate', 'change_account', 'unlink', 'password_reset',
    'leave', 'session_expiry', 'membership_removed', 'lease_expiry',
])
def test_automatic_authorization_is_not_inherited_after_host_authority_changes(env, revocation):
    host, guest = guest_room(env)
    toggle_auto(host)
    token = guest.get('/discord/activity/state?instance_id=room-one').json()['watch_token']
    if revocation == 'logout':
        post(host, 'logout')
        post(host, 'login', username='alice', password='alicepw')
    elif revocation == 'reauthenticate':
        post(host, 'token', code='111')
        join(host)
    elif revocation == 'change_account':
        post(host, 'login', username='bob', password='bobpw')
    elif revocation == 'unlink':
        post(host, 'unlink')
    elif revocation == 'password_reset':
        env.data['users'][0]['token'] = 'new-alice-token'
    elif revocation == 'leave':
        post(host, 'leave', instance_id='room-one')
    elif revocation == 'session_expiry':
        env.backend.sessions[host.cookies.get(activity.COOKIE_NAME)]['expires'] = env.clock[0] - 1
    elif revocation == 'membership_removed':
        env.members['room-one'] = ['222']
        env.clock[0] += activity.MEMBERSHIP_TTL + 1
    else:
        env.clock[0] += activity.MEMBER_LEASE + 1
        join(guest)
    state = guest.get('/discord/activity/state?instance_id=room-one').json()
    assert state['auto_grant'] is False and state['watch_token'] is None
    assert env.backend.guest_access(guest_request(guest, token)) is None


def test_auto_grant_does_not_transfer_to_the_next_logged_in_host(env):
    host, guest = guest_room(env)
    toggle_auto(host)
    env.members['room-one'].append('333')
    successor = client(env, '333')
    post(successor, 'login', username='bob', password='bobpw')
    join(successor)
    post(host, 'leave', instance_id='room-one')
    state = successor.get('/discord/activity/state?instance_id=room-one').json()
    assert state['is_host'] is True and state['auto_grant_available'] is True
    assert state['auto_grant'] is False
    assert guest.get('/discord/activity/state?instance_id=room-one').json()['can_watch'] is False


def test_presence_scope_upgrade_preserves_watch_identity_room_and_guest_grants(env, monkeypatch):
    host, guest = guest_room(env)
    toggle_auto(host)
    token = guest.get('/discord/activity/state?instance_id=room-one').json()['watch_token']
    sid = host.cookies.get(activity.COOKIE_NAME)
    session = env.backend.sessions[sid]
    before = {key: value for key, value in session.items() if key != 'operation_lock'}
    before_room = copy.deepcopy(env.backend.rooms['room-one'])
    calls = []
    def discord_request(method, path, **kwargs):
        calls.append((method, path))
        if path == '/oauth2/token':
            assert kwargs['data']['code'] == 'presence-code'
            return {'access_token': 'temporary-presence-token',
                    'scope': 'identify applications.commands rpc.activities.write', 'expires_in': 999999}
        return {'id': '111', 'username': 'discord-111'}
    monkeypatch.setattr(env.backend, '_discord_request', discord_request)
    response = post(host, 'presence-token', code='presence-code')
    assert response.status_code == 200 and response.json() == {'access_token': 'temporary-presence-token'}
    assert calls == [('POST', '/oauth2/token'), ('GET', '/users/@me')]
    assert {key: value for key, value in session.items() if key != 'operation_lock'} == before
    assert env.backend.rooms['room-one'] == before_room
    assert 'temporary-presence-token' not in str(session)
    # The original viewing capability remains valid after upgrading the SDK.
    assert env.backend.guest_access(guest_request(guest, token)) is not None


@pytest.mark.parametrize('scope', ['', 'identify applications.commands', 'rpc.activities.write', None, []])
def test_presence_token_requires_identify_and_activity_write_scopes(env, monkeypatch, scope):
    c = client(env)
    monkeypatch.setattr(env.backend, '_discord_request', lambda *args, **kwargs: {
        'access_token': 'temporary-presence-token', 'scope': scope})
    response = post(c, 'presence-token', code='presence-code')
    assert response.status_code == 403 and response.json()['error'] == 'presence_scope_required'
    assert 'temporary-presence-token' not in response.text


def test_presence_token_rejects_other_discord_account(env, monkeypatch):
    c = client(env)
    monkeypatch.setattr(env.backend, '_discord_request', lambda method, path, **kwargs:
        {'access_token': 'temporary-presence-token', 'scope': 'identify rpc.activities.write'}
        if path == '/oauth2/token' else {'id': '222'})
    response = post(c, 'presence-token', code='presence-code')
    assert response.status_code == 403 and response.json()['error'] == 'discord_identity_mismatch'
    assert 'temporary-presence-token' not in response.text
    assert env.backend.sessions[c.cookies.get(activity.COOKIE_NAME)]['user']['id'] == '111'


def test_presence_token_requires_activity_identity_csrf_and_valid_code(env):
    c = TestClient(env.server.app, base_url='https://activity.test')
    bootstrap = c.get('/discord/activity/config').json()
    c.headers['X-Activity-CSRF'] = bootstrap['csrf_token']
    assert post(c, 'presence-token', code='presence-code').status_code == 401
    c = client(env)
    assert c.post('/discord/activity/presence-token', json={'code': 'presence-code'},
                  headers={'X-Activity-CSRF': ''}).status_code == 403
    for code in (None, '', [], 123, 'x' * 4097):
        assert post(c, 'presence-token', code=code).status_code == 400
