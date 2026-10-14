"""Account-scoped plugin loader and event dispatcher; no Android runtime emulation."""
import ast
import contextvars
import importlib.util
import json
import logging
import os
from pathlib import Path
import re
import sys
import time
import traceback
import types
import zipfile

_CONTEXT = contextvars.ContextVar('aftergram_plugin_context')
_HOSTS = {}
MAX_SOURCE = 2 * 1024 * 1024
SUPPORTED = {'base_plugin', 'client_utils', 'android_utils', 'file_utils', 'ui', 'ui.settings', 'ui.bulletin', 'aftergram_android', 'aftergram_java'}
VENDORED = {'requests', 'packaging', 'urllib3', 'idna', 'certifi', 'charset_normalizer', 'yaml'}
VERSIONS = {'requests': '2.32.5', 'packaging': '25.0', 'urllib3': '2.5.0', 'idna': '3.11', 'certifi': '2025.10.5', 'charset-normalizer': '3.4.4', 'pyyaml': '6.0.3'}
ADAPTERS = {'org.telegram.messenger': ('aftergram_android', {'AndroidUtilities', 'UserConfig'}),
            'java.lang': ('aftergram_java', {'String', 'Integer', 'Long'})}
UNSUPPORTED_NAMES = {'hook_method', 'hook_all_methods', 'hook_all_constructors', 'find_class', 'send_request', 'edit_message', 'send_photo', 'send_video', 'send_audio', 'send_document', 'Custom', 'java_subclass', 'get_queue_by_name', 'get_selected_account', 'get_messages_controller', 'get_last_fragment', 'get_account_instance', 'get_connections_manager'}

def current():
    try: return _CONTEXT.get()
    except LookupError: raise RuntimeError('This API must run inside a plugin callback') from None

def emit(action):
    ctx = current()
    action['plugin'] = ctx['plugin']
    action['account'] = ctx['account']
    ctx['actions'].append(action)

def schedule(fn, delay=0):
    if not callable(fn): raise TypeError('Expected a callback')
    ctx = current()
    ctx['host'].jobs.append((time.monotonic() + max(0, int(delay)) / 1000, ctx['plugin'], fn, ctx['account'], ctx.get('dialog_id', 0), ctx.get('native_peer')))

class Node(types.SimpleNamespace):
    def getId(self): return getattr(self, 'id', 0)
    def getDialogId(self): return getattr(self, 'dialog_id', 0)

def node(value):
    if isinstance(value, dict): return Node(**{k: node(v) for k, v in value.items()})
    if isinstance(value, list): return [node(v) for v in value]
    return value

def atomic_json(path, value):
    temp = path.with_suffix('.tmp')
    temp.write_text(json.dumps(value, ensure_ascii=False), encoding='utf-8')
    os.replace(temp, path)

