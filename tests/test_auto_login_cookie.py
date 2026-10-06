# -*- coding: utf-8 -*-
"""自動登入拿到的新 cookie, 接下來的下載一定要讀得到.

兩個地方會自動登入: Config.invalid_cookie() (下載途中 cookie 被拒絕) 和每一輪更新開頭
(aniGamerPlus._run_update_cycle). 舊寫法都是 open('cookie.txt', 'w'), 寫到的是「目前
工作目錄」而不是程式資料夾 —— 不是在程式資料夾啟動的話, read_cookie() 永遠讀不到新
cookie, 只會再標記失效、再登入一次. 更新開頭那一處還沒丟掉記憶體裡登入前的 cookie,
那一輪派出去的任務照樣拿舊的.
"""

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
Config = agp.Config

NEW_COOKIE = 'BAHAID=tester; BAHARUNE=new'
AUTO_LOGIN = {'enabled': True, 'username': 'tester', 'password': 'secret',
              'headless': True, 'save_browser_cookie': False}


@pytest.fixture
def program_dir(tmp_path, monkeypatch):
    """cookie.txt 在程式資料夾, 但程式是從別的目錄啟動的. 瀏覽器登入第一次會成功."""
    program = tmp_path / 'program'
    elsewhere = tmp_path / 'elsewhere'
    program.mkdir()
    elsewhere.mkdir()
    monkeypatch.chdir(elsewhere)
    monkeypatch.setattr(Config, 'cookie_path', str(program / 'cookie.txt'))
    monkeypatch.setattr(Config, 'cookie', None)
    monkeypatch.setattr(Config, '__color_print', lambda *a, **k: None)

    logins = []

    def do_all(*args):
        logins.append(args)
        return NEW_COOKIE if len(logins) == 1 else False  # 寫錯地方的話會一直重登, 第二次起讓它失敗收場

    monkeypatch.setattr(Config.Loginer, 'do_all', do_all)
    return types.SimpleNamespace(cookie_txt=program / 'cookie.txt', logins=logins)


def test_cookie_from_auto_login_after_rejection_is_read_back(program_dir, monkeypatch):
    program_dir.cookie_txt.write_text('BAHAID=tester; BAHARUNE=old', encoding='utf-8')
    monkeypatch.setattr(Config, 'read_settings', lambda *a, **k: {'auto_login': AUTO_LOGIN})
    assert Config.login_token(Config.read_cookie()) == 'old'

    assert Config.invalid_cookie()

    assert Config.login_token(Config.read_cookie()) == 'new'
    assert len(program_dir.logins) == 1
    assert not os.path.exists('cookie.txt'), 'cookie 寫到啟動目錄去了'


def test_tasks_in_the_cycle_that_logged_in_use_the_new_cookie(program_dir, monkeypatch):
    program_dir.cookie_txt.write_text('nologinuser=1', encoding='utf-8')  # 已登出
    monkeypatch.setitem(agp.settings, 'auto_login', AUTO_LOGIN)
    for key in ('read_sn_list_when_checking_update', 'read_config_when_checking_update',
                'check_sn_ended', 'auto_update_danmu'):
        monkeypatch.setitem(agp.settings, key, False)
    monkeypatch.setitem(agp.settings['dashboard'], 'online_watch', False)
    monkeypatch.setattr(agp, 'queue', {})
    monkeypatch.setattr(agp.plugin_manager, 'auto_update', lambda context: {})

    seen = []
    monkeypatch.setattr(agp, 'check_tasks', lambda: seen.append(Config.read_cookie()))

    agp._run_update_cycle()

    assert len(program_dir.logins) == 1
    assert Config.login_token(seen[0]) == 'new', '這一輪的任務拿的還是登入前的 cookie'
