"""Newer Android SDK namespace layout, using the same generated TL models."""
import types
from aftergram_tl import SCHEMA, TLRPC
__supported_symbols__ = {'TL_' + m['name'].split('.')[0] for m in SCHEMA if '.' in m['name']}

class _Namespace(types.SimpleNamespace):
    def __init__(self, namespace): self.namespace = namespace
    def __getattr__(self, name):
        key = name.removeprefix('TL_')
        try: return getattr(TLRPC, 'TL_' + self.namespace + '_' + key)
        except AttributeError: return getattr(TLRPC, self.namespace + '_' + key)

def __getattr__(name):
    if name in __supported_symbols__: return _Namespace(name[3:])
    raise AttributeError(name)
