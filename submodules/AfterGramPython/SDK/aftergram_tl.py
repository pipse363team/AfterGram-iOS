"""Java-shaped Telegram models backed by the native client's exact wire schema."""
import base64
import copy
import io
import json
from pathlib import Path
import re
import struct
import types
import zipfile

def _schema():
    filename = str(Path(__file__).with_name('aftergram_tl_schema.json'))
    if '.zip/' in filename:
        archive, member = filename.split('.zip/', 1)
        with zipfile.ZipFile(archive + '.zip') as z: return json.loads(z.read(member))
    return json.loads(Path(filename).read_text())

SCHEMA = _schema()
BY_ID = {m['id'] & 0xffffffff: m for m in SCHEMA}
BY_NAME = {m['name']: m for m in SCHEMA}
REQUEST_HOOK_NAMES = {'TL_' + m['name'].replace('.','_') for m in SCHEMA if m.get('function')}


class JavaList(list):
    def add(self, value): self.append(value);return True
    def get(self, index): return self[index]
    def set(self, index, value): old = self[index];self[index] = value;return old
    def size(self): return len(self)
    def isEmpty(self): return not self
    def toArray(self): return list(self)
    def addAll(self, values): self.extend(values);return True

def _snake(name): return re.sub(r'(?<!^)(?=[A-Z])', '_', name).lower()

class _TLType(type):
    @property
    def class_(cls): return cls
    def getSimpleName(cls): return cls.__name__
    def getName(cls): return 'org.telegram.tgnet.TLRPC$' + cls.__name__
    def isAssignableFrom(cls, other): return isinstance(other, type) and issubclass(other, cls)

class TLObject(metaclass=_TLType):
    _model = None
    def __init__(self, /, **values):
        object.__setattr__(self, '_values', {})
        object.__setattr__(self, '_assigned', set())
        if self._model:
            for f in self._model['fields']:
                kind = f['type']
                self._values[f['name']] = JavaList() if kind.startswith('[') else (0 if kind in {'Int32','Int64','Double'} else None)
        for name, value in values.items(): setattr(self, name, value)
    def __getattr__(self, name):
        key = _snake(name)
        try: values = object.__getattribute__(self, '_values')
        except AttributeError: raise AttributeError(name) from None
        if key in values: return values[key]
        flags = (self._model or {}).get('booleans', {})
        if key in flags:
            flag,bit = flags[key]
            return bool(int(self._values.get(flag, 0)) & (1 << bit))
        raise AttributeError(type(self).__name__ + '.' + name)
    def __deepcopy__(self, memo):
        result = type(self)();memo[id(self)] = result
        object.__setattr__(result,'_values',copy.deepcopy(self._values,memo))
        object.__setattr__(result,'_assigned',set(self._assigned))
        return result
    def __setattr__(self, name, value):
        if name.startswith('_'): object.__setattr__(self, name, value);return
        key = _snake(name)
        if self._model and key not in {f['name'] for f in self._model['fields']} and key not in self._model.get('booleans',{}):
            raise AttributeError('Unsupported Telegram field in this API layer: ' + type(self).__name__ + '.' + name)
        self._values[key] = JavaList(value) if isinstance(value, list) and not isinstance(value, JavaList) else value
        self._assigned.add(key)
    def getClass(self): return type(self)
    def __repr__(self): return type(self).__name__ + '(' + repr(self._values) + ')'
    def __eq__(self, other): return type(self) is type(other) and self._values == other._values

class _Namespace(types.ModuleType):
    def __getattr__(self, name):
        if name in _CLASSES: return _CLASSES[name]
        raise AttributeError('Telegram constructor is unavailable in this API layer: ' + name)

