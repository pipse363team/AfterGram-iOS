"""Account-scoped plugin loader and event dispatcher; no Android runtime emulation."""
import ast
import contextvars
import copy
from concurrent.futures import ThreadPoolExecutor
import importlib
import importlib.util
import json
import logging
import os
from pathlib import Path
import re
import sys
import time
import threading
import traceback
import types
import zipfile

_CONTEXT = contextvars.ContextVar('aftergram_plugin_context')
_HOSTS = {}
MAX_SOURCE = 2 * 1024 * 1024
SUPPORTED = {'base_plugin', 'client_utils', 'android_utils', 'file_utils', 'ui', 'ui.settings', 'ui.bulletin', 'ui.alert', 'extera_utils', 'extera_utils.text_formatting', 'aftergram_android', 'aftergram_java', 'java', 'org.telegram.tgnet', 'org.telegram.tgnet.TLRPC', 'org.telegram.tgnet.tl'}
VENDORED = {'requests', 'packaging', 'urllib3', 'idna', 'certifi', 'charset_normalizer', 'yaml'}
VERSIONS = {'requests': '2.32.5', 'packaging': '25.0', 'urllib3': '2.5.0', 'idna': '3.11', 'certifi': '2025.10.5', 'charset-normalizer': '3.4.4', 'pyyaml': '6.0.3'}
VENDORED.update({'mpmath','tinydb','bs4','soupsieve','typing_extensions','markdown','dateutil','six','pytz'})
VERSIONS.update({'mpmath':'1.3.0','tinydb':'4.8.2','beautifulsoup4':'4.13.5','soupsieve':'2.8','typing-extensions':'4.15.0','markdown':'3.9','python-dateutil':'2.9.0.post0','six':'1.17.0','pytz':'2025.2'})
ADAPTERS = {'org.telegram.messenger': ('aftergram_android', {'AndroidUtilities', 'UserConfig', 'MessagesController', 'ConnectionsManager', 'ApplicationLoader'}),
            'java.lang': ('aftergram_java', {'String', 'Integer', 'Long', 'Object', 'Double', 'Boolean'}),
            'android.widget': ('aftergram_ui', {'TextView','EditText','Button','LinearLayout','FrameLayout'}),
            'android.view': ('aftergram_ui', {'View','Gravity'}),
            'android.text': ('aftergram_ui', {'InputType'}),
            'android.content': ('aftergram_intents', {'Intent','Context'}),
            'android.net': ('aftergram_intents', {'Uri'}),
            'org.telegram.ui.Components': ('aftergram_ui', {'LayoutHelper'})}
UNSUPPORTED_NAMES = {'hook_method', 'hook_all_methods', 'hook_all_constructors', 'find_class', 'Custom', 'java_subclass'}

def current():
    try: return _CONTEXT.get()
    except LookupError: raise RuntimeError('This API must run inside a plugin callback') from None

def emit(action):
    ctx = current()
    if ctx.get('background') and ctx['host'].generations.get(ctx['plugin'],0) != ctx['generation']: return
    action['plugin'] = ctx['plugin']
    action['account'] = ctx['account']
    action['generation'] = ctx['generation']
    ctx['actions'].append(action)

def schedule(fn, delay=0, background=False):
    if not callable(fn): raise TypeError('Expected a callback')
    ctx = current()
    host = ctx['host']
    with host.state_lock:
        if len(host.jobs) >= 512: raise ValueError('Plugin scheduled task limit exceeded')
        if ctx.get('background') and host.generations.get(ctx['plugin'],0) != ctx['generation']: return
        host.jobs.append((time.monotonic() + max(0, int(delay)) / 1000, ctx['plugin'], fn, ctx['account'], ctx.get('dialog_id', 0), ctx.get('native_peer'), bool(background)))

class Node(types.SimpleNamespace):
    def getId(self): return getattr(self, 'id', 0)
    def getDialogId(self): return getattr(self, 'dialog_id', 0)

