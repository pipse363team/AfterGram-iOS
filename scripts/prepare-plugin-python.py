#!/usr/bin/env python3
"""Prepare checksum-pinned Python iOS frameworks and Bazel resource bundles."""
import argparse, hashlib, io, json, os, plistlib, shutil, subprocess, sys, tarfile, urllib.request, zipfile
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
VERSION = '3.11-b11'
SHA256 = '92bda6f03a5fc5fd696b946b1917e7160e625b2ea618a43a7d6b66e9cf849b5f'
URL = f'https://github.com/beeware/Python-Apple-support/releases/download/{VERSION}/Python-3.11-iOS-support.b11.tar.gz'

PACKAGES = [('requests', '2.32.5', '2462f94637a34fd532264295e186976db0f5d453d1cdd31473c85a6a161affb6'), ('packaging', '25.0', '29572ef2b1f17581046b3a2227d5c611fb25ec70ca1ba8554b24b0e69331a484'), ('urllib3', '2.5.0', 'e6b01673c0fa6a13e374b50871808eb3bf7046c4b125b216f6bf1cc604cff0dc'), ('idna', '3.11', '771a87f49d9defaf64091e6e6fe9c18d4833f140bd19464795bc32d966ca37ea'), ('certifi', '2025.10.5', '0f212c2744a9bb6de0c56639a6f68afe01ecd92d91f14ae897c4fe7bbeeef0de'), ('charset-normalizer', '3.4.4', '7a32c560861a02ff789ad905a2fe94e3f840803362c84fecf1851cb4cf3dc37f'), ('PyYAML', '6.0.3', 'd76623373421df22fb4cf8817020cbb7ef15c725b9d5e45f17e189bfc384190f')]
PACKAGES += [
    ('mpmath', '1.3.0', 'a0b2b9fe80bbcd81a6647ff13108738cfb482d481d826cc0e02f5b35e5c88d2c'),
    ('tinydb', '4.8.2', 'f97030ee5cbc91eeadd1d7af07ab0e48ceb04aa63d4a983adbaca4cba16e86c3'),
    ('beautifulsoup4', '4.13.5', '642085eaa22233aceadff9c69651bc51e8bf3f874fb6d7104ece2beb24b47c4a'),
    ('soupsieve', '2.8', '0cc76456a30e20f5d7f2e14a98a4ae2ee4e5abdc7c5ea0aafe795f344bc7984c'),
    ('typing_extensions', '4.15.0', 'f0fa19c6845758ab08074a0cfa8b7aecb71c999ca73d62883bc25cc018c4e548'),
    ('Markdown', '3.9', '9f4d91ed810864ea88a6f32c07ba8bee1346c0cc1f6b1f9f6c822f2a9667d280'),
    ('python-dateutil', '2.9.0.post0', 'a8b2bc7bffae282281c8140a97d3aa9c14da0b136dfe83f850eea9a5f7470427'),
    ('six', '1.17.0', '4721f391ed90541fddacab5acf947aa0d3dc7d27b2e1e8eda2be8970586c3274'),
    ('pytz', '2025.2', '5ddf76296dd8c44c26eb8f4b6f35488f3ccbf6fbbd7adee0b7262d43f0ec2f00'),
]

def add_packages(z):
    cache = ROOT / 'build-input/python-packages'
    cache.mkdir(exist_ok=True)
    for name, version, digest in PACKAGES:
        data_path = cache / (name + '-' + version)
        if not data_path.exists():
            with urllib.request.urlopen(f'https://pypi.org/pypi/{name}/{version}/json', timeout=30) as response:
                metadata = json.load(response)
            asset = next(a for a in metadata['urls'] if (a['packagetype'] == 'sdist' if name == 'PyYAML' else a['filename'].endswith('none-any.whl')))
            urllib.request.urlretrieve(asset['url'], data_path)
        data = data_path.read_bytes()
        if hashlib.sha256(data).hexdigest() != digest: raise ValueError('Package checksum mismatch: ' + name)
        if name == 'PyYAML':
            with tarfile.open(fileobj=io.BytesIO(data)) as tar:
                for member in tar.getmembers():
                    if member.isfile() and '/lib/yaml/' in member.name and member.name.endswith('.py'):
                        target = 'yaml/' + member.name.split('/lib/yaml/', 1)[1]
                        z.writestr(target, tar.extractfile(member).read())
                    elif member.isfile() and member.name.endswith('/LICENSE'):
                        z.writestr('aftergram_licenses/PyYAML-LICENSE', tar.extractfile(member).read())
        else:
            with zipfile.ZipFile(io.BytesIO(data)) as wheel:
                for member in wheel.infolist():
                    if not member.is_dir(): z.writestr(member.filename, wheel.read(member))

