# -*- coding: utf-8 -*-
"""redownload 指令: redownload <sn|all> [解析度] [all|one]."""

import os
import sys
import threading
import time
import types

import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

for _name in ('pip_system_certs', 'pip_system_certs.wrapt_requests', 'selenium_recaptcha_solver'):
    if _name not in sys.modules:
        _stub = types.ModuleType(_name)
        if _name == 'selenium_recaptcha_solver':
            _stub.RecaptchaSolver = object
            _stub.StandardDelayConfig = object
        sys.modules[_name] = _stub

agp = pytest.importorskip('aniGamerPlus')


class FakeAnime:
    def __init__(self, sn=100, new_path='', episodes=None):
        self.sn = sn
        self.video_size = 0
        self.video_resolution = 0
        self.local_video_path = ''
        self.upload_succeed_flag = False
        self.new_path = new_path
        self.episodes = episodes or {'1': sn}
        self.download_calls = []

    def download(self, resolution, **kwargs):
        self.download_calls.append((resolution, kwargs))
        self.video_resolution = int(resolution)
        self.video_size = 100
        self.local_video_path = self.new_path

    def get_sn(self):
        return self.sn

    def get_title(self):
        return '測試標題'

    def get_bangumi_name(self):
        return '測試番劇'

    def get_episode(self):
        return '1'

    def get_episode_list(self):
        return self.episodes


@pytest.fixture
def env(monkeypatch):
    monkeypatch.setattr(agp, 'queue', {})
    monkeypatch.setattr(agp, 'processing_queue', [])
    monkeypatch.setattr(agp, 'sn_dict', {})
    monkeypatch.setattr(agp.Config, 'current_sn_list_all', {})
    monkeypatch.setitem(agp.settings, 'download_resolution', '1080')
    started = []
    monkeypatch.setattr(agp, 'worker_thread', lambda sn, info: started.append((sn, info)))
    db = {}

    def read_db(sn):
        if sn not in db:
            raise IndexError
        return db[sn]

    monkeypatch.setattr(agp, 'read_db', read_db)
    monkeypatch.setattr(agp, 'read_db_all', lambda: list(db.values()))
    return types.SimpleNamespace(started=started, db=db)


def _row(sn, resolution, status=1):
    return {'sn': sn, 'status': status, 'resolution': resolution}


def _wait_started(env, count):
    # _schedule_redownload 是開執行緒去跑 worker_thread 的
    deadline = time.monotonic() + 2
    while len(env.started) < count and time.monotonic() < deadline:
        time.sleep(0.01)
    time.sleep(0.05)  # 多等一下, 抓出派了太多條的情況
    assert len(env.started) == count


@pytest.mark.parametrize('raw', [
    'redownload',
    'redownload abc',
    'redownload 123 999',
    'redownload 123 1080 some',
    'redownload 123 1080 all extra',
    'redownload all one',
    'redownload all 720 all',
])
def test_rejects_bad_arguments(env, raw):
    result = agp.execute_control_command(raw)
    assert result['success'] is False
    assert 'redownload' in result['message']
    assert env.started == []


def test_single_sn_defaults_to_one_episode(env):
    result = agp.execute_control_command('redownload 123 720p')

    assert result['success'] is True
    _wait_started(env, 1)
    sn, info = env.started[0]
    assert sn == 123
    assert info['resolution'] == '720'
    assert info['redownload'] is True
    assert agp.processing_queue == [123]
    assert agp.queue[123] is info


def test_resolution_defaults_to_config(env):
    agp.execute_control_command('redownload 123 one')
    _wait_started(env, 1)
    assert env.started[0][1]['resolution'] == '1080'


def test_sn_all_redownloads_whole_series_with_subscription_settings(env, monkeypatch):
    agp.sn_dict[202] = {'mode': 'all', 'tag': '新番', 'rename': '改名'}
    episodes = {'1': 201, '2': 202, '3': 203}
    monkeypatch.setattr(agp, 'build_anime',
                        lambda s: {'failed': False, 'anime': FakeAnime(sn=s, episodes=episodes)})

    result = agp.execute_control_command('redownload 201 480 all')

    assert result['success'] is True
    _wait_started(env, 3)
    assert sorted(sn for sn, _ in env.started) == [201, 202, 203]
    for _, info in env.started:
        assert info['tag'] == '新番' and info['rename'] == '改名'
        assert info['resolution'] == '480'


def test_all_only_takes_downloaded_rows_and_skips_running_tasks(env):
    for row in (_row(1, 480), _row(2, 480, status=0), _row(3, 480)):
        env.db[row['sn']] = row
    agp.processing_queue.append(3)

    result = agp.execute_control_command('redownload all 720')

    _wait_started(env, 1)
    assert env.started[0][0] == 1
    assert '略過 1 個正在進行中' in result['message']


