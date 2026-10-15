#!/usr/bin/env python3
"""Update Python-only SDK files in a verified native build and re-sign ad hoc.

Native source changes or wire-schema changes require the full build workflow.
Run this on macOS so ditto preserves IPA permissions and codesign reseals bundles.
"""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parent.parent

def overlay_sdk(original):
    source = ROOT / 'submodules/AfterGramPython/SDK'
    files = {str(p.relative_to(source)):p.read_bytes() for p in source.rglob('*') if p.is_file() and p.suffix in {'.py','.json'}}
    output = io.BytesIO()
    with zipfile.ZipFile(io.BytesIO(original)) as old:
        if json.loads(old.read('aftergram_tl_schema.json')) != json.loads(files['aftergram_tl_schema.json']):
            raise ValueError('The Telegram wire schema changed; run a full native build')
        previous = set(json.loads(old.read('aftergram_sdk_files.json'))) if 'aftergram_sdk_files.json' in old.namelist() else set()
        with zipfile.ZipFile(output,'w',compression=zipfile.ZIP_STORED) as new:
            for info in old.infolist():
                if info.filename not in files and info.filename not in previous and info.filename != 'aftergram_sdk_files.json':
                    new.writestr(info,old.read(info))
            for name,data in sorted(files.items()): new.writestr(name,data)
            new.writestr('aftergram_sdk_files.json',json.dumps(sorted(files)))
    return output.getvalue()

def verify_source(native_sha):
    if len(native_sha)!=40 or any(c not in '0123456789abcdef' for c in native_sha): raise ValueError('Invalid native source SHA')
    current = subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip()
    repository = os.environ.get('GITHUB_REPOSITORY')
    if not repository: repository = subprocess.check_output(['gh','repo','view','--json','nameWithOwner','--jq','.nameWithOwner'],cwd=ROOT,text=True).strip()
    comparison = json.loads(subprocess.check_output(['gh','api',f'repos/{repository}/compare/{native_sha}...{current}'],text=True))
    changed = comparison.get('files',[])
    if len(changed)>=300: raise ValueError('Too many changes to verify a Python-only update')
    prefixes = ('submodules/AfterGramPython/SDK/','scripts/tests/','docs/','examples/','.github/workflows/')
    allowed = {'README.md','README.en.md','.github/workflows/plugin-sdk.yml','scripts/repackage-plugin-sdk.py'}
    names = [name for f in changed for name in [f['filename'],f.get('previous_filename')] if name]
    blocked = [name for name in names if not name.startswith(prefixes) and name not in allowed]
    if blocked: raise ValueError('Native inputs changed; run a full build: ' + ', '.join(blocked))
    return current

def repackage(ipa, output, native_sha):
    if sys.platform != 'darwin': raise RuntimeError('IPA resealing requires macOS codesign and ditto')
    current = verify_source(native_sha)
    with tempfile.TemporaryDirectory(prefix='aftergram-sdk-') as directory:
        stage = Path(directory)
        subprocess.run(['ditto','-x','-k',str(ipa.resolve()),str(stage)],check=True)
        apps = list((stage/'Payload').glob('*.app'))
        if len(apps)!=1: raise ValueError('Expected one main app')
        app = apps[0]
        bundles = [p for p in app.rglob('aftergram_sdk.zip') if p.parent.name=='AfterGramPython.bundle']
        if len(bundles)!=1: raise ValueError('Expected one SDK resource bundle')
        sdk = bundles[0];sdk.write_bytes(overlay_sdk(sdk.read_bytes()))
        metadata = {'native_source':native_sha,'sdk_source':current,'sdk_sha256':hashlib.sha256(sdk.read_bytes()).hexdigest()}
        (sdk.parent/'sdk-build.json').write_text(json.dumps(metadata,indent=2)+'\n')
        owners = [p for p in sdk.parents if p==app or p.suffix=='.framework' or (p.suffix=='.bundle' and (p/'_CodeSignature/CodeResources').exists())]
        for bundle in owners:
            subprocess.run(['codesign','--force','--sign','-','--preserve-metadata=identifier,entitlements,requirements','--generate-entitlement-der',str(bundle)],check=True)
        subprocess.run(['codesign','--verify','--deep','--strict',str(app)],check=True)
        output = output.resolve();output.parent.mkdir(parents=True,exist_ok=True)
        output.unlink(missing_ok=True)
        subprocess.run(['ditto','-c','-k','--norsrc','--keepParent',str(stage/'Payload'),str(output)],check=True)
        (output.parent/'sdk-build.json').write_text(json.dumps(metadata,indent=2)+'\n')
    subprocess.run([sys.executable,str(ROOT/'scripts/verify-plugin-ipa.py'),str(output)],check=True)
    print('Repackaged SDK; native source',native_sha,'SDK source',current)

if __name__=='__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('--ipa',type=Path)
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--native-sha')
    parser.add_argument('--sdk-only',type=Path,help='Local SDK archive check without packaging an IPA')
    args=parser.parse_args()
    if args.sdk_only: args.output.write_bytes(overlay_sdk(args.sdk_only.read_bytes()))
    elif args.ipa and args.native_sha: repackage(args.ipa,args.output,args.native_sha)
    else: parser.error('Provide --ipa and --native-sha, or --sdk-only')