def analyze(source, adapt=False, metadata=None, local_modules=()):
    if len(source.encode('utf-8')) > MAX_SOURCE: raise ValueError('Plugin source exceeds 2 MB')
    tree = ast.parse(source)
    meta = {}
    for stmt in tree.body:
        if isinstance(stmt, ast.Assign):
            for target in stmt.targets:
                if isinstance(target, ast.Name) and target.id.startswith('__'):
                    try: meta[target.id] = ast.literal_eval(stmt.value)
                    except (ValueError, TypeError): pass
    if metadata:
        meta.update({'__' + k.strip('_') + '__': v for k, v in metadata.items()})
    if not re.fullmatch(r'[A-Za-z][A-Za-z0-9_-]{1,31}', str(meta.get('__id__', ''))): raise ValueError('Missing or invalid __id__')
    if not isinstance(meta.get('__name__'), str): raise ValueError('Missing __name__')
    issues, changes = [], []
    for item in ast.walk(tree):
        if isinstance(item, ast.ImportFrom) and item.module in ADAPTERS:
            replacement, symbols = ADAPTERS[item.module]
            if all(a.name in symbols for a in item.names):
                changes.append(item.module + ' -> ' + replacement)
                if adapt: item.module = replacement
            else: issues.append('Unsupported Android imports: ' + item.module)
        elif isinstance(item, (ast.Import, ast.ImportFrom)):
            names = [a.name for a in item.names] if isinstance(item, ast.Import) else [item.module or '']
            for name in names:
                if name.startswith(('java', 'android.', 'org.', 'hook_utils', 'extera_utils')):
                    issues.append('Platform dependency: ' + name)
                elif name not in SUPPORTED and name.split('.')[0] not in sys.stdlib_module_names and name.split('.')[0] not in VENDORED and name.split('.')[0] not in local_modules and not name.startswith('elyx') and getattr(item, 'level', 0) == 0:
                    # Local package imports are handled separately for Elyx projects.
                    issues.append('Check dependency: ' + name)
        if isinstance(item, ast.Call):
            name = getattr(item.func, 'attr', getattr(item.func, 'id', ''))
            if name in UNSUPPORTED_NAMES: issues.append('Unsupported API: ' + name)
            if name == 'add_hook' and item.args and isinstance(item.args[0], ast.Constant):
                if not str(item.args[0].value).startswith(('TL_update', 'update')): issues.append('Unsupported request hook: ' + str(item.args[0].value))
    requirements = meta.get('__requirements__', [])
    if isinstance(requirements, str): requirements = [x.strip() for x in requirements.split(',') if x.strip()]
    if requirements:
        from packaging.requirements import Requirement
        for raw in requirements:
            try:
                req = Requirement(raw)
                version = VERSIONS.get(req.name.lower().replace('_', '-'))
                if req.url or req.extras or not version or version not in req.specifier:
                    issues.append('Unavailable requirement: ' + raw)
            except Exception: issues.append('Invalid requirement: ' + str(raw))
    class LocalImportAdapter(ast.NodeTransformer):
        def visit_Import(self, item):
            if item.names and all(alias.name in local_modules and '.' not in alias.name for alias in item.names):
                changes.append('Local imports -> account-scoped relative imports')
                if adapt: return ast.copy_location(ast.ImportFrom(module=None, names=item.names, level=1), item)
            return item
        def visit_ImportFrom(self, item):
            if item.level == 0 and item.module and item.module.split('.')[0] in local_modules:
                changes.append('Local imports -> account-scoped relative imports')
                if adapt: item.level = 1
            return item
    tree = LocalImportAdapter().visit(tree)
    ast.fix_missing_locations(tree)
    return {'metadata': meta, 'issues': sorted(set(issues)), 'changes': sorted(set(changes)),
            'source': ast.unparse(tree) if adapt and changes else source}

