# -*- coding: utf-8 -*-
"""下載/上傳併發限制器不可以在失敗路徑上漏名額.

upload_limiter 和 thread_limiter 都是 Semaphore. 只要有一條錯誤路徑忘了 release,
名額就永久少一個; 漏滿之後所有 worker 都會卡死在 acquire() 上, 使用者看到的現象
就是「下載停住了, 也沒有任何錯誤」—— 這正是 OneDrive 配額爆掉那次的災情.
"""

import os
import sqlite3
import sys
import threading
import types

import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

# aniGamerPlus 在 import 時就會拉進這幾個第三方套件, 測試環境不見得裝得到,
# 但它們跟這裡要驗的邏輯完全無關, 塞個空殼進去即可.
for _name in ('pip_system_certs', 'pip_system_certs.wrapt_requests', 'selenium_recaptcha_solver'):
    if _name not in sys.modules:
        _stub = types.ModuleType(_name)
        if _name == 'selenium_recaptcha_solver':
            _stub.RecaptchaSolver = object
            _stub.StandardDelayConfig = object
        sys.modules[_name] = _stub

agp = pytest.importorskip('aniGamerPlus')


class FakeAnime:
    def __init__(self, video_size=100):
        self.video_size = video_size
        self.video_resolution = 1080
        self.local_video_path = __file__
        self.upload_succeed_flag = False

    def download(self, *args, **kwargs):
        pass

    def upload(self, bangumi_tag=''):
        return False

    def get_sn(self):
        return 51229

    def get_title(self):
        return '測試標題'

    def get_bangumi_name(self):
        return '測試番劇'

    def get_episode(self):
        return '1'


@pytest.fixture
def isolated_limiters(monkeypatch):
    """給這次測試一組乾淨的限制器與列隊."""
    upload_limiter = threading.Semaphore(1)
    thread_limiter = threading.Semaphore(1)
    monkeypatch.setattr(agp, 'upload_limiter', upload_limiter)
    monkeypatch.setattr(agp, 'thread_limiter', thread_limiter)
    monkeypatch.setattr(agp, 'queue', {})
    monkeypatch.setattr(agp, 'processing_queue', [])
    monkeypatch.setattr(agp, 'update_db', lambda anime: None)
    monkeypatch.setattr(agp, 'download_cd_counter', lambda: agp.thread_limiter.release())
    return types.SimpleNamespace(upload=upload_limiter, thread=thread_limiter)


def _enqueue(sn):
    info = {'tag': '', 'rename': ''}
    agp.queue[sn] = info
    agp.processing_queue.append(sn)
    return info


def _db_row(status, remote_status, local_file_path=__file__):
    return {
        'sn': 51229, 'title': 't', 'anime_name': 'a', 'episode': '1',
        'status': status, 'remote_status': remote_status,
        'resolution': 1080, 'file_size': 100,
        'local_file_path': local_file_path, 'timestamp': 0,
    }


def test_upload_only_releases_limiter_when_plugin_upload_explodes(monkeypatch, isolated_limiters):
    """OneDrive 配額爆掉(插件丟例外)之後, 上傳名額要還回來."""
    sn = 51229
    monkeypatch.setitem(agp.settings, 'upload_to_server', True)
    monkeypatch.setattr(agp, 'read_db', lambda s: _db_row(status=1, remote_status=0))
    monkeypatch.setattr(agp, 'build_anime', lambda s: {'failed': False, 'anime': FakeAnime()})

    def quota_exceeded(anime, bangumi_tag=''):
        raise RuntimeError('建立 OneDrive 上傳工作階段失敗: quotaLimitReached')

    monkeypatch.setattr(agp, 'upload_video', quota_exceeded)
    info = _enqueue(sn)

    agp.worker_thread(sn, info)

    assert isolated_limiters.upload.acquire(blocking=False), 'upload_limiter 的名額被漏掉了'
    assert sn not in agp.queue
    assert sn not in agp.processing_queue


def test_upload_only_survives_a_null_local_path(monkeypatch, isolated_limiters):
    """local_file_path 是 NULL 時舊寫法會 os.path.exists(None) 丟 TypeError."""
    sn = 51229
    monkeypatch.setitem(agp.settings, 'upload_to_server', True)
    monkeypatch.setattr(agp, 'read_db', lambda s: _db_row(status=1, remote_status=0, local_file_path=None))
    monkeypatch.setattr(agp, 'build_anime', lambda s: {'failed': False, 'anime': FakeAnime()})
    info = _enqueue(sn)

    agp.worker_thread(sn, info)

    assert isolated_limiters.upload.acquire(blocking=False), 'upload_limiter 的名額被漏掉了'
    assert sn not in agp.processing_queue


