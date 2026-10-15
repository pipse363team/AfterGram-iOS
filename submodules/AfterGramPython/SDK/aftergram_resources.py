"""Adapt data-file access for libraries delivered inside the SDK archive."""
from importlib.resources import files
import os
from pathlib import Path

def install():
    try: import pytz
    except ImportError: return
    if '.zip/' not in (pytz.__file__ or ''): return
    resource_root = files('pytz').joinpath('zoneinfo')
    def open_resource(name):
        parts = str(name).lstrip('/').split('/')
        if any(part in {'','..','.'} or '\\' in part for part in parts): raise ValueError('Invalid timezone resource path')
        custom = os.environ.get('PYTZ_TZDATADIR')
        if custom: return Path(custom).joinpath(*parts).open('rb')
        return resource_root.joinpath(*parts).open('rb')
    pytz.open_resource = open_resource