def test_all_skips_episodes_already_at_target_resolution(env):
    for row in (_row(1, 720), _row(2, 1080), _row(3, 720), _row(4, 1080)):
        env.db[row['sn']] = row

    result = agp.execute_control_command('redownload all 1080')

    _wait_started(env, 2)
    assert sorted(sn for sn, _ in env.started) == [1, 3]
    assert '略過 2 個已是 1080P' in result['message']


def test_sn_all_skips_up_to_date_but_keeps_missing_episodes(env, monkeypatch):
    env.db[201] = _row(201, 1080)
    env.db[202] = _row(202, 720)
    episodes = {'1': 201, '2': 202, '3': 203}  # 203 還沒下載過
    monkeypatch.setattr(agp, 'build_anime',
                        lambda s: {'failed': False, 'anime': FakeAnime(sn=s, episodes=episodes)})

    agp.execute_control_command('redownload 201 1080 all')

    _wait_started(env, 2)
    assert sorted(sn for sn, _ in env.started) == [202, 203]


def test_nothing_to_do_when_everything_is_up_to_date(env):
    env.db[123] = _row(123, 1080)

    result = agp.execute_control_command('redownload 123 1080')

    assert result['success'] is True
    assert '都已經是 1080P' in result['message']
    _wait_started(env, 0)


def test_worker_redownload_replaces_old_file(monkeypatch, tmp_path):
    old_video = tmp_path / '番[1][720P].mp4'
    old_danmu = tmp_path / '番[1][720P].ass'
    old_video.write_bytes(b'old')
    old_danmu.write_text('danmu', encoding='utf-8')
    new_video = tmp_path / '番[1][1080P].mp4'
    new_video.write_bytes(b'new')

    monkeypatch.setattr(agp, 'thread_limiter', threading.Semaphore(1))
    monkeypatch.setattr(agp, 'queue', {})
    monkeypatch.setattr(agp, 'processing_queue', [])
    monkeypatch.setattr(agp, 'download_cd_counter', lambda: agp.thread_limiter.release())
    monkeypatch.setitem(agp.settings, 'upload_to_server', True)
    monkeypatch.setitem(agp.settings['dashboard'], 'online_watch', False)
    # 已下載、未上傳: 一般情況會走「僅上傳」, 重新下載必須跳過它
    monkeypatch.setattr(agp, 'read_db', lambda s: {
        'sn': 100, 'status': 1, 'remote_status': 0, 'resolution': 720,
        'file_size': 10, 'local_file_path': str(old_video)})
    anime = FakeAnime(new_path=str(new_video))
    monkeypatch.setattr(agp, 'build_anime', lambda s: {'failed': False, 'anime': anime})
    monkeypatch.setattr(agp, 'update_db', lambda a: None)
    monkeypatch.setattr(agp, 'insert_db', lambda a: pytest.fail('資料庫已有這筆, 不該再 insert'))
    monkeypatch.setattr(agp, 'upload_video', lambda a, bangumi_tag='': True)

    info = {'tag': '', 'rename': '', 'resolution': '1080', 'redownload': True}
    agp.processing_queue.append(100)
    agp.queue[100] = info
    agp.worker_thread(100, info)

    assert anime.download_calls[0][0] == '1080'
    assert not old_video.exists()
    assert not old_danmu.exists()
    assert (tmp_path / '番[1][1080P].ass').read_text(encoding='utf-8') == 'danmu'
    assert new_video.exists()
    assert agp.processing_queue == []


def test_worker_redownload_registers_missing_db_row(monkeypatch, tmp_path):
    monkeypatch.setattr(agp, 'thread_limiter', threading.Semaphore(1))
    monkeypatch.setattr(agp, 'queue', {})
    monkeypatch.setattr(agp, 'processing_queue', [])
    monkeypatch.setattr(agp, 'download_cd_counter', lambda: agp.thread_limiter.release())
    monkeypatch.setitem(agp.settings, 'upload_to_server', False)
    monkeypatch.setitem(agp.settings['dashboard'], 'online_watch', False)

    def not_in_db(sn):
        raise IndexError

    monkeypatch.setattr(agp, 'read_db', not_in_db)
    anime = FakeAnime(new_path=str(tmp_path / 'new.mp4'))
    monkeypatch.setattr(agp, 'build_anime', lambda s: {'failed': False, 'anime': anime})
    calls = []
    monkeypatch.setattr(agp, 'insert_db', lambda a: calls.append('insert'))
    monkeypatch.setattr(agp, 'update_db', lambda a: calls.append('update'))

    info = {'tag': '', 'rename': '', 'resolution': '720', 'redownload': True}
    agp.processing_queue.append(100)
    agp.worker_thread(100, info)

    assert calls == ['insert', 'update']
    assert agp.processing_queue == []
