# -*- coding: utf-8 -*-
"""插件出錯不可以把下載流程帶著一起死.

起因: OneDrive 配額爆掉 (quotaLimitReached) 之後追番就不再往下跑. 這裡釘住
plugin_system 的容錯契約 —— 任何一個 hook 拋例外, PluginManager 都要自己吞掉、
回一個呼叫端能處理的值, 絕對不能往上炸到 worker / auto_update_loop.
"""

import os
import sys

import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from plugin_system import PluginManager


class ExplodingPlugin:
    """每一個 hook 都炸的插件."""

    def upload(self, anime, bangumi_tag=''):
        raise RuntimeError('建立 OneDrive 上傳工作階段失敗: quotaLimitReached')

    def upload_video(self, video_data):
        raise RuntimeError('quotaLimitReached')

    def has_remote(self, video_data):
        raise RuntimeError('state 壞了')

    def resolve_playback_source(self, video_data):
        raise RuntimeError('Graph 掛了')

    def get_commands(self):
        raise RuntimeError('壞了')

    def run_command(self, command_name, args, context):
        raise RuntimeError('壞了')

    def on_auto_update(self, context):
        raise RuntimeError('壞了')


class SilentPlugin:
    """全部回 None, 代表「這筆我不處理」."""

    def upload(self, anime, bangumi_tag=''):
        return None

    def resolve_playback_source(self, video_data):
        return None


class WorkingPlugin:
    def resolve_playback_source(self, video_data):
        return {'url': 'https://example.invalid/ok.mp4', 'provider': 'Working'}


def _manager_with(*plugins):
    manager = PluginManager({'plugins': {'enabled': []}})
    manager._plugins = list(plugins)
    return manager


def test_upload_exception_is_reported_as_handled_failure():
    # 插件已經接手這筆上傳, 炸了就是「上傳失敗」, 不能被當成「沒人處理」而掉進
    # FTP 備援 —— 沒設定 FTP 的人會卡在連線重試上十幾分鐘還占著 upload_limiter.
    result = _manager_with(ExplodingPlugin()).upload(object(), bangumi_tag='')
    assert result == {'handled': True, 'success': False}


def test_no_plugin_handles_upload_leaves_it_unhandled():
    # 沒有插件接手時仍要回 handled=False, 呼叫端才知道要走內建 FTP 上傳
    result = _manager_with(SilentPlugin()).upload(object(), bangumi_tag='')
    assert result['handled'] is False


@pytest.mark.parametrize('call', [
    lambda m: m.has_remote({'sn': '51229', 'resolution': 1080}),
    lambda m: m.upload_video_data({'sn': '51229', 'path': 'x.mp4'}),
    lambda m: m.resolve_playback_source({'sn': '51229', 'resolution': 1080}),
    lambda m: m.get_commands(),
    lambda m: m.run_command('whatever', [], {}),
    lambda m: m.auto_update({}),
])
def test_every_hook_swallows_plugin_exceptions(call):
    call(_manager_with(ExplodingPlugin()))  # 不該拋出任何東西


def test_has_remote_and_playback_fall_through_to_next_plugin():
    # 前面的插件炸掉不能擋住後面還能用的插件
    manager = _manager_with(ExplodingPlugin(), WorkingPlugin())
    assert manager.resolve_playback_source({'sn': '1', 'resolution': 0})['provider'] == 'Working'


def test_auto_update_counts_only_valid_scheduled_values():
    class BadCount:
        def on_auto_update(self, context):
            return {'scheduled': '不是數字'}

    class GoodCount:
        def on_auto_update(self, context):
            return {'scheduled': 2}

    assert _manager_with(BadCount(), GoodCount(), ExplodingPlugin()).auto_update({}) == {'scheduled': 2}


def test_upload_rejects_garbage_return_type():
    class GarbagePlugin:
        def upload(self, anime, bangumi_tag=''):
            return ['不是 dict 也不是 bool']

    assert _manager_with(GarbagePlugin()).upload(object()) == {'handled': True, 'success': False}


def test_reload_survives_a_plugin_that_fails_to_import():
    manager = PluginManager({'plugins': {'enabled': ['definitely_not_a_real_plugin']}})
    assert manager._plugins == []


def test_reload_keeps_old_plugins_visible_until_the_new_set_is_ready():
    # reload 期間不可以出現「插件列表暫時是空的」的窗口, 否則剛好在那一瞬間
    # upload() 會誤判成沒有插件而掉去 FTP
    manager = _manager_with(WorkingPlugin())
    seen = []

    class Watcher(dict):
        def get(self, key, default=None):
            seen.append(list(manager._plugins))
            return super().get(key, default)

    manager.reload(Watcher({'plugins': {'enabled': []}}))
    assert all(len(snapshot) == 1 for snapshot in seen), '載入新插件時舊列表被提前清空了'