def node(value):
    if isinstance(value, dict): return Node(**{k: node(v) for k, v in value.items()})
    if isinstance(value, list): return [node(v) for v in value]
    return value

def error_summary(error):
    if isinstance(error, SyntaxError):
        return 'Python syntax error at line ' + str(error.lineno or '?') + ': ' + str(error.msg)
    return str(error) or type(error).__name__

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
                if name in SUPPORTED:
                    if isinstance(item, ast.ImportFrom) and item.level == 0:
                        module = importlib.import_module(name)
                        for alias in item.names:
                            if alias.name != '*' and alias.name not in vars(module) and alias.name not in vars(module).get('__supported_symbols__', set()) and name + '.' + alias.name not in SUPPORTED:
                                issues.append('Unsupported SDK symbol: ' + name + '.' + alias.name)
                elif name.startswith(('java', 'android.', 'org.', 'hook_utils', 'extera_utils')):
                    issues.append('Platform dependency: ' + name)
                elif name not in SUPPORTED and name.split('.')[0] not in sys.stdlib_module_names and name.split('.')[0] not in VENDORED and name.split('.')[0] not in local_modules and not name.startswith('elyx') and getattr(item, 'level', 0) == 0:
                    # Local package imports are handled separately for Elyx projects.
                    issues.append('Check dependency: ' + name)
        if isinstance(item, ast.Call):
            name = getattr(item.func, 'attr', getattr(item.func, 'id', ''))
            if name in UNSUPPORTED_NAMES: issues.append('Unsupported API: ' + name)
            if name == 'add_hook' and item.args and isinstance(item.args[0], ast.Constant):
                from aftergram_tl import SCHEMA
                hook = str(item.args[0].value)
                supported = {'TL_updateNewMessage','TL_updateNewChannelMessage'} | {'TL_' + m['name'].replace('.','_') for m in SCHEMA if m.get('function')}
                substring = any(k.arg == 'match_substring' and isinstance(k.value, ast.Constant) and k.value.value for k in item.keywords)
                if hook not in supported and not (substring and any(hook in n for n in supported)): issues.append('Unsupported event hook: ' + hook)
    requirements = meta.get('__requirements__', [])
    if isinstance(requirements, str): requirements = [x.strip() for x in requirements.split(',') if x.strip()]
    if requirements:
        from packaging.requirements import Requirement
        for raw in requirements:
            try:
                req = Requirement(raw)
                if req.marker and not req.marker.evaluate({'platform_system':'iOS','sys_platform':'ios','platform_machine':'arm64','python_version':'3.11','python_full_version':'3.11.13'}): continue
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
    def __init__(self, root, account, metadata=None):
        self.root = Path(root)
        self.root.mkdir(parents=True, exist_ok=True)
        self.account = account
        self.state_lock = threading.RLock()
        self.executor = ThreadPoolExecutor(max_workers=4, thread_name_prefix='AfterGram-plugin')
        self.futures = set()
        self.worker_results = []
        self.generations = {}
        self.locale = "en"
        self.registry_path = self.root / 'registry.json'
        self.settings_path = self.root / 'settings.json'
        self.registry = self.read(self.registry_path)
        self.settings = self.read(self.settings_path)
        self.plugins = {}
        self.errors = {}
        self.error_details = {}
        self.jobs = []
        self.logs = []
        self.actions = []
        self.callbacks = {}
        self.dialogs = {}
        self.peers = {}
        self.users = {}
        self.chats = {}
        self.self_id = int((metadata or {}).get('self_id', 0))
        if (metadata or {}).get('self_user'):
            from aftergram_tl import from_json
            user = from_json(metadata['self_user']);self.users[user.id] = user
        self.next_callback = 0
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
    def save_settings(self):
        with self.state_lock: atomic_json(self.settings_path, self.settings)
    def fail(self, plugin_id, error=None, details=None):
        self.errors[plugin_id] = error_summary(error if error is not None else sys.exception())
        self.error_details[plugin_id] = details or traceback.format_exc(limit=8)[-6000:]
        self.logs.append(self.error_details[plugin_id]);self.logs = self.logs[-100:]
        try: self.unload(plugin_id)
        except Exception: pass
        if plugin_id in self.registry:
            self.registry[plugin_id]['enabled'] = False;self.save()
    def invoke(self, plugin_id, fn, *args, account=None, dialog_id=0, native_peer=None, background=False, generation=None, budget=None):
        context = {'host': self, 'plugin': plugin_id, 'account': self.account if account is None else account,
                   'dialog_id': dialog_id, 'native_peer': native_peer, 'directory': self.root / plugin_id, 'actions': [],
                   'background':background, 'generation':self.generations.get(plugin_id,0) if generation is None else generation}
        token = _CONTEXT.set(context)
        budget = (30.0 if background else 1.0) if budget is None else float(budget)
        deadline = time.monotonic() + budget
        opcodes = 0
        def trace(frame, event, arg):
            nonlocal opcodes
            # CPython 3.11 can optimize a one-line infinite loop so that it
            # emits no repeated line events. Opcode tracing must cover it.
            if event == 'call': frame.f_trace_opcodes = True
            if event == 'opcode':
                opcodes += 1
                if opcodes % 256: return trace
            if background and self.generations.get(plugin_id,0) != context['generation']: raise RuntimeError('Plugin was stopped')
            if time.monotonic() > deadline: raise TimeoutError('Plugin callback exceeded ' + ('one second' if budget == 1 else f'{budget:g} seconds'))
            return trace
        old_trace = sys.gettrace()
        sys.settrace(trace)
        try:
            result = fn(*args)
            if background:
                with self.state_lock: self.worker_results.append((plugin_id,context['generation'],context['actions'],None,None))
            else: self.actions.extend(context['actions'])
            return result
        finally:
            sys.settrace(old_trace);_CONTEXT.reset(token)
    def register_callback(self, callback, result_type=None):
        context = dict(current())
        with self.state_lock:
            if context.get('background') and context['generation'] != self.generations.get(context['plugin'],0): raise RuntimeError('Plugin was stopped')
            if len(self.callbacks) >= 256: raise ValueError('Plugin callback limit exceeded')
            self.next_callback += 1
            key = str(self.next_callback)
            self.callbacks[key] = (callback, context, result_type)
            return key
    def remember_peers(self, response):
        from aftergram_tl import TLRPC
        users = [v for v in response if isinstance(v,TLRPC.User)] if isinstance(response,list) else ([response] if isinstance(response,TLRPC.User) else getattr(response,'users',[]))
        chats = [v for v in response if isinstance(v,TLRPC.Chat)] if isinstance(response,list) else ([response] if isinstance(response,TLRPC.Chat) else getattr(response,'chats',[]))
        for user in users:
            if isinstance(user, TLRPC.User) and getattr(user,'id',0):
                self.users[user.id] = user
                if getattr(user,'access_hash',None): self.peers[user.id] = TLRPC.TL_inputPeerUser(user_id=user.id, access_hash=user.access_hash)
        for chat in chats:
            if not getattr(chat,'id',0): continue
            self.chats[chat.id] = chat
            if isinstance(chat, TLRPC.TL_channel) and getattr(chat,'access_hash',None): self.peers[-chat.id] = TLRPC.TL_inputPeerChannel(channel_id=chat.id, access_hash=chat.access_hash)
            elif isinstance(chat, TLRPC.TL_chat): self.peers[-chat.id] = TLRPC.TL_inputPeerChat(chat_id=chat.id)
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
        self.invoke(plugin_id, spec.loader.exec_module, module, budget=10)
        classes = [c for c in vars(module).values() if isinstance(c, type) and issubclass(c, BasePlugin) and c is not BasePlugin and c.__module__ == module.__name__]
        if len(classes) != 1: raise ValueError('Expected exactly one BasePlugin subclass')
        plugin = self.invoke(plugin_id, classes[0], budget=10)
        if not hasattr(plugin, '_host'): plugin._attach(self, plugin_id)
        self.plugins[plugin_id] = plugin
        self.invoke(plugin_id, plugin.on_plugin_load, budget=10)
        self.invoke(plugin_id, plugin.on_app_event, AppEvent.START, budget=10)
        self.errors.pop(plugin_id, None)
        self.error_details.pop(plugin_id, None)
    def unload(self, plugin_id):
        from base_plugin import AppEvent
        with self.state_lock:
            plugin = self.plugins.pop(plugin_id, None)
            self.generations[plugin_id] = self.generations.get(plugin_id,0) + 1
            self.jobs = [job for job in self.jobs if job[1] != plugin_id]
            self.callbacks = {key: value for key, value in self.callbacks.items() if value[1]['plugin'] != plugin_id}
            self.dialogs = {key: value for key, value in self.dialogs.items() if value[1]['plugin'] != plugin_id}
        prefix = self.namespace + '.' + plugin_id.encode('utf-8').hex()
        try:
            if plugin:
                try: self.invoke(plugin_id, plugin.on_app_event, AppEvent.STOP)
                finally: self.invoke(plugin_id, plugin.on_plugin_unload)
        finally:
            with self.state_lock:
                self.jobs = [job for job in self.jobs if job[1] != plugin_id]
                self.dialogs = {key:value for key,value in self.dialogs.items() if value[1]['plugin'] != plugin_id}
            for name in list(sys.modules):
                if name == prefix or name.startswith(prefix + '.'): del sys.modules[name]
    def package(self, path, adapt):
        source = Path(path)
        if source.suffix.lower() in {'.py', '.plugin'}:
            if source.stat().st_size > MAX_SOURCE: raise ValueError('Plugin source exceeds 2 MB')
            text = source.read_text(encoding='utf-8-sig')
            report = analyze(text, adapt)
            return {'report': report, 'files': {'main.py': report['source'].encode()}, 'entry': 'main.py', 'refmap': {}, 'original': text.encode()}
        if source.suffix.lower() not in {'.elyx', '.eaf', '.zip'}: raise ValueError('Import a .plugin, .py or Elyx source archive')
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
        params = node({'message': text, 'peer': int(request['peer']), 'account': request['account'], 'entities': None})
        ordered = sorted(list(self.plugins.items()), key=lambda item: (-(item[1]._send_priority or 0), item[0]))
        cancelled = False
        for plugin_id, plugin in ordered:
            if plugin._send_priority is None: continue
            previous = copy.deepcopy(params)
            checkpoint = len(self.actions)
            try:
                result = self.invoke(plugin_id, plugin.on_send_message_hook, request['account'], params, account=request['account'], dialog_id=int(request['peer']), native_peer=request.get('native_peer'))
                if result is None: result = HookResult()
                if not isinstance(result, HookResult): raise TypeError('Expected HookResult')
                if result.strategy == HookStrategy.CANCEL:
                    cancelled = True;break
                if result.strategy in (HookStrategy.MODIFY, HookStrategy.MODIFY_FINAL):
                    changed = result.params
                    from extera_utils.text_formatting import serialize_entities, utf16_length
                    if not changed or not isinstance(changed.message, str) or utf16_length(changed.message) > 4096: raise ValueError('Invalid modified message')
                    params.message = changed.message
                    entities = getattr(changed, 'entities', None)
                    if changed.message != previous.message and entities == previous.entities: entities = None
                    params.entities = serialize_entities(entities, changed.message) if entities is not None else None
                else: params = previous
                if result.strategy == HookStrategy.MODIFY_FINAL: break
            except Exception:
                del self.actions[checkpoint:]
                params = previous;self.fail(plugin_id)
        result = {'text': params.message, 'cancel': cancelled}
        if params.entities is not None: result['entities'] = params.entities
        return result
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
        with self.state_lock:
            results,self.worker_results = self.worker_results,[]
        for plugin_id,generation,actions,error,details in results:
            if plugin_id not in self.plugins or self.generations.get(plugin_id,0) != generation: continue
            if error is not None: self.fail(plugin_id,error,details)
            else: self.actions.extend(actions)
        now = time.monotonic()
        with self.state_lock:
            ready = [j for j in self.jobs if j[0] <= now]
            self.jobs = ready[32:] + [j for j in self.jobs if j[0] > now]
            self.futures = {future for future in self.futures if not future.done()}
        for _, plugin_id, fn, account, dialog, native_peer, background in ready[:32]:
            if plugin_id not in self.plugins: continue
            if background:
                with self.state_lock:
                    if len(self.futures) >= 4:
                        self.jobs.append((now,plugin_id,fn,account,dialog,native_peer,background));continue
                    generation = self.generations.get(plugin_id,0)
                    def work(key=plugin_id, task=fn, account_id=account, peer=dialog, native=native_peer, gen=generation):
                        if self.generations.get(key,0) != gen or key not in self.plugins: return
                        try: self.invoke(key,task,account=account_id,dialog_id=peer,native_peer=native,background=True,generation=gen)
                        except Exception as error:
                            with self.state_lock: self.worker_results.append((key,gen,[],error,traceback.format_exc(limit=8)[-6000:]))
                    self.futures.add(self.executor.submit(work))
                continue
            try: self.invoke(plugin_id, fn, account=account, dialog_id=dialog, native_peer=native_peer)
            except Exception: self.fail(plugin_id)
    def handle(self, r):
        op = r['op'];plugin_id = r.get('id')
        self.locale = r.get('locale', self.locale)
        self.self_id = int(r.get('self_id', self.self_id))
        if r.get('peer_wire') and r.get('peer'):
            from aftergram_tl import decode
            self.peers[int(r['peer'])] = decode(r['peer_wire'])
        if r.get('self_user'):
            from aftergram_tl import from_json
            user = from_json(r['self_user']);self.users[user.id] = user
        if op == 'sample':
            path = self.root / 'sample.py'
            path.write_text(SAMPLE, encoding='utf-8')
            try: return self.install(path, False)
            finally: path.unlink(missing_ok=True)
        if op == 'tl_encode':
            from aftergram_tl import from_json, encode
            return {'payload': encode(from_json(r['object']))}
        if op == 'tl_fixtures':
            from aftergram_tl import native_fixtures
            return {'fixtures': native_fixtures()}
        if op == 'list':
            return {'plugins': [{'id': key, **value, 'enabled': key in self.plugins, 'error': self.errors.get(key, '')} for key, value in self.registry.items()], 'callbacks': list(self.callbacks), 'dialogs': list(self.dialogs), 'generations':dict(self.generations), 'hooks':[{'name':hook,'substring':substring} for plugin in self.plugins.values() for hook,substring,_ in plugin._hooks]}
        if op == 'request_hook':
            from aftergram_tl import BY_NAME, decode, encode, encode_result, TLRPC
            from base_plugin import HookResult, HookStrategy
            wire_name = r['name'];model = BY_NAME[wire_name];name = 'TL_' + wire_name.replace('.','_')
            stage = r['stage'];error = TLRPC.TL_error(**r['error']) if r.get('error') else None
            value = None if error else decode(r['payload'], 'Object' if stage == 'pre' else model['result'])
            matched = []
            for key, plugin in self.plugins.items():
                priorities = [p for hook,sub,p in plugin._hooks if (hook in name if sub else hook == name)]
                if priorities: matched.append((max(priorities),key,plugin))
            for _,key,plugin in sorted(matched, key=lambda entry: -entry[0]):
                previous = copy.deepcopy(value);checkpoint = len(self.actions)
                try:
                    args = (name,self.account,value) if stage == 'pre' else (name,self.account,value,error)
                    callback = plugin.pre_request_hook if stage == 'pre' else plugin.post_request_hook
                    result = self.invoke(key, callback, *args)
                    if result is None: result = HookResult()
                    if not isinstance(result, HookResult): raise TypeError('Expected HookResult')
                    if result.strategy == HookStrategy.CANCEL: return {'cancel':True}
                    if result.strategy in {HookStrategy.MODIFY,HookStrategy.MODIFY_FINAL} and not error:
                        value = result.request if stage == 'pre' else result.response
                        if stage == 'pre' and getattr(value,'_model',{}).get('name') != wire_name: raise ValueError('A request hook cannot change the Telegram method')
                        if stage == 'pre': encode(value)
                        else: encode_result(value, model['result'])
                    else: value = previous
                    if result.strategy == HookStrategy.MODIFY_FINAL: break
                except Exception:
                    del self.actions[checkpoint:];value = previous;self.fail(key)
            return {'payload':r.get('payload','') if error else (encode(value) if stage == 'pre' else encode_result(value, model['result']))}
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
                if row.kind in {'Input', 'EditText'}:
                    maximum = getattr(row, 'max_length', None)
                    if maximum is not None and len(value) > int(maximum): raise ValueError('Text exceeds the setting length limit')
                    mask = getattr(row, 'mask', None)
                    if mask and not re.fullmatch(mask, value): raise ValueError('Text does not match the setting format')
                if row.kind == 'Selector' and (not isinstance(value, int) or isinstance(value, bool) or not 0 <= value < len(row.items)): raise ValueError('Invalid selector index')
                self.invoke(plugin_id, plugin.set_setting, row.key, r['value'])
                if row.on_change: self.invoke(plugin_id, row.on_change, r['value'])
            elif row.on_click: self.invoke(plugin_id, row.on_click, None)
            return {'rows': self.settings_rows(plugin_id, r.get('path', []))}
        if op == 'long_press':
            self.settings_rows(plugin_id, r.get('path', []))
            plugin = self.plugins[plugin_id];row = plugin._rows[r['index']]
            callback = getattr(row, 'on_long_click', None)
            if callback: self.invoke(plugin_id, callback, None)
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
            ordered = sorted(list(self.plugins.items()), key=lambda item: -max([priority for hook, substring, priority in item[1]._hooks if (hook in name if substring else hook == name)] or [0]))
            for key, plugin in ordered:
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
        if op == 'native_error':
            self.logs.append(str(r['text']));self.logs = self.logs[-100:]
            self.actions.append({'type':'notice', 'text':str(r['text'])})
            return {}
        if op == 'rpc_result':
            pending = self.callbacks.pop(str(r['callback']), None)
            if pending is None: return {}
            callback, ctx, result_type = pending
            key = ctx['plugin']
            if key not in self.plugins: return {}
            try:
                from aftergram_tl import decode
                from aftergram_tl import TLRPC
                error = TLRPC.TL_error(**r['error']) if r.get('error') else None
                response = decode(r['payload'], result_type) if not error else None
                if response is not None: self.remember_peers(response)
                self.invoke(key, callback, response, error, account=ctx['account'], dialog_id=ctx['dialog_id'], native_peer=ctx.get('native_peer'))
            except Exception: self.fail(key)
            return {}
        if op == 'dialog_event':
            entry = self.dialogs.get(str(r['dialog']))
            if not entry: return {}
            dialog, ctx = entry;key = ctx['plugin']
            if key not in self.plugins: return {}
            try: self.invoke(key, dialog._event, r['event'], int(r.get('which',0)), r.get('values',[]), account=ctx['account'], dialog_id=ctx['dialog_id'], native_peer=ctx.get('native_peer'))
            except Exception: self.fail(key)
            return {}
        if op == 'logs': return {'logs': self.logs[-100:]}
        if op == 'close':
            for key in list(self.plugins): self.unload(key)
            self.executor.shutdown(wait=False,cancel_futures=True)
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
            host = Host(root, r['account'], r);_HOSTS[root] = host
        host.actions = []
        result = host.handle(r)
        result['actions'] = host.actions
        return json.dumps(result, ensure_ascii=False)
    except Exception as error:
        details = traceback.format_exc(limit=8)[-6000:]
        if 'host' in locals():
            host.logs.append(details);host.logs = host.logs[-100:]
        return json.dumps({'error': error_summary(error)}, ensure_ascii=False)

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
