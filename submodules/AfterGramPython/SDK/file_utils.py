from pathlib import Path
from aftergram_host import current

def get_plugin_dir(): return str(current()['directory'])
def get_cache_dir():
    p = Path(get_plugin_dir()) / 'cache';p.mkdir(exist_ok=True);return str(p)
def read_file(path): return Path(path).read_text(encoding='utf-8')
def write_file(path, content): Path(path).write_text(content, encoding='utf-8')