class Host:
    def __init__(self, root, account):
        self.root = Path(root)
        self.root.mkdir(parents=True, exist_ok=True)
        self.account = account
        self.locale = "en"
        self.registry_path = self.root / 'registry.json'
        self.settings_path = self.root / 'settings.json'
        self.registry = self.read(self.registry_path)
        self.settings = self.read(self.settings_path)
        self.plugins = {}
        self.errors = {}
        self.jobs = []
        self.logs = []
        self.actions = []
        self.namespace = '_ag_' + str(abs(hash(str(self.root))))
        pkg = types.ModuleType(self.namespace);pkg.__path__ = [str(self.root)]
        sys.modules[self.namespace] = pkg
        for plugin_id, entry in self.registry.items():
            if entry.get('enabled'):
                try: self.load(plugin_id)
                except Exception: self.fail(plugin_id)
    @staticmethod
    def read(path):
        try: return json.loads(path.read_text(encoding='utf-8'))
        except (OSError, ValueError): return {}
    def save(self): atomic_json(self.registry_path, self.registry)
    def save_settings(self): atomic_json(self.settings_path, self.settings)
    def fail(self, plugin_id):
        self.errors[plugin_id] = traceback.format_exc(limit=5)[-3000:]
        self.logs.append(self.errors[plugin_id]);self.logs = self.logs[-100:]
        try: self.unload(plugin_id)
        except Exception: pass
        if plugin_id in self.registry:
            self.registry[plugin_id]['enabled'] = False;self.save()
    def invoke(self, plugin_id, fn, *args, account=None, dialog_id=0, native_peer=None):
        context = {'host': self, 'plugin': plugin_id, 'account': self.account if account is None else account,
                   'dialog_id': dialog_id, 'native_peer': native_peer, 'directory': self.root / plugin_id, 'actions': []}
        token = _CONTEXT.set(context)
        deadline = time.monotonic() + 1.0
        def trace(frame, event, arg):
            if time.monotonic() > deadline: raise TimeoutError('Plugin callback exceeded one second')
            return trace
        old_trace = sys.gettrace()
        sys.settrace(trace)
        try:
            result = fn(*args)
            self.actions.extend(context['actions'])
            return result
        finally:
            sys.settrace(old_trace);_CONTEXT.reset(token)
    def load(self, plugin_id):
        from base_plugin import BasePlugin, AppEvent
        self.unload(plugin_id)
        self.settings.setdefault(plugin_id, {})
        directory = self.root / plugin_id
        entry = self.registry[plugin_id]
        main = directory / entry.get('entry', 'main.py')
        module_name = self.namespace + '.' + plugin_id.encode('utf-8').hex()
        spec = importlib.util.spec_from_file_location(module_name, main, submodule_search_locations=[str(main.parent)])
        module = importlib.util.module_from_spec(spec);sys.modules[module_name] = module
        self.invoke(plugin_id, spec.loader.exec_module, module)
        classes = [c for c in vars(module).values() if isinstance(c, type) and issubclass(c, BasePlugin) and c is not BasePlugin and c.__module__ == module.__name__]
        if len(classes) != 1: raise ValueError('Expected exactly one BasePlugin subclass')
        plugin = self.invoke(plugin_id, classes[0])
        if not hasattr(plugin, '_host'): plugin._attach(self, plugin_id)
        self.plugins[plugin_id] = plugin
        self.invoke(plugin_id, plugin.on_plugin_load)
        self.invoke(plugin_id, plugin.on_app_event, AppEvent.START)
        self.errors.pop(plugin_id, None)
    def unload(self, plugin_id):
        plugin = self.plugins.pop(plugin_id, None)
        self.jobs = [job for job in self.jobs if job[1] != plugin_id]
        if plugin: self.invoke(plugin_id, plugin.on_plugin_unload)
        prefix = self.namespace + '.' + plugin_id.encode('utf-8').hex()
        for name in list(sys.modules):
            if name == prefix or name.startswith(prefix + '.'): del sys.modules[name]
    def package(self, path, adapt):
        source = Path(path)
        if source.suffix.lower() == '.py':
            text = source.read_text(encoding='utf-8-sig')
            report = analyze(text, adapt)
            return {'report': report, 'files': {'main.py': report['source'].encode()}, 'entry': 'main.py', 'refmap': {}, 'original': text.encode()}
        if source.suffix.lower() not in {'.elyx', '.eaf', '.zip'}: raise ValueError('Import a .py or Elyx source archive')
        import yaml
        with zipfile.ZipFile(source) as archive:
            entries = archive.infolist()
            if len(entries) > 512 or sum(x.file_size for x in entries) > 8 * 1024 * 1024: raise ValueError('Plugin archive exceeds the import limit')
            files = {}
            for entry in entries:
                path = Path(entry.filename)
                if str(path) != entry.filename.rstrip('/') or path.is_absolute() or '..' in path.parts or '\\' in entry.filename or (entry.external_attr >> 16) & 0o170000 == 0o120000:
                    raise ValueError('Invalid plugin archive path')
                if entry.is_dir(): continue
                if path.suffix in {'.pyc', '.so', '.dylib', '.whl'}: raise ValueError('Use an Elyx source archive without bytecode or native libraries')
                if entry.filename in files: raise ValueError('Duplicate archive member')
                files[entry.filename] = archive.read(entry)
            def structured(name):
                if name not in files: raise ValueError('Missing package file: ' + name)
                text = files[name].decode('utf-8-sig')
                value = json.loads(text) if name.endswith('.json') else yaml.safe_load(text)
                if not isinstance(value, dict): raise ValueError('Expected a mapping: ' + name)
                return value
            refname = next((n for n in ['refmap.yaml', 'refmap.yml', 'refmap.json'] if n in files), None)
            if not refname: raise ValueError('Elyx archive needs a root refmap')
            refmap = structured(refname)
            main = refmap.get('main', 'main.py')
            metapath = refmap.get('metainfo') or next((n for n in ['metainfo.yaml', 'metainfo.yml', 'metainfo.json'] if n in files), None)
            if not metapath: raise ValueError('Elyx metadata is missing')
            metadata = structured(metapath)
            if metadata.get('requires'): raise ValueError('Dependencies on other plugins are not yet supported')
            for key in ['main', 'metainfo', 'assets', 'strings']:
                value = refmap.get(key)
                if value is not None and (not isinstance(value, str) or Path(value).is_absolute() or '..' in Path(value).parts): raise ValueError('Invalid refmap path')
            if main not in files or not main.endswith('.py'): raise ValueError('Expected a Python source entry')
            local = set()
            issues, changes = [], []
            report = analyze(files[main].decode('utf-8-sig'), adapt, metadata, {Path(n).stem for n in files if n.endswith('.py')})
            for name in list(files):
                if not name.endswith('.py'): continue
                text = files[name].decode('utf-8-sig')
                parent = Path(name).parent
                siblings = {Path(candidate).stem for candidate in files if Path(candidate).parent == parent and candidate.endswith('.py')}
                siblings.update(Path(candidate).parent.name for candidate in files if Path(candidate).name == '__init__.py' and Path(candidate).parent.parent == parent)
                part = analyze(text, adapt, metadata, siblings)
                issues.extend(part['issues']);changes.extend(part['changes'])
                files[name] = part['source'].encode('utf-8')
            report['issues'] = sorted(set(issues));report['changes'] = sorted(set(changes))
            return {'report': report, 'files': files, 'entry': main, 'refmap': refmap, 'metadata': metadata, 'original': source.read_bytes()}
    def install(self, path, adapt):
        import shutil
        package = self.package(path, adapt)
        report = package['report']
        if report['issues'] or (report['changes'] and not adapt): return {'report': report, 'installed': False}
        plugin_id = report['metadata']['__id__']
        directory = self.root / plugin_id
        staging = self.root / (plugin_id + '.staging')
        if staging.exists(): shutil.rmtree(staging)
        staging.mkdir()
        try:
            for name, data in package['files'].items():
                target = staging / name;target.parent.mkdir(parents=True, exist_ok=True);target.write_bytes(data)
            (staging / 'original.source').write_bytes(package['original'])
            self.unload(plugin_id)
            backup = self.root / (plugin_id + '.backup')
            if backup.exists(): shutil.rmtree(backup)
            if directory.exists(): directory.rename(backup)
            try: staging.rename(directory)
            except Exception:
                if backup.exists(): backup.rename(directory)
                raise
            if backup.exists(): shutil.rmtree(backup)
        finally:
            if staging.exists(): shutil.rmtree(staging)
        self.registry[plugin_id] = {'name': report['metadata']['__name__'], 'version': str(report['metadata'].get('__version__', '1.0')), 'enabled': False, 'adapted': bool(report['changes']), 'entry': package['entry'], 'refmap': package['refmap'], 'metadata': package.get('metadata', {})}
        self.save()
        return {'installed': True, 'id': plugin_id, 'report': report}
    def outgoing(self, request):
        from base_plugin import HookResult, HookStrategy
        text = request['text']
        params = node({'message': text, 'peer': int(request['peer']), 'account': request['account']})
        ordered = sorted(list(self.plugins.items()), key=lambda item: (-(item[1]._send_priority or 0), item[0]))
        cancelled = False
        for plugin_id, plugin in ordered:
            if plugin._send_priority is None: continue
            previous = params.message
            checkpoint = len(self.actions)
            try:
                result = self.invoke(plugin_id, plugin.on_send_message_hook, request['account'], params, account=request['account'], dialog_id=int(request['peer']), native_peer=request.get('native_peer'))
                if result is None: result = HookResult()
                if not isinstance(result, HookResult): raise TypeError('Expected HookResult')
                if result.strategy == HookStrategy.CANCEL:
                    cancelled = True;break
                if result.strategy in (HookStrategy.MODIFY, HookStrategy.MODIFY_FINAL):
                    changed = result.params
                    if not changed or not isinstance(changed.message, str) or len(changed.message) > 4096: raise ValueError('Invalid modified message')
                    params.message = changed.message
                else: params.message = previous
                if result.strategy == HookStrategy.MODIFY_FINAL: break
            except Exception:
                del self.actions[checkpoint:]
                params.message = previous;self.fail(plugin_id)
        return {'text': params.message, 'cancel': cancelled}
    def settings_rows(self, plugin_id, path=()):
        plugin = self.plugins.get(plugin_id)
        if not plugin: return []
        try:
            if len(path) > 8: raise ValueError('Settings nesting limit exceeded')
            rows = self.invoke(plugin_id, plugin.create_settings)
            for index in path:
                callback = rows[index].create_sub_fragment
                if not callable(callback): raise ValueError('This setting has no subpage')
                rows = self.invoke(plugin_id, callback)
            plugin._rows = rows
            return [row.as_json(plugin, i) for i, row in enumerate(rows)]
        except Exception:
            self.fail(plugin_id);return []
    def tick(self):
        now = time.monotonic()
        ready = [j for j in self.jobs if j[0] <= now]
        self.jobs = [j for j in self.jobs if j[0] > now]
        for _, plugin_id, fn, account, dialog, native_peer in ready[:32]:
            if plugin_id not in self.plugins: continue
            try: self.invoke(plugin_id, fn, account=account, dialog_id=dialog, native_peer=native_peer)
            except Exception: self.fail(plugin_id)
    def handle(self, r):
        op = r['op'];plugin_id = r.get('id')
        self.locale = r.get('locale', self.locale)
        if op == 'sample':
            path = self.root / 'sample.py'
            path.write_text(SAMPLE, encoding='utf-8')
            try: return self.install(path, False)
            finally: path.unlink(missing_ok=True)
        if op == 'list':
            return {'plugins': [{'id': key, **value, 'enabled': key in self.plugins, 'error': self.errors.get(key, '')} for key, value in self.registry.items()]}
        if op == 'install': return self.install(r['path'], r.get('adapt', False))
        if op == 'inspect': return {'report': self.package(r['path'], False)['report']}
        if op == 'enable':
            self.registry[plugin_id]['enabled'] = bool(r['enabled']);self.save()
            if r['enabled']:
                try: self.load(plugin_id)
                except Exception: self.fail(plugin_id)
            else: self.unload(plugin_id)
            return {'error': self.errors.get(plugin_id, '')}
        if op == 'delete':
            import shutil
            if plugin_id not in self.registry: raise ValueError('Unknown plugin')
            self.unload(plugin_id);self.registry.pop(plugin_id);self.settings.pop(plugin_id, None)
            shutil.rmtree(self.root / plugin_id);self.save();self.save_settings();return {}
        if op == 'outgoing': return self.outgoing(r)
        if op == 'settings': return {'rows': self.settings_rows(plugin_id, r.get('path', []))}
        if op == 'setting':
            self.settings_rows(plugin_id, r.get('path', []))
            plugin = self.plugins[plugin_id];row = plugin._rows[r['index']]
            if row.key:
                value = r['value']
                if row.kind == 'Switch' and not isinstance(value, bool): raise ValueError('Expected a switch value')
                if row.kind in {'Input', 'EditText'} and not isinstance(value, str): raise ValueError('Expected text')
                if row.kind == 'Selector' and (not isinstance(value, int) or isinstance(value, bool) or not 0 <= value < len(row.items)): raise ValueError('Invalid selector index')
                plugin.set_setting(row.key, r['value'])
                if row.on_change: self.invoke(plugin_id, row.on_change, r['value'])
            elif row.on_click: self.invoke(plugin_id, row.on_click, None)
            return {'rows': self.settings_rows(plugin_id, r.get('path', []))}
        if op == 'menus':
            return {'menus': [{'plugin': key, 'id': mid, 'text': item.text, 'type': item.menu_type.value, 'priority': item.priority} for key, plugin in self.plugins.items() for mid, item in plugin._menus.items()]}
        if op == 'menu':
            item = self.plugins[plugin_id]._menus[r['menu']]
            self.invoke(plugin_id, item.on_click, {**r.get('context', {}), 'account': self.account, 'message': node(r.get('message', {}))}, dialog_id=int(r.get('peer', 0)), native_peer=r.get('native_peer'))
            return {}
        if op == 'update':
            from base_plugin import HookResult, HookStrategy
            name = r['name'];update = node(r['update'])
            for key, plugin in list(self.plugins.items()):
                if any((hook in name if substring else hook == name) for hook, substring, _ in plugin._hooks):
                    try:
                        result = self.invoke(key, plugin.on_update_hook, name, self.account, update, dialog_id=int(r.get('peer', 0)), native_peer=r.get('native_peer'))
                        if result is not None and (not isinstance(result, HookResult) or result.strategy != HookStrategy.DEFAULT):
                            raise NotImplementedError('Incoming message events are read-only in this version')
                    except Exception: self.fail(key)
            return {}
        if op == 'app_event':
            from base_plugin import AppEvent
            event = AppEvent[r['event']]
            for key, plugin in list(self.plugins.items()):
                try: self.invoke(key, plugin.on_app_event, event)
                except Exception: self.fail(key)
            return {}
        if op == 'tick': self.tick();return {}
        if op == 'logs': return {'logs': self.logs[-100:]}
        if op == 'close':
            for key in list(self.plugins): self.unload(key)
            _HOSTS.pop(str(self.root), None);return {}
        raise ValueError('Unknown plugin operation: ' + op)

