import importlib
import traceback

try:
    from ColorPrint import err_print
except BaseException:  # ColorPrint 連不上(缺套件、設定檔壞掉)也不該讓插件系統整個掛掉
    def err_print(sn, err_msg, detail='', status=0, no_sn=False, **kwargs):
        if kwargs.get('display', True):
            print(f'{err_msg} {detail}'.rstrip())


def _plugin_name(plugin):
    try:
        return type(plugin).__name__
    except BaseException:
        return 'UnknownPlugin'


def _report(plugin, hook, e):
    # 插件炸掉只能影響插件自己. 印一行給使用者看, traceback 丟日誌檔, 然後讓呼叫端
    # 當作「這個插件沒有回應」繼續跑 —— 絕不能讓它往上炸穿下載/上傳/更新流程.
    err_print(0, '插件異常', f'{_plugin_name(plugin)}.{hook}() 拋出例外: {e}', no_sn=True, status=1)
    err_print(0, '插件異常', '異常詳情:\n' + traceback.format_exc(), no_sn=True, status=1, display=False)


# 片單來源可以宣告的功能. 沒宣告的照預設值; 未知的鍵一律丟掉.
#   tags      作品卡片帶 tags, 可以用動畫瘋的分類標籤 (Catalog.TAGS) 篩選
#   download  可以下載單集 (catalog_download 的 mode='single')
#   subscribe 可以整部加入下載並追蹤之後的新集數 (mode='all')
CATALOG_FEATURES = ('tags', 'download', 'subscribe')


class CatalogProvider:
    """線上片庫來源的介面. 插件繼承它 (或照同樣的方法名自己寫) 就會出現在
    Dashboard 的「所有動畫」: 來源篩選、搜尋、作品資訊、下載.

    每個 hook 的第一個參數都是來源 id. 不是自己的來源就回 None, 讓下一個插件接;
    一個插件要提供好幾個來源, 覆寫 catalog_providers() 多報幾個就好.

    作品編號、集數編號只能用英數字、底線、減號 (最長 64 字). Dashboard 對外會把
    作品編號加上來源前綴 (anime1:1878), 插件這邊收到的一律是沒有前綴的.

    catalog_items(provider) -> list[dict]
        整份片單, 排在前面的先顯示. 每一部:
        {'animeSn': '1878', 'title': '作品名',          # 必填
         'cover': 'https://...', 'info': '2026 春',     # 卡片說明那一行
         'volume': '連載中(19)', 'popular': '65萬',
         'tags': ['異世界', ...]}                        # 宣告了 tags 才會拿來篩
        會被頻繁呼叫 (每次搜尋、翻頁), 請自己快取.

    catalog_anime(provider, anime_id) -> dict | None
        作品資訊. 只會問 catalog_items 裡有的作品.
        {'title': ..., 'cover': ..., 'content': '簡介', 'tags': [...],
         'director': ..., 'publisher': ..., 'seasonStart': ..., 'totalEpisode': ...,
         'sourceUrl': 'https://原站的作品頁',
         'groups': [{'name': '本篇', 'episodes': [
             {'id': '30259', 'episode': '19', 'path': '下載後的檔案路徑'}]}]}
        path 用來比對片庫: 那個檔案在片庫裡, 這一集就標成已下載、可以直接播.
        path 不會送到瀏覽器.

    catalog_download(provider, anime_id, episodes, mode, context) -> dict | None
        mode 是 'single' (episodes 是集數編號) 或 'all' (整部追番, episodes 為空).
        請把真正的下載丟到背景執行緒, 這裡馬上回 {'success': bool, 'message': str}.
        context 裡有 updatelist() 跟 upload_video(anime, tag), 下載完記得呼叫前者,
        片庫才看得到新的檔案.
    """

    provider_id = ''
    provider_name = ''
    features = {}

    def owns(self, provider):
        return bool(self.provider_id) and provider == self.provider_id

    def catalog_providers(self):
        if not self.provider_id:
            return []
        return [{'id': self.provider_id, 'name': self.provider_name or self.provider_id,
                 'features': dict(self.features)}]

    def catalog_items(self, provider):
        return None

    def catalog_anime(self, provider, anime_id):
        return None

    def catalog_download(self, provider, anime_id, episodes, mode, context):
        return None


