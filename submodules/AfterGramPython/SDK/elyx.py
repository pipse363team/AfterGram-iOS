"""Portable subset of Elyx: source imports, assets, strings and settings."""
import importlib
import json
from pathlib import Path
from aftergram_host import current

class Asset:
    def __init__(self, path): self.path = Path(path)
    @classmethod
    def from_path(cls, path): return cls(path)
    def content_bytes(self): return self.path.read_bytes()
    def content_string(self): return self.path.read_text(encoding='utf-8')
    def content_json(self): return json.loads(self.content_string())
    def content_yaml(self):
        import yaml
        return yaml.safe_load(self.content_string())

class Assets:
    def __init__(self, dir_path): self.path = Path(dir_path).resolve()
    def get(self, name):
        path = (self.path / name).resolve()
        if not path.is_relative_to(self.path): raise ValueError('Asset path leaves resource directory')
        return Assets(path) if path.is_dir() else Asset(path)
    def __getitem__(self, name): return self.get(name)
    def __contains__(self, name): return (self.path / name).is_file()

class Strings:
    def __init__(self, dir_path, locale='en'):
        self.values = {}
        directory = Path(dir_path)
        for language in ['en', locale.split('-')[0]]:
            for extension in ['json', 'yml', 'yaml']:
                path = directory / ('strings_' + language + '.' + extension)
                if path.exists():
                    if extension == 'json': data = json.loads(path.read_text())
                    else:
                        import yaml
                        data = yaml.safe_load(path.read_text())
                    if isinstance(data, dict): self.values.update(data)
    def get(self, key, **kwargs): return str(self.values.get(key, key)).format(**kwargs)
    def __getitem__(self, key): return self.get(key)
    def __call__(self, key, **kwargs): return self.get(key, **kwargs)

class SettingsController:
    def __init__(self): self.ctx = current()
    def get(self, key, default=None): return self.ctx['host'].settings.get(self.ctx['plugin'], {}).get(key, default)
    def set(self, key, value):
        host = self.ctx['host'];host.settings.setdefault(self.ctx['plugin'], {})[key] = value;host.save_settings()
    get_setting = get
    set_setting = set

def get_environment():
    ctx = current();entry = ctx['host'].registry[ctx['plugin']];mapping = entry.get('refmap', {})
    directory = ctx['directory']
    result = {'settings': SettingsController(), 'metainfo': entry.get('metadata', {}), 'refmap': mapping}
    if mapping.get('assets'): result['assets'] = Assets(directory / mapping['assets'])
    if mapping.get('strings'): result['strings'] = Strings(directory / mapping['strings'], ctx['host'].locale)
    return result

def __getattr__(name):
    env = get_environment()
    if name in env: return env[name]
    raise AttributeError(name)

def import_module(name, package=None):
    ctx = current()
    prefix = ctx['host'].namespace + '.' + ctx['plugin'].encode('utf-8').hex()
    if package: return importlib.import_module(name, prefix + '.' + package)
    return importlib.import_module('.' + name, prefix)
