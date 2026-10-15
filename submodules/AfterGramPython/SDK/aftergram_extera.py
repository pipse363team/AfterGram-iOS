"""Compatibility placeholders for Extera-only management and Android UI APIs."""
class _Plugins:
    def get(self, plugin_id): return None

class PluginsController:
    @staticmethod
    def getInstance(): return PluginsController()
    def __init__(self): self.plugins = _Plugins()

class PluginSettingsActivity:
    def __init__(self, *args, **kwargs): raise NotImplementedError('Extera plugin screens need a manual iOS settings port')

class _Gson:
    @staticmethod
    def toJson(value):
        import json
        return json.dumps(value, default=lambda item: getattr(item, '__dict__', str(item)))

class AppUtils:
    @staticmethod
    def getGson(): return _Gson()