def prepare(archive=None, fix_install_names=True):
    subprocess.run([sys.executable, str(ROOT / 'scripts/generate-plugin-tl.py')], check=True)
    out = ROOT / 'build-input/aftergram-python'
    out.mkdir(parents=True, exist_ok=True)
    cache = ROOT / 'build-input/python-ios.tar.gz'
    if archive:
        cache = Path(archive)
    elif not cache.exists():
        urllib.request.urlretrieve(URL, cache)
    if hashlib.sha256(cache.read_bytes()).hexdigest() != SHA256:
        raise ValueError('Python support archive checksum mismatch')
    source = out / 'support'
    if not source.exists():
        source.mkdir()
        with tarfile.open(cache) as tar:
            for member in tar.getmembers():
                if member.name.startswith('/') or '..' in Path(member.name).parts:
                    raise ValueError('Invalid archive path')
            tar.extractall(source, filter='data')
    xc = source / 'Python.xcframework'
    frameworks = out / 'frameworks'
    if frameworks.exists(): shutil.rmtree(frameworks)
    frameworks.mkdir()
    python_xc = frameworks / 'Python.xcframework'
    python_xc.mkdir()
    # Only runtime framework slices belong in the xcframework, not the SDK/lib trees.
    shutil.copy2(xc / 'Info.plist', python_xc / 'Info.plist')
    for identifier in ['ios-arm64', 'ios-arm64_x86_64-simulator']:
        dest = python_xc / identifier
        dest.mkdir()
        shutil.copytree(xc / identifier / 'Python.framework', dest / 'Python.framework')
    resources = out / 'resources'
    resources.mkdir(exist_ok=True)
    native_names = []
    native_dir = xc / 'ios-arm64/lib-arm64/python3.11/lib-dynload'
    for device_binary in sorted(native_dir.glob('*.so')):
        module = device_binary.name.split('.')[0]
        if module.startswith('_test') or module == '_xxtestfuzz': continue
        framework_name = 'AGPy' + module
        framework = frameworks / (framework_name + '.xcframework')
        available = []
        for identifier, original, platform_variant in [
            ('ios-arm64', device_binary, None),
            ('ios-arm64-simulator', next((xc / 'ios-arm64_x86_64-simulator/lib-arm64/python3.11/lib-dynload').glob(module + '.*.so'), None), 'simulator')]:
            if original is None: raise ValueError(f'Missing simulator extension: {module}')
            fw = framework / identifier / (framework_name + '.framework')
            fw.mkdir(parents=True)
            binary = fw / framework_name
            shutil.copy2(original, binary)
            if fix_install_names:
                subprocess.run(['install_name_tool', '-id', f'@rpath/{framework_name}.framework/{framework_name}', str(binary)], check=True)
            plistlib.dump({'CFBundleExecutable': framework_name, 'CFBundleIdentifier': 'org.aftergram.python.' + module.replace('_', '-'), 'CFBundleName': framework_name, 'CFBundlePackageType': 'FMWK', 'CFBundleVersion': '1', 'CFBundleShortVersionString': '1.0', 'MinimumOSVersion': '13.0', 'CFBundleSupportedPlatforms': ['iPhoneSimulator' if platform_variant else 'iPhoneOS']}, (fw / 'Info.plist').open('wb'))
            entry = {'LibraryIdentifier': identifier, 'LibraryPath': framework_name + '.framework', 'BinaryPath': framework_name + '.framework/' + framework_name, 'SupportedArchitectures': ['arm64'], 'SupportedPlatform': 'ios'}
            if platform_variant: entry['SupportedPlatformVariant'] = platform_variant
            available.append(entry)
        plistlib.dump({'XCFrameworkFormatVersion': '1.0', 'CFBundlePackageType': 'XFWK', 'AvailableLibraries': available}, (framework / 'Info.plist').open('wb'))
        native_names.append((module, framework_name))
    with zipfile.ZipFile(resources / 'python311.zip', 'w', zipfile.ZIP_STORED) as z:
        lib = xc / 'lib/python3.11'
        for f in sorted(lib.rglob('*')):
            if f.is_file() and not any(part in {'test', 'tests', '__pycache__', 'ensurepip', 'idlelib', 'tkinter'} for part in f.relative_to(lib).parts) and f.suffix in {'.py', '.txt'}:
                z.write(f, str(f.relative_to(lib)))
    with zipfile.ZipFile(resources / 'aftergram_sdk.zip', 'w', zipfile.ZIP_STORED) as z:
        sdk = ROOT / 'submodules/AfterGramPython/SDK'
        for f in sorted(sdk.rglob('*')):
            if f.is_file() and f.suffix in {'.py', '.json'}: z.write(f, str(f.relative_to(sdk)))
        add_packages(z)
    (resources / 'native-modules.json').write_text(json.dumps(dict(native_names)))
    shutil.copy2(xc / 'lib/python3.11/LICENSE.txt', resources / 'PYTHON-LICENSE.txt')
    lines = ['load("@build_bazel_rules_apple//apple:apple.bzl", "apple_dynamic_xcframework_import")', 'load("@build_bazel_rules_apple//apple:resources.bzl", "apple_resource_bundle")', 'package(default_visibility = ["//visibility:public"])']
    for name in ['Python'] + [fw for _, fw in native_names]:
        lines.append(f'apple_dynamic_xcframework_import(name="{name}", xcframework_imports=glob(["frameworks/{name}.xcframework/**"]))')
    lines.append('apple_resource_bundle(name="stdlib", bundle_name="AfterGramPython", resources=glob(["resources/*"]))')
    lines.append('alias(name="runtime", actual=":Python")')
    lines.append('filegroup(name="bundle_files", srcs=[":stdlib"])')
    # A library propagates all extension frameworks to both the app and test host.
    lines.insert(0, 'load("@rules_cc//cc:objc_library.bzl", "objc_library")')
    lines.append('objc_library(name="extensions", deps=[' + ','.join('":' + fw + '"' for _, fw in native_names) + '])')
    (out / 'BUILD.bazel').write_text('\n'.join(lines) + '\n')
    (out / 'MODULE.bazel').write_text('module(name="aftergram_python")\n')
    print(f'Prepared Python 3.11, {len(native_names)} native modules and AfterGram SDK.')

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--archive')
    parser.add_argument('--skip-install-names', action='store_true', help='For Linux packaging checks only')
    args = parser.parse_args()
    prepare(args.archive, not args.skip_install_names)
