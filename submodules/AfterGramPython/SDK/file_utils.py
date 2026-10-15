from pathlib import Path
import logging
from aftergram_host import current

def get_plugin_dir(): return str(current()['directory'])
def get_cache_dir():
    p = Path(get_plugin_dir()) / 'cache';p.mkdir(exist_ok=True);return str(p)
def get_plugins_dir(): return str(current()['host'].root)
def _directory(name):
    path = Path(get_plugin_dir()) / 'files' / name
    path.mkdir(parents=True, exist_ok=True)
    return str(path)
def get_files_dir(): return _directory('')
def get_images_dir(): return _directory('images')
def get_videos_dir(): return _directory('videos')
def get_audios_dir(): return _directory('audios')
def get_documents_dir(): return _directory('documents')
def ensure_dir_exists(path): Path(path).mkdir(parents=True, exist_ok=True)
def list_dir(path, recursive=False, include_files=True, include_dirs=False, extensions=None):
    suffixes = {('.' + str(ext).lstrip('.')).lower() for ext in extensions} if extensions else None
    directory = Path(path)
    return [str(p) for p in (directory.rglob('*') if recursive else directory.iterdir())
            if ((include_files and p.is_file()) or (include_dirs and p.is_dir())) and (suffixes is None or p.suffix.lower() in suffixes)]
def read_file(path):
    try: return Path(path).read_text(encoding='utf-8')
    except (OSError, UnicodeError): logging.getLogger('plugin').exception('Cannot read file');return None
def write_file(path, content): Path(path).write_text(content, encoding='utf-8')
def read_file_bytes(path):
    try: return Path(path).read_bytes()
    except OSError: logging.getLogger('plugin').exception('Cannot read file');return None
def write_file_bytes(path, content): Path(path).write_bytes(content)
def delete_file(path):
    try: Path(path).unlink();return True
    except OSError: return False
