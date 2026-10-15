#!/usr/bin/env python3
"""Check that the app contains its Python resources and signed-framework inputs."""
import argparse
import json
import io
import zipfile
from pathlib import Path

def verify(path):
    with zipfile.ZipFile(path) as ipa:
        names = set(ipa.namelist())
        roots = [name[:-len('Info.plist')] for name in names if name.startswith('Payload/') and name.count('/') == 2 and name.endswith('.app/Info.plist')]
        if len(roots) != 1: raise ValueError('Expected one main app bundle')
        root = roots[0]
        if root + 'Frameworks/Python.framework/Python' not in names: raise ValueError('Python framework was not embedded')
        bundles = [name[:-len('native-modules.json')] for name in names if name.startswith(root) and name.endswith('AfterGramPython.bundle/native-modules.json')]
        if not bundles: raise ValueError('AfterGram Python resource bundle was not embedded')
        resource = bundles[0]
        for file in ['python311.zip', 'aftergram_sdk.zip', 'PYTHON-LICENSE.txt']:
            if resource + file not in names: raise ValueError('Missing Python resource: ' + file)
        with zipfile.ZipFile(io.BytesIO(ipa.read(resource + 'aftergram_sdk.zip'))) as sdk:
            for file in ['aftergram_host.py','aftergram_tl.py','aftergram_tl_schema.json','ui/alert.py','extera_utils/text_formatting.py','org/telegram/tgnet/tl/__init__.py']:
                if file not in sdk.namelist(): raise ValueError('Missing plugin SDK module: ' + file)
            schema = json.loads(sdk.read('aftergram_tl_schema.json'))
            if sum(bool(model.get('function')) for model in schema) != 840 or len(schema) != 2540:
                raise ValueError('Unexpected plugin Telegram API schema')
        modules = json.loads(ipa.read(resource + 'native-modules.json'))
        for framework in modules.values():
            if root + f'Frameworks/{framework}.framework/{framework}' not in names: raise ValueError('Missing native Python extension: ' + framework)
        print('IPA includes Python, SDK/stdlib resources and', len(modules), 'native extension frameworks.')

if __name__ == '__main__':
    parser = argparse.ArgumentParser();parser.add_argument('ipa');args = parser.parse_args();verify(Path(args.ipa))
