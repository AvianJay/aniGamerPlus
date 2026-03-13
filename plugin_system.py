import importlib


class PluginManager:
    def __init__(self, settings):
        self._plugins = []
        self.reload(settings)

    def reload(self, settings):
        self._plugins = []
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
            for module_name in candidate_modules:
                try:
                    module = importlib.import_module(module_name)
                    if not hasattr(module, 'create_plugin'):
                        continue
                    plugin = module.create_plugin(settings)
                    if plugin is None:
                        continue
                    self._plugins.append(plugin)
                    loaded = True
                    break
                except BaseException as e:
                    last_exception = e

            if not loaded and last_exception is not None:
                print(f'[PluginManager] 載入插件失敗: {plugin_name}')
                print(str(last_exception))

    def upload(self, anime, bangumi_tag=''):
        for plugin in self._plugins:
            upload_func = getattr(plugin, 'upload', None)
            if not callable(upload_func):
                continue

            result = upload_func(anime, bangumi_tag=bangumi_tag)
            if result is None:
                continue

            if isinstance(result, bool):
                return {'handled': True, 'success': result}

            handled = bool(result.get('handled', True))
            success = bool(result.get('success', False))
            return {'handled': handled, 'success': success, **result}

        return {'handled': False, 'success': False}

    def resolve_playback_source(self, video_data):
        for plugin in self._plugins:
            resolver = getattr(plugin, 'resolve_playback_source', None)
            if not callable(resolver):
                continue
            result = resolver(video_data)
            if result:
                return result
        return None

    def upload_video_data(self, video_data):
        for plugin in self._plugins:
            uploader = getattr(plugin, 'upload_video', None)
            if not callable(uploader):
                continue
            result = uploader(video_data)
            if result is None:
                continue
            if isinstance(result, bool):
                return result
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
            except BaseException:
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
            except BaseException:
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
                return {'handled': True, 'success': False, 'message': str(e)}
            if result is not None:
                if isinstance(result, bool):
                    return {'handled': True, 'success': result}
                if isinstance(result, dict):
                    return {'handled': True, **result}
                return {'handled': True, 'success': False, 'message': 'Invalid plugin command result'}
        return {'handled': False, 'success': False, 'message': 'Command not found'}