TLRPC = _Namespace('TLRPC')
_CLASSES = {}
_WIRE_CLASSES = {}
for _m in SCHEMA:
    _base = _m.get('base', 'TLObject').replace('.', '_')
    if _base not in _CLASSES: _CLASSES[_base] = type(_base, (TLObject,), {})
    _name = 'TL_' + _m['name'].replace('.', '_')
    _cls = type(_name, (_CLASSES[_base],), {'_model': _m, 'constructor': _m['id']})
    _CLASSES[_name] = _cls
    _WIRE_CLASSES[_m['id'] & 0xffffffff] = _cls
TLRPC.__dict__.update(_CLASSES)
TLRPC.TLObject = TLObject
TLRPC.TL_error = _TLType('TL_error', (TLObject,), {})

def _bytes(value):
    n = len(value)
    if n > 0xffffff: raise ValueError('Telegram byte string is too large')
    header = bytes([n]) if n < 254 else b'\xfe' + n.to_bytes(3, 'little')
    return header + value + b'\0' * (-(len(header) + n) % 4)

def _write(kind, value, depth):
    if depth > 64: raise ValueError('Telegram object nesting limit exceeded')
    if kind.startswith('['):
        if not isinstance(value, (list, tuple)) or len(value) > 100000: raise ValueError('Invalid Telegram vector')
        return struct.pack('<II', 0x1cb5c415, len(value)) + b''.join(_write(kind[1:-1], v, depth + 1) for v in value)
    if kind == 'Int32': return struct.pack('<I', int(value) & 0xffffffff)
    if kind == 'Int64': return struct.pack('<Q', int(value) & 0xffffffffffffffff)
    if kind == 'Double': return struct.pack('<d', float(value))
    if kind == 'String':
        if not isinstance(value, str): raise TypeError('Expected a Telegram string')
        return _bytes(value.encode('utf-8'))
    if kind == 'Buffer': return _bytes(bytes(value))
    if kind.lower() in {'int128','int256'}:
        data = bytes(value)
        if len(data) != int(kind[3:]) // 8: raise ValueError('Invalid fixed-width Telegram integer')
        return data
    if kind == 'Api.Bool' and isinstance(value, bool): value = TLRPC.TL_boolTrue() if value else TLRPC.TL_boolFalse()
    if not isinstance(value, TLObject) or not value._model: raise TypeError('Expected ' + kind + ', got ' + type(value).__name__)
    model = value._model
    if kind.startswith('Api.') and model.get('base') != kind.removeprefix('Api.'):
        raise TypeError('Expected ' + kind + ', got ' + type(value).__name__)
    fields = dict(value._values)
    for field in model['fields']:
        if 'flag' not in field: continue
        flag, bit = field['flag'];key = field['name'];v = fields.get(key)
        active = (v is not None) if key in value._assigned else ((isinstance(v, list) and bool(v)) or bool(int(fields.get(flag, 0)) & (1 << bit)))
        fields[flag] = (int(fields.get(flag, 0)) & ~(1 << bit)) | ((1 << bit) if active else 0)
    for name, (flag,bit) in model.get('booleans', {}).items():
        if name in value._assigned:
            fields[flag] = (int(fields.get(flag, 0)) & ~(1 << bit)) | ((1 << bit) if bool(fields[name]) else 0)
    result = [struct.pack('<I', model['id'] & 0xffffffff)]
    for field in model['fields']:
        if 'flag' in field:
            flag, bit = field['flag']
            if not int(fields.get(flag, 0)) & (1 << bit): continue
        result.append(_write(field['type'], fields.get(field['name']), depth + 1))
    return b''.join(result)

def serialize(value):
    data = _write('Object', value, 0)
    if len(data) > 8 * 1024 * 1024: raise ValueError('Telegram request exceeds 8 MB')
    return data

def encode_result(value, kind): return base64.b64encode(_write(kind, value, 0)).decode('ascii')

