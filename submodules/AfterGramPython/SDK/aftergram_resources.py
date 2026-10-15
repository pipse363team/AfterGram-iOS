"""Adapt data-file access for libraries delivered inside the SDK archive."""
from importlib.resources import files
import os
from pathlib import Path

def install():
    try:
        import pytz
    except ImportError:
        return
    resource_root = files('pytz').joinpath('zoneinfo')
    def open_resource(name):
        parts = Path(str(name)).parts
        if not parts or any(part in {'', '.', '..'} for part in parts):
            raise ValueError('Invalid timezone resource path')
        custom = os.environ.get('PYTZ_TZDATADIR')
        if custom:
            return (Path(custom).joinpath(*parts)).open('rb')
        return resource_root.joinpath(*parts).open('rb')
    pytz.open_resource = open_resource

class Resources:
    def getIdentifier(self, name, kind=None, package=None): return 0
    def getString(self, resource_id): raise LookupError('Android string resources are not available on iOS')
    def getDrawable(self, resource_id): raise LookupError('Android drawable resources are not available on iOS')

class ColorStateList:
    def __init__(self, color): self.defaultColor = color
    @staticmethod
    def valueOf(color): return ColorStateList(color)
