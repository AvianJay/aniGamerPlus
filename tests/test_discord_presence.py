"""Encrypted Discord sync: identity isolation, validation and credential lifecycle."""
import base64
import copy

import pytest
from fastapi.testclient import TestClient
from starlette.requests import Request

import Dashboard.Server as server


def envelope():
    b64 = lambda length: base64.b64encode(b'x' * length).decode('ascii')
    return {'v': 1, 'kdf': 'pbkdf2-sha256', 'iterations': 600000,
            'salt': b64(16), 'nonce': b64(12), 'ciphertext': b64(100), 'mac': b64(16)}


@pytest.fixture
def env(monkeypatch):
    settings = {'dashboard': {'user_control': {'enabled': True}}}
    data = {'users': [
        {'username': 'alice', 'password': 'alicepw1', 'token': 'alice-session',
         'role': 'user', 'videotimes': {}},
        {'username': 'admin', 'password': 'adminpw1', 'token': 'admin-session',
         'role': 'admin', 'videotimes': {}},
    ]}
    monkeypatch.setattr(server, '_get_current_settings', lambda: settings)
    monkeypatch.setattr(server, 'load_user_data', lambda: copy.deepcopy(data))
    def save(value):
        data.clear()
        data.update(copy.deepcopy(value))
    monkeypatch.setattr(server, 'save_user_data', save)
    client = TestClient(server.app)
    client.cookies.set('token', 'alice-session')
    return client, settings, data


def test_ciphertext_roundtrip_and_account_isolation(env):
    client, _, data = env
    value = envelope()
    assert client.put('/user/discord', json=value).status_code == 200
    result = client.get('/user/discord')
    assert result.json() == {'credentials': value}
    assert result.headers['cache-control'] == 'no-store'
    assert data['users'][0]['discord_presence'] == value
    assert 'discord_presence' not in client.post('/userinfo', json={'action': 'get'}).json()
    client.cookies.set('token', 'admin-session')
    assert client.get('/user/discord').json() == {'credentials': None}
    assert client.delete('/user/discord').status_code == 200
    assert data['users'][0]['discord_presence'] == value
    client.cookies.set('token', 'alice-session')
    assert client.delete('/user/discord').status_code == 200
    assert client.get('/user/discord').json() == {'credentials': None}


@pytest.mark.parametrize('change', [
    {'token': 'never-accept-plaintext'}, {'v': True}, {'iterations': 1},
    {'salt': 'invalid!'}, {'nonce': ''}, {'mac': base64.b64encode(b'x').decode()},
    {'ciphertext': base64.b64encode(b'x' * 4097).decode()},
])
def test_rejects_plaintext_or_malformed_envelope(env, change):
    client, _, data = env
    assert client.put('/user/discord', json={**envelope(), **change}).status_code == 400
    assert 'discord_presence' not in data['users'][0]


def test_authentication_precedes_body_parsing_and_disabled_accounts(env, monkeypatch):
    client, settings, _ = env
    async def forbidden_parse(self):
        raise AssertionError('unauthenticated body parsed')
    monkeypatch.setattr(Request, 'json', forbidden_parse)
    client.cookies.clear()
    assert client.put('/user/discord', content=b'bad json').status_code == 401
    settings['dashboard']['user_control']['enabled'] = False
    client.cookies.set('token', 'alice-session')
    for method in ('get', 'put', 'delete'):
        assert getattr(client, method)('/user/discord').status_code == 404


@pytest.mark.parametrize('admin_reset', [False, True])
def test_password_changes_discard_old_password_ciphertext(env, admin_reset):
    client, _, data = env
    assert client.put('/user/discord', json=envelope()).status_code == 200
    if admin_reset:
        client.cookies.set('token', 'admin-session')
        result = client.post('/usermanage', json={
            'action': 'change', 'username': 'alice', 'password': 'newalicepw'})
    else:
        result = client.post('/userinfo', json={'action': 'changepassword',
            'original_password': 'alicepw1', 'new_password1': 'newalicepw',
            'new_password2': 'newalicepw'})
    assert result.status_code == 200
    assert 'discord_presence' not in data['users'][0]
    assert data['users'][0]['token'] != 'alice-session'
