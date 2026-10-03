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

from plugin_system import CatalogProvider, PluginManager


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

    def catalog_providers(self):
        raise RuntimeError('片單壞了')

    def catalog_items(self, provider):
        raise RuntimeError('片單壞了')

    def catalog_anime(self, provider, anime_id):
        raise RuntimeError('分類頁壞了')

    def catalog_download(self, provider, anime_id, episodes, mode, context):
        raise RuntimeError('下載壞了')


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
    lambda m: m.catalog_providers(),
    lambda m: m.catalog_items('anime1'),
    lambda m: m.catalog_anime('anime1', '1878'),
    lambda m: m.catalog_download('anime1', '1878', ['30259'], 'single', {}),
])
def test_every_hook_swallows_plugin_exceptions(call):
    call(_manager_with(ExplodingPlugin()))  # 不該拋出任何東西


ALL_DOWNLOADS = {'tags': False, 'download': True, 'subscribe': True}


class CatalogPlugin:
    """只認 anime1 這個來源的片單插件, 照方法名自己寫的, 沒宣告 features."""

    def catalog_providers(self):
        return [{'id': 'anime1', 'name': 'Anime1.me'}, 'garbage', {'id': ''}]

    def catalog_items(self, provider):
        return [{'animeSn': '1878', 'title': 'Re:0'}] if provider == 'anime1' else None

    def catalog_anime(self, provider, anime_id):
        return {'title': 'Re:0'} if provider == 'anime1' else None

    def catalog_download(self, provider, anime_id, episodes, mode, context):
        if provider != 'anime1':
            return None
        return {'success': True, 'scheduled': len(episodes)}


def test_a_broken_catalog_plugin_does_not_hide_the_next_one():
    # 片單這幾個 hook 是「第一個回答的說了算」: 炸掉的插件當它沒回答, 後面的照樣算數
    manager = _manager_with(ExplodingPlugin(), CatalogPlugin())
    assert manager.catalog_providers() == [{'id': 'anime1', 'name': 'Anime1.me', 'features': ALL_DOWNLOADS}]
    assert manager.catalog_items('anime1') == [{'animeSn': '1878', 'title': 'Re:0'}]
    assert manager.catalog_anime('anime1', '1878') == {'title': 'Re:0'}


def test_catalog_hooks_for_an_unknown_provider_come_back_empty():
    manager = _manager_with(CatalogPlugin())
    assert manager.catalog_items('nope') == []
    assert manager.catalog_anime('nope', '1') is None
    assert manager.catalog_download('nope', '1', [], 'all', {})['handled'] is False


def test_catalog_download_exception_is_a_handled_failure():
    # 插件已經接手這次下載, 炸了就是下載失敗 —— 不能往下問別的插件, 更不能往上炸
    result = _manager_with(ExplodingPlugin(), CatalogPlugin()).catalog_download(
        'anime1', '1878', ['30259'], 'single', {})
    assert result['handled'] is True and result['success'] is False


def test_duplicate_provider_ids_keep_the_first_plugin():
    class Impostor:
        def catalog_providers(self):
            return [{'id': 'anime1', 'name': '冒牌'}]

    providers = _manager_with(CatalogPlugin(), Impostor()).catalog_providers()
    assert providers == [{'id': 'anime1', 'name': 'Anime1.me', 'features': ALL_DOWNLOADS}]


def test_features_default_from_what_the_plugin_implements():
    # 照方法名自己寫、沒宣告 features 的插件: 有 catalog_download 就當它能下載
    class ListOnly:
        def catalog_providers(self):
            return [{'id': 'viewer', 'name': '只能看'}]

    manager = _manager_with(CatalogPlugin(), ListOnly())
    features = {provider['id']: provider['features'] for provider in manager.catalog_providers()}
    assert features == {'anime1': ALL_DOWNLOADS,
                        'viewer': {'tags': False, 'download': False, 'subscribe': False}}


def test_declared_features_win_and_unknown_keys_are_dropped():
    class Declared(CatalogProvider):
        provider_id = 'tagged'
        provider_name = '有標籤'
        features = {'tags': True, 'subscribe': False, 'stream': True}

    assert _manager_with(Declared()).catalog_providers() == [{
        'id': 'tagged', 'name': '有標籤',
        # 繼承 CatalogProvider 的一定有 catalog_download (base 回 None), 所以沒宣告的就是不支援
        'features': {'tags': True, 'download': False, 'subscribe': False}}]


def test_catalog_provider_base_only_answers_for_its_own_id():
    class Mine(CatalogProvider):
        provider_id = 'mine'

        def catalog_items(self, provider):
            return [{'animeSn': '1', 'title': 'x'}] if self.owns(provider) else None

    manager = _manager_with(Mine())
    assert manager.catalog_items('mine') == [{'animeSn': '1', 'title': 'x'}]
    assert manager.catalog_items('other') == []
    # base 沒實作的 hook 一律是「不是我的」, 不會被當成下載失敗
    assert manager.catalog_download('mine', '1', ['1'], 'single', {})['handled'] is False
    assert CatalogProvider().catalog_providers() == []


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