class _Reader:
    def __init__(self, data): self.stream = io.BytesIO(data)
    def read(self, count):
        data = self.stream.read(count)
        if len(data) != count: raise ValueError('Truncated Telegram response')
        return data
    def i32(self): return struct.unpack('<i', self.read(4))[0]
    def value(self, kind='Object', depth=0):
        if depth > 64: raise ValueError('Telegram response nesting limit exceeded')
        if kind.startswith('['):
            if self.i32() != 0x1cb5c415: raise ValueError('Invalid Telegram vector marker')
            count = self.i32()
            if not 0 <= count <= 100000: raise ValueError('Invalid Telegram vector length')
            return JavaList(self.value(kind[1:-1], depth + 1) for _ in range(count))
        if kind == 'Int32': return self.i32()
        if kind == 'Int64': return struct.unpack('<q', self.read(8))[0]
        if kind == 'Double': return struct.unpack('<d', self.read(8))[0]
        if kind in {'String','Buffer'}:
            n = self.read(1)[0];header = 1
            if n == 254: n = int.from_bytes(self.read(3), 'little');header = 4
            elif n == 255: raise ValueError('Invalid Telegram byte string')
            data = self.read(n);self.read(-(header + n) % 4)
            return data.decode('utf-8') if kind == 'String' else data
        if kind.lower() in {'int128','int256'}: return self.read(int(kind[3:]) // 8)
        constructor = self.i32() & 0xffffffff
        if constructor not in _WIRE_CLASSES: raise ValueError('Unknown Telegram constructor: ' + hex(constructor))
        result = _WIRE_CLASSES[constructor]()
        for field in result._model['fields']:
            if 'flag' in field:
                flag, bit = field['flag']
                if not int(result._values.get(flag, 0)) & (1 << bit): continue
            result._values[field['name']] = self.value(field['type'], depth + 1)
        return result

def deserialize(data, result_type='Object'):
    if len(data) > 8 * 1024 * 1024: raise ValueError('Telegram response exceeds 8 MB')
    reader = _Reader(data);result = reader.value(result_type)
    if reader.stream.read(1): raise ValueError('Trailing Telegram response data')
    return result

def encode(value): return base64.b64encode(serialize(value)).decode('ascii')
def decode(value, result_type='Object'): return deserialize(base64.b64decode(value, validate=True), result_type)

def from_json(value):
    if isinstance(value, list): return JavaList(from_json(v) for v in value)
    if isinstance(value, dict):
        if '_' not in value: raise ValueError('Telegram object needs a constructor name')
        name = 'TL_' + value['_'].replace('.', '_')
        return getattr(TLRPC, name)(**{k:from_json(v) for k,v in value.items() if k != '_'})
    return value

def native_fixtures():
    """Deterministic wire fixtures verified against Swift parsers in XCTest."""
    bases = {}
    for model in SCHEMA:
        if not model.get('function'): bases.setdefault(model['base'], []).append(model)
    for models in bases.values(): models.sort(key=lambda m: len([f for f in m['fields'] if 'flag' not in f]))
    def value(kind, visiting):
        if kind.startswith('['): return JavaList()
        if kind in {'Int32','Int64'}: return 7
        if kind == 'Double': return 1.25
        if kind == 'String': return 'test 😀'
        if kind == 'Buffer': return b'bytes'
        if kind.lower() in {'int128','int256'}: return b'\x07' * (int(kind[3:]) // 8)
        name = kind.removeprefix('Api.')
        for model in bases.get(name, []):
            if model['name'] in visiting: continue
            try: return instance(model, visiting)
            except ValueError: pass
        raise ValueError('No finite fixture for ' + kind)
    def instance(model, visiting):
        if len(visiting) > 16: raise ValueError('Fixture nesting limit')
        result = _WIRE_CLASSES[model['id'] & 0xffffffff]()
        for field in model['fields']:
            if field['name'].startswith('flags') or 'flag' in field: continue
            setattr(result, field['name'], value(field['type'], visiting | {model['name']}))
        return result
    fixtures = []
    for model in SCHEMA:
        if model.get('function'): continue
        try: fixtures.append({'name':model['name'], 'payload':encode(instance(model, set()))})
        except (ValueError, TypeError, OverflowError): pass
    return fixtures
