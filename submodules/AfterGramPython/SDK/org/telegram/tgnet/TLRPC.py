from aftergram_tl import TLRPC as _types
__supported_symbols__ = set(vars(_types))
def __getattr__(name): return getattr(_types, name)
