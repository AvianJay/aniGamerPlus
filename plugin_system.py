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