def test_download_releases_thread_limiter_when_db_write_explodes(monkeypatch, isolated_limiters):
    """下載完成但寫資料庫失敗時, 下載名額不能被吃掉."""
    sn = 51230
    monkeypatch.setitem(agp.settings, 'upload_to_server', False)
    monkeypatch.setattr(agp, 'read_db', lambda s: _db_row(status=0, remote_status=0))
    monkeypatch.setattr(agp, 'build_anime', lambda s: {'failed': False, 'anime': FakeAnime()})

    def db_locked(anime):
        raise sqlite3.OperationalError('database is locked')

    monkeypatch.setattr(agp, 'update_db', db_locked)
    info = _enqueue(sn)

    agp.worker_thread(sn, info)

    assert isolated_limiters.thread.acquire(blocking=False), 'thread_limiter 的名額被漏掉了'
    assert sn not in agp.processing_queue


def test_download_failure_releases_thread_limiter(monkeypatch, isolated_limiters):
    sn = 51231
    monkeypatch.setitem(agp.settings, 'upload_to_server', False)
    monkeypatch.setattr(agp, 'read_db', lambda s: _db_row(status=0, remote_status=0))
    monkeypatch.setattr(agp, 'build_anime', lambda s: {'failed': False, 'anime': FakeAnime(video_size=0)})
    info = _enqueue(sn)

    agp.worker_thread(sn, info)

    assert isolated_limiters.thread.acquire(blocking=False), 'thread_limiter 的名額被漏掉了'
    assert sn not in agp.processing_queue


def test_unreadable_db_row_does_not_wedge_the_task(monkeypatch, isolated_limiters):
    """讀不到資料庫也要把 sn 移出列隊, 否則它永遠不會被重試."""
    sn = 51232

    def boom(s):
        raise sqlite3.OperationalError('database is locked')

    monkeypatch.setattr(agp, 'read_db', boom)
    info = _enqueue(sn)

    agp.worker_thread(sn, info)

    assert sn not in agp.queue
    assert sn not in agp.processing_queue


def test_repeated_upload_failures_do_not_drain_the_limiter(monkeypatch, isolated_limiters):
    """連續失敗 N 次之後名額要還是滿的 —— 這是「下載慢慢卡死」的真正成因."""
    monkeypatch.setitem(agp.settings, 'upload_to_server', True)
    monkeypatch.setattr(agp, 'read_db', lambda s: _db_row(status=1, remote_status=0))
    monkeypatch.setattr(agp, 'build_anime', lambda s: {'failed': False, 'anime': FakeAnime()})

    def quota_exceeded(anime, bangumi_tag=''):
        raise RuntimeError('quotaLimitReached')

    monkeypatch.setattr(agp, 'upload_video', quota_exceeded)

    for sn in range(51240, 51250):
        agp.worker_thread(sn, _enqueue(sn))

    assert isolated_limiters.upload.acquire(blocking=False)
    assert agp.processing_queue == []


def test_db_locker_is_released_when_update_db_hits_a_bad_row(monkeypatch):
    """update_db 中途爆掉不能把全程序唯一的 db_locker 帶走."""
    locker = threading.Semaphore(1)
    monkeypatch.setattr(agp, 'db_locker', locker)
    monkeypatch.setattr(agp, 'db_path', 'file:not_a_real_db?mode=memory')

    class BrokenAnime(FakeAnime):
        def get_sn(self):
            raise ValueError('sn 壞了')

    with pytest.raises(ValueError):
        agp.update_db(BrokenAnime())

    assert locker.acquire(blocking=False), 'db_locker 沒有釋放, 整個程序的資料庫存取都會卡死'


def test_update_db_tolerates_a_null_video_size(monkeypatch):
    """僅上傳模式會把資料庫的 file_size 塞回 video_size, 它可能是 None."""
    locker = threading.Semaphore(1)
    monkeypatch.setattr(agp, 'db_locker', locker)
    written = {}

    class Recorder:
        def cursor(self):
            return self

        def execute(self, sql, params):
            written.update(params)

        def close(self):
            pass

        def commit(self):
            pass

    monkeypatch.setattr(agp.sqlite3, 'connect', lambda *a, **k: Recorder())

    anime = FakeAnime()
    anime.video_size = None
    agp.update_db(anime)

    assert written['status'] == 0
    assert locker.acquire(blocking=False)
