"""Activity credentials use the normal config lifecycle and stay server-side."""
import copy
import json
from pathlib import Path
from types import SimpleNamespace

import pytest
from fastapi.testclient import TestClient

import Config
import Dashboard.Server as server
from Dashboard.discord_activity import ActivityBackend


SAMPLE = Path(__file__).resolve().parents[1] / 'config-sample.json'
EMPTY = {'client_id': '', 'client_secret': '', 'bot_token': ''}
CREDENTIALS = {'client_id': '12345', 'client_secret': 'test-config-secret',
               'bot_token': 'test-config-bot-token'}


@pytest.fixture
def isolated_config(tmp_path, monkeypatch):
    path = tmp_path / 'config.json'
    monkeypatch.setattr(Config, 'working_dir', str(tmp_path))
    monkeypatch.setattr(Config, 'config_path', str(path))
    monkeypatch.setattr(Config, 'logs_dir', str(tmp_path / 'logs'))
    monkeypatch.setattr(Config, 'sanitize_ja3', lambda value: value)
    (tmp_path / 'Dashboard').mkdir()
    return path


def test_new_config_includes_empty_activity_fields(isolated_config):
    settings = Config.read_settings()
    stored = json.loads(isolated_config.read_text(encoding='utf-8'))
    assert settings['dashboard']['discord_activity'] == EMPTY
    assert stored['dashboard']['discord_activity'] == EMPTY
    assert stored['config_version'] == Config.latest_config_version


@pytest.mark.parametrize('previous', [None, {'client_id': '12345', 'bot_token': 'test-existing-bot'}])
def test_upgrade_adds_missing_fields_and_preserves_existing_credentials(isolated_config, previous):
    settings = json.loads(SAMPLE.read_text(encoding='utf-8'))
    settings['config_version'] = 18.4
    if previous is None:
        settings['dashboard'].pop('discord_activity')
    else:
        settings['dashboard']['discord_activity'] = previous
    settings['dashboard']['online_watch_requires_login'] = True
    isolated_config.write_text(json.dumps(settings), encoding='utf-8')

    upgraded = Config.read_settings()
    expected = {**EMPTY, **(previous or {})}
    assert upgraded['dashboard']['discord_activity'] == expected
    assert upgraded['dashboard']['online_watch_requires_login'] is True
    assert upgraded['dashboard']['user_control'] == settings['dashboard']['user_control']
    stored = json.loads(isolated_config.read_text(encoding='utf-8'))
    assert stored['dashboard']['discord_activity'] == expected
    assert stored['config_version'] == Config.latest_config_version
    Config.write_settings(copy.deepcopy(upgraded))
    assert Config.read_settings()['dashboard']['discord_activity'] == expected


def test_activity_config_uses_config_json_even_if_legacy_environment_is_present(monkeypatch):
    for key in CREDENTIALS:
        monkeypatch.setenv('AGP_DISCORD_' + key.upper(), 'unused-environment-value')
    settings = {'dashboard': {'discord_activity': copy.deepcopy(CREDENTIALS)}}
    backend = ActivityBackend(SimpleNamespace(_get_current_settings=lambda: settings))
    assert backend.config() == CREDENTIALS
    settings['dashboard'].pop('discord_activity')
    assert backend.config() == EMPTY
    settings['dashboard']['discord_activity'] = {**CREDENTIALS, 'client_id': 12345}
    assert backend.config() == CREDENTIALS


@pytest.mark.parametrize('value', [None, [], 'invalid', False,
                                   {'client_id': True, 'client_secret': [], 'bot_token': {}}])
def test_malformed_activity_settings_do_not_enable_authentication(value):
    backend = ActivityBackend(SimpleNamespace(_get_current_settings=lambda: {
        'dashboard': {'discord_activity': value}}))
    assert backend.config() == EMPTY


def test_activity_secrets_are_absent_from_dashboard_responses(monkeypatch):
    settings = json.loads(SAMPLE.read_text(encoding='utf-8'))
    settings['dashboard']['online_watch'] = True
    settings['dashboard']['discord_activity'] = copy.deepcopy(CREDENTIALS)
    monkeypatch.setattr(server, '_get_current_settings', lambda: settings)
    monkeypatch.setattr(Config, 'read_settings', lambda: copy.deepcopy(settings))
    monkeypatch.setattr(server.discord_activity, 'sessions', {})
    client = TestClient(server.app, base_url='https://activity.test')
    for path in ('/discord/activity/config', '/discord/activity', '/get_server_info', '/data/config.json'):
        response = client.get(path)
        assert response.status_code == 200
        assert CREDENTIALS['client_secret'] not in response.text
        assert CREDENTIALS['bot_token'] not in response.text
    assert client.get('/discord/activity/config').json()['client_id'] == CREDENTIALS['client_id']