class LogHandler(logging.Handler):
    def emit(self, record):
        try:
            host = current()['host'];host.logs.append(self.format(record));host.logs = host.logs[-100:]
        except RuntimeError: pass
logging.getLogger().addHandler(LogHandler())
logging.getLogger().setLevel(logging.INFO)

def dispatch(raw):
    try:
        r = json.loads(raw)
        root = str(Path(r['root']).resolve())
        host = _HOSTS.get(root)
        if host is None:
            host = Host(root, r['account']);_HOSTS[root] = host
        host.actions = []
        result = host.handle(r)
        result['actions'] = host.actions
        return json.dumps(result, ensure_ascii=False)
    except Exception:
        return json.dumps({'error': traceback.format_exc(limit=5)[-3000:]}, ensure_ascii=False)

SAMPLE = """from base_plugin import BasePlugin, HookResult, HookStrategy
from ui.settings import Header, Input
__id__ = 'hello_world'
__name__ = 'Hello World'
__version__ = '1.0'
class HelloWorldPlugin(BasePlugin):
    def on_plugin_load(self):
        self.add_on_send_message_hook()
    def create_settings(self):
        return [Header(text='Hello'), Input(key='template', text='Template', default='Hello, {name}!')]
    def on_send_message_hook(self, account, params):
        if params.message.startswith('.hello '):
            params.message = self.get_setting('template', 'Hello, {name}!').format(name=params.message[7:])
            return HookResult(strategy=HookStrategy.MODIFY, params=params)
        return HookResult()
"""
