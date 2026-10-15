class Integer(int):
    @classmethod
    def valueOf(cls, value): return cls(value)
    def intValue(self): return int(self)
    TYPE = int
class Long(Integer):
    def longValue(self): return int(self)
    TYPE = int
class String(str):
    def toString(self): return str(self)
    def length(self): return len(self)
class Object: pass
class Double(float):
    def doubleValue(self): return float(self)
    TYPE = float

class Float(float):
    TYPE = float

class Math:
    @staticmethod
    def toIntExact(value):
        value = int(value)
        if not -(2 ** 31) <= value < 2 ** 31: raise OverflowError('integer overflow')
        return value
    @staticmethod
    def abs(value): return abs(value)
    @staticmethod
    def min(first, second): return min(first, second)
    @staticmethod
    def max(first, second): return max(first, second)

class Class:
    @staticmethod
    def forName(name): return None
class Boolean:
    def __init__(self, value=False): self.value = bool(value)
    def __bool__(self): return self.value
    def booleanValue(self): return self.value
    TYPE = bool

class ArrayList(list):
    def add(self, value): self.append(value);return True
    def get(self, index): return self[index]
    def size(self): return len(self)

class HashMap(dict):
    def put(self, key, value): previous = self.get(key);self[key] = value;return previous
    def getOrDefault(self, key, default): return self.get(key, default)
    def containsKey(self, key): return key in self

class HashSet(set):
    def add(self, value):
        existed = value in self;super().add(value);return not existed
    def contains(self, value): return value in self

class Date:
    def __init__(self, millis=None):
        import time
        self.millis = int(time.time() * 1000) if millis is None else int(millis)
    def getTime(self): return self.millis

class UUID:
    @staticmethod
    def randomUUID():
        import uuid
        return uuid.uuid4()

class Locale:
    US = 'en_US'
    @staticmethod
    def getDefault(): return 'en_US'

class Objects:
    @staticmethod
    def equals(first, second): return first == second
    @staticmethod
    def hash(*values): return hash(values)

class File:
    def __init__(self, path, child=None):
        from pathlib import Path
        self.path = Path(path) / child if child is not None else Path(path)
    def exists(self): return self.path.exists()
    def isFile(self): return self.path.is_file()
    def isDirectory(self): return self.path.is_dir()
    def getName(self): return self.path.name
    def getAbsolutePath(self): return str(self.path.resolve())
    def length(self): return self.path.stat().st_size if self.path.exists() else 0
    def __str__(self): return str(self.path)

class ByteArrayInputStream:
    def __init__(self, data):
        import io
        self._stream = io.BytesIO(bytes(data))
    def read(self, *args): return self._stream.read(*args)
    def close(self): return self._stream.close()

class ByteArrayOutputStream:
    def __init__(self):
        import io
        self._stream = io.BytesIO()
    def write(self, data): return self._stream.write(bytes(data))
    def toByteArray(self): return self._stream.getvalue()
    def close(self): return self._stream.close()

InputStream = ByteArrayInputStream
OutputStream = ByteArrayOutputStream

def dynamic_proxy(interface, handler=None):
    """Create a small Python callback proxy for portable SDK interfaces."""
    if handler is None: return interface
    class Proxy:
        __interface__ = interface
        def __getattr__(self, method):
            def call(*args):
                invoke = getattr(handler, 'invoke', None)
                if callable(invoke): return invoke(None, method, list(args))
                if callable(handler): return handler(method, *args)
                target = getattr(handler, method, None)
                if callable(target): return target(*args)
                raise NotImplementedError('No portable callback for ' + str(method))
            return call
    return Proxy()