def _catalog_features(plugin, declared):
    # 能下載的預設值看插件有沒有寫 catalog_download: 照著方法名自己寫、沒宣告
    # features 的舊插件, 以前能下載的現在也照樣能. 繼承 CatalogProvider 的一律
    # 有這個方法 (base 回 None), 所以要自己宣告.
    downloads = (callable(getattr(plugin, 'catalog_download', None)) and
                 not isinstance(plugin, CatalogProvider))
    defaults = {'tags': False, 'download': downloads, 'subscribe': downloads}
    declared = declared if isinstance(declared, dict) else {}
    return {name: bool(declared.get(name, defaults[name])) for name in CATALOG_FEATURES}


class PluginManager:
    def __init__(self, settings):
        self._plugins = []
        self.reload(settings)

    def reload(self, settings):
        # 建在本地再一次換上去. 原本先清空 self._plugins 再逐個載入, 中間這段空窗期
        # 若有別的執行緒剛好在 upload(), 它會看到「沒有任何插件」而掉進 FTP 備援.
        plugins = []
        plugin_settings = settings.get('plugins', {})
        enabled_plugins = plugin_settings.get('enabled', [])

        for plugin_name in enabled_plugins:
            candidate_modules = []
            if '.' in plugin_name:
                candidate_modules.append(plugin_name)
            else:
                candidate_modules.append(f'plugins.{plugin_name}')
                if not plugin_name.endswith('_plugin'):
                    candidate_modules.append(f'plugins.{plugin_name}_plugin')

            loaded = False
            last_exception = None
            last_traceback = ''
            for module_name in candidate_modules:
                try:
                    module = importlib.import_module(module_name)
                    if not hasattr(module, 'create_plugin'):
                        continue
                    plugin = module.create_plugin(settings)
                    if plugin is None:
                        continue
                    plugins.append(plugin)
                    loaded = True
                    break
                except BaseException as e:
                    last_exception = e
                    last_traceback = traceback.format_exc()

            if not loaded and last_exception is not None:
                err_print(0, '插件載入失敗', f'{plugin_name}: {last_exception}', no_sn=True, status=1)
                err_print(0, '插件載入失敗', '異常詳情:\n' + last_traceback, no_sn=True, status=1, display=False)

        self._plugins = plugins

    def upload(self, anime, bangumi_tag=''):
        for plugin in self._plugins:
            upload_func = getattr(plugin, 'upload', None)
            if not callable(upload_func):
                continue

            try:
                result = upload_func(anime, bangumi_tag=bangumi_tag)
            except BaseException as e:
                # 插件已經接手這筆上傳(它不是回 None 表示不管), 中途爆了就算它上傳失敗.
                # 不能當成「沒有插件處理」往下掉到 FTP 備援 —— 沒設定 FTP 的人會卡在
                # 連線重試上 15 分鐘, 還一路占著 upload_limiter 的名額.
                _report(plugin, 'upload', e)
                return {'handled': True, 'success': False}

            if result is None:
                continue

            if isinstance(result, bool):
                return {'handled': True, 'success': result}

            if not isinstance(result, dict):
                err_print(0, '插件異常',
                          f'{_plugin_name(plugin)}.upload() 回傳了非預期的型別: {type(result).__name__}',
                          no_sn=True, status=1)
                return {'handled': True, 'success': False}

            handled = bool(result.get('handled', True))
            success = bool(result.get('success', False))
            return {'handled': handled, 'success': success, **result}

        return {'handled': False, 'success': False}

    def resolve_playback_source(self, video_data):
        for plugin in self._plugins:
            resolver = getattr(plugin, 'resolve_playback_source', None)
            if not callable(resolver):
                continue
            try:
                result = resolver(video_data)
            except BaseException as e:
                # 線上看取不到遠端位址就算了, 讓呼叫端退回本地檔案, 別回 500.
                _report(plugin, 'resolve_playback_source', e)
                continue
            if result:
                return result
        return None

    def upload_video_data(self, video_data):
        for plugin in self._plugins:
            uploader = getattr(plugin, 'upload_video', None)
            if not callable(uploader):
                continue
            try:
                result = uploader(video_data)
            except BaseException as e:
                _report(plugin, 'upload_video', e)
                return False
            if result is None:
                continue
            if isinstance(result, bool):
                return result
            if not isinstance(result, dict):
                return False
            return bool(result.get('success', False))
        return False

    def has_remote(self, video_data):
        for plugin in self._plugins:
            checker = getattr(plugin, 'has_remote', None)
            if not callable(checker):
                continue
            try:
                if checker(video_data):
                    return True
            except BaseException as e:
                _report(plugin, 'has_remote', e)
                continue
        return False

    # ------------------------------------------------------------ 片單來源
    # 動畫瘋的片單是寫死在 Catalog.py 裡的; 其他站的片單由插件提供, 介面見
    # CatalogProvider. 插件用 catalog_providers() 報上自己認得的來源 id, 之後每個
    # hook 都帶著這個 id 問, 不是自己的來源就回 None, 讓下一個插件接.

    def catalog_providers(self):
        providers = []
        seen = set()
        for plugin in self._plugins:
            getter = getattr(plugin, 'catalog_providers', None)
            if not callable(getter):
                continue
            try:
                result = getter()
            except BaseException as e:
                _report(plugin, 'catalog_providers', e)
                continue
            for provider in result or []:
                if not isinstance(provider, dict):
                    continue
                provider_id = str(provider.get('id') or '').strip()
                # 同一個 id 只認第一個報上來的, 否則兩個插件會搶著回答同一個來源
                if not provider_id or provider_id in seen:
                    continue
                seen.add(provider_id)
                providers.append({
                    'id': provider_id,
                    'name': str(provider.get('name') or provider_id),
                    'features': _catalog_features(plugin, provider.get('features')),
                })
        return providers

    def _first_answer(self, hook, *args):
        for plugin in self._plugins:
            func = getattr(plugin, hook, None)
            if not callable(func):
                continue
            try:
                result = func(*args)
            except BaseException as e:
                # 片單列不出來就當這個來源今天沒有東西, 不能讓整頁 500
                _report(plugin, hook, e)
                continue
            if result is not None:
                return result
        return None

    def catalog_items(self, provider):
        items = self._first_answer('catalog_items', provider)
        return items if isinstance(items, list) else []

    def catalog_anime(self, provider, anime_id):
        detail = self._first_answer('catalog_anime', provider, anime_id)
        return detail if isinstance(detail, dict) else None

    def catalog_download(self, provider, anime_id, episodes, mode='single', context=None):
        if context is None:
            context = {}
        for plugin in self._plugins:
            func = getattr(plugin, 'catalog_download', None)
            if not callable(func):
                continue
            try:
                result = func(provider, anime_id, episodes, mode, context)
            except BaseException as e:
                # 跟 run_command 一樣: 插件已經接手了, 炸掉就是這次下載失敗
                _report(plugin, 'catalog_download', e)
                return {'handled': True, 'success': False, 'message': str(e)}
            if result is None:
                continue
            if isinstance(result, bool):
                return {'handled': True, 'success': result}
            if isinstance(result, dict):
                return {'handled': True, 'success': bool(result.get('success', False)), **result}
            return {'handled': True, 'success': False, 'message': 'Invalid plugin download result'}
        return {'handled': False, 'success': False, 'message': 'Provider not found'}

    def get_commands(self):
        commands = []
        for plugin in self._plugins:
            getter = getattr(plugin, 'get_commands', None)
            if not callable(getter):
                continue
            try:
                plugin_commands = getter()
            except BaseException as e:
                _report(plugin, 'get_commands', e)
                continue
            if not plugin_commands:
                continue
            for cmd in plugin_commands:
                if isinstance(cmd, dict) and cmd.get('name'):
                    commands.append(cmd)
        return commands

    def run_command(self, command_name, args=None, context=None):
        if args is None:
            args = []
        if context is None:
            context = {}
        for plugin in self._plugins:
            runner = getattr(plugin, 'run_command', None)
            if not callable(runner):
                continue
            try:
                result = runner(command_name, args, context)
            except BaseException as e:
                _report(plugin, 'run_command', e)
                return {'handled': True, 'success': False, 'message': str(e)}
            if result is not None:
                if isinstance(result, bool):
                    return {'handled': True, 'success': result}
                if isinstance(result, dict):
                    return {'handled': True, **result}
                return {'handled': True, 'success': False, 'message': 'Invalid plugin command result'}
        return {'handled': False, 'success': False, 'message': 'Command not found'}

    def auto_update(self, context=None):
        if context is None:
            context = {}

        scheduled = 0
        for plugin in self._plugins:
            runner = getattr(plugin, 'on_auto_update', None)
            if not callable(runner):
                continue
            try:
                result = runner(context)
            except BaseException as e:
                _report(plugin, 'on_auto_update', e)
                continue

            if isinstance(result, dict):
                try:
                    scheduled += int(result.get('scheduled', 0) or 0)
                except (TypeError, ValueError):
                    # 插件回了個不能轉成數字的 scheduled, 不值得為它中斷整輪更新
                    _report(plugin, 'on_auto_update', 'scheduled 欄位無法解析為數字')

        return {'scheduled': scheduled}
