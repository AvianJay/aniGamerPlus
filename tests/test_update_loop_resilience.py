# -*- coding: utf-8 -*-
"""自動更新迴圈不可以被單一錯誤打死.

auto_update_loop 是唯一會派發下載任務的執行緒. 它只要拋出一次沒人接的例外就整個
結束, 程式表面上還活著(Dashboard 照開), 但從此不再檢查更新、不再發新任務 ——
使用者看到的就是「下載無法繼續」.
"""

import json
import os
import sys
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


def test_a_failed_cycle_does_not_kill_the_loop(monkeypatch):
    calls = []

    def cycle():
        calls.append(1)
        if len(calls) == 1:
            raise RuntimeError('插件在更新途中炸了')
        raise SystemExit  # 第二輪用來結束測試, auto_update_loop 只對 SystemExit 放行

    monkeypatch.setattr(agp, '_run_update_cycle', cycle)
    monkeypatch.setitem(agp.settings, 'check_frequency', 0)  # 不要真的等

    with pytest.raises(SystemExit):
        agp.auto_update_loop()

    assert len(calls) == 2, '第一輪失敗之後迴圈就死了, 不會再有下一輪更新'


def test_check_tasks_skips_a_broken_sn_and_keeps_going(monkeypatch):
    checked = []

    def check_one(sn):
        checked.append(sn)
        if sn == 'bad':
            raise RuntimeError('這部番的資料壞了')

    monkeypatch.setattr(agp, 'sn_dict', {'good1': {}, 'bad': {}, 'good2': {}})
    monkeypatch.setattr(agp, '_check_one_sn', check_one)

    agp.check_tasks()

    assert checked == ['good1', 'bad', 'good2'], '一部番出錯就不檢查後面的番了'


def _library(monkeypatch, tmp_path, rows, has_remote):
    empty_bangumi_dir = tmp_path / 'bangumi'
    empty_bangumi_dir.mkdir()
    monkeypatch.setattr(agp, 'working_dir', str(tmp_path))
    monkeypatch.setattr(agp, 'read_db_all', lambda: rows)
    monkeypatch.setattr(agp.Config, 'read_settings', lambda: {'bangumi_dir': str(empty_bangumi_dir)})
    monkeypatch.setattr(agp.plugin_manager, 'has_remote', lambda video_data: has_remote)
    return tmp_path / 'video_list.json'


def _row(local_file_path):
    return {
        'sn': 51229, 'title': '標題', 'anime_name': '番劇', 'episode': '1',
        'status': 1, 'remote_status': 1, 'resolution': 1080, 'file_size': 100,
        'local_file_path': local_file_path, 'timestamp': 0,
    }


def test_updatelist_handles_a_remote_only_entry_with_no_local_path(monkeypatch, tmp_path):
    """插件說雲端有、但本地沒有路徑時, 舊寫法會 None.replace() 直接炸掉 updatelist().

    updatelist() 是在 auto_update_loop 裡呼叫的, 炸了就把整條更新執行緒帶走.
    """
    out = _library(monkeypatch, tmp_path, [_row(local_file_path=None)], has_remote=True)

    agp.updatelist()

    videos = json.loads(out.read_text(encoding='utf-8'))['videos']
    assert len(videos) == 1
    assert videos[0]['danmu'] is False
    assert videos[0]['danmu_path'] is None


def test_updatelist_skips_an_entry_that_exists_nowhere(monkeypatch, tmp_path):
    out = _library(monkeypatch, tmp_path, [_row(local_file_path=None)], has_remote=False)

    agp.updatelist()

    assert json.loads(out.read_text(encoding='utf-8'))['videos'] == []


def test_updatelist_skips_an_unreadable_custom_library_file(monkeypatch, tmp_path):
    """一份壞掉的 .aniGamerPlus.json 不該讓整個片庫重建失敗."""
    bangumi_dir = tmp_path / 'bangumi'
    (bangumi_dir / 'broken').mkdir(parents=True)
    (bangumi_dir / 'broken' / '.aniGamerPlus.json').write_text('{ 這不是 JSON', encoding='utf-8')

    monkeypatch.setattr(agp, 'working_dir', str(tmp_path))
    monkeypatch.setattr(agp, 'read_db_all', lambda: [])
    monkeypatch.setattr(agp.Config, 'read_settings', lambda: {'bangumi_dir': str(bangumi_dir)})
    monkeypatch.setattr(agp.plugin_manager, 'has_remote', lambda video_data: False)

    agp.updatelist()  # 不該拋出

    assert json.loads((tmp_path / 'video_list.json').read_text(encoding='utf-8'))['videos'] == []
