#!/usr/bin/env python3
"""Make a relocatable CLI bundle; reject unresolved or unaccounted dependencies."""
import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import zipfile


SYSTEM = ('/usr/lib/', '/System/Library/')
# Darwin's stable public iconv API supplies the same three imported functions.
# Using the OS copy also uses its matching character maps instead of Nix's paths.
PLATFORM_LIBRARIES = {
    'libiconv.2.dylib': '/usr/lib/libiconv.2.dylib',
    'libcharset.1.dylib': '/usr/lib/libcharset.1.dylib',
}


def command(*args):
    return subprocess.check_output(args, text=True).strip()


def dependencies(path):
    identity = command('otool', '-D', str(path)).splitlines()[1:]
    own = identity[0].strip() if identity else None
    return [value for line in command('otool', '-L', str(path)).splitlines()[1:]
            if (value := line.strip().split(' (compatibility', 1)[0]) != own]


def rpaths(path):
    lines = command('otool', '-l', str(path)).splitlines()
    return [lines[i + 2].strip().split('path ', 1)[1].split(' (offset', 1)[0]
            for i, line in enumerate(lines) if line.strip() == 'cmd LC_RPATH']


def notice_name(name):
    return re.search(r'COPYING|LICEN[CS]E|COPYRIGHT|NOTICE|^README', name, re.I)


def copy_notices(source, target):
    target.mkdir(parents=True, exist_ok=True)
    if source.is_dir():
        files = ((str(p.relative_to(source)), p.read_bytes()) for p in source.rglob('*')
                 if p.is_file() and len(p.relative_to(source).parts) <= 3 and notice_name(p.name))
    elif zipfile.is_zipfile(source):
        with zipfile.ZipFile(source) as archive:
            files = [(name, archive.read(name)) for name in archive.namelist()
                     if not name.endswith('/') and len(Path(name).parts) <= 4 and notice_name(Path(name).name)]
    else:
        with tarfile.open(source) as archive:
            files = [(m.name, archive.extractfile(m).read()) for m in archive.getmembers()
                     if m.isfile() and len(Path(m.name).parts) <= 4 and notice_name(Path(m.name).name)]
    count = 0
    for name, data in files:
        (target / name.replace('/', '__')).write_bytes(data)
        count += 1
    if not count:
        raise RuntimeError(f'No license notices found in {source.name}')


def build(args):
    package = Path(args.package).resolve()
    output = Path(args.output)
    output.mkdir(parents=True, exist_ok=False)
    (output / 'bin').mkdir()
    (output / 'lib').mkdir()
    notices = output / 'share' / 'licenses'
    notices.mkdir(parents=True)
    source = Path(args.source)
    shutil.copy2(source / 'LICENSE', notices / 'My-Pod.txt')
    shutil.copy2(source / 'core/libgpod/COPYING', notices / 'libgpod-LGPL-2.1.txt')
    packages = json.loads(Path(args.sources).read_text())
    executable = package / 'bin/mypod'
    queue = [executable.resolve()]
    destinations = {executable.resolve(): output / 'bin/mypod'}
    copied_names = {}
    used_packages = {}
    mappings = {}
    while queue:
        original = queue.pop(0)
        destination = destinations[original]
        shutil.copyfile(original, destination)
        destination.chmod(0o755)
        mappings[destination] = []
        for dependency in dependencies(original):
            if dependency.startswith(SYSTEM):
                continue
            if dependency.startswith('@'):
                # Source-built Nix libraries have absolute IDs. Refuse a new
                # layout rather than accidentally resolving against the host.
                raise RuntimeError(f'Unresolved dependency: {original.name}: {dependency}')
            native = PLATFORM_LIBRARIES.get(Path(dependency).name)
            if native:
                library = ctypes.CDLL(native)
                for symbol in (['iconv', 'iconv_open', 'iconv_close'] if 'iconv' in native else ['locale_charset']):
                    getattr(library, symbol)
                mappings[destination].append((dependency, native))
                continue
            library = Path(dependency).resolve(strict=True)
            owners = [p for p in packages if any(str(library).startswith(root + '/') for root in p['outputs'])]
            if len(owners) != 1:
                raise RuntimeError(f'Dependency needs a source/license entry: {library}')
            owner = owners[0]
            used_packages[owner['name']] = owner
            if library not in destinations:
                if library.name in copied_names and copied_names[library.name] != library:
                    raise RuntimeError(f'Conflicting library names: {library.name}')
                copied_names[library.name] = library
                destinations[library] = output / 'lib' / library.name
                queue.append(library)
            relative = ('../lib/' if destination.parent.name == 'bin' else '') + library.name
            mappings[destination].append((dependency, '@loader_path/' + relative))
    for original, destination in destinations.items():
        if destination.parent.name == 'lib':
            subprocess.run(['install_name_tool', '-id', '@loader_path/' + destination.name, str(destination)], check=True)
        for before, after in mappings[destination]:
            subprocess.run(['install_name_tool', '-change', before, after, str(destination)], check=True)
        for path in rpaths(destination):
            if not path.startswith(SYSTEM):
                subprocess.run(['install_name_tool', '-delete_rpath', path, str(destination)], check=True)
        # Same fixed-length hash replacement as Nix remove-references-to.
        # These optional data/module lookup paths were proved unnecessary by
        # the no-Nix integration test; keep Nix from retaining their closures.
        data = destination.read_bytes()
        data = re.sub(rb'/nix/store/[0-9a-z]{32}-', b'/nix/store/' + b'e' * 32 + b'-', data)
        destination.write_bytes(data)
        subprocess.run(['codesign', '--force', '--sign', '-', str(destination)], check=True)
        for dependency in dependencies(destination):
            if not dependency.startswith(SYSTEM + ('@loader_path/',)):
                raise RuntimeError(f'Non-relocatable load command: {dependency}')
        destination.chmod(0o555)
    third_party = []
    for package in sorted(used_packages.values(), key=lambda p: p['name']):
        copy_notices(Path(package['src']), notices / package['name'])
        third_party.append({key: package[key] for key in ['name', 'version', 'licenses', 'homepage']})
    metadata = {'version': args.version, 'system': args.system, 'sourceRevision': args.revision,
                'correspondingSources': f'mypod-{args.version}-sources.tar.gz', 'libraries': third_party}
    (output / 'bundle.json').write_text(json.dumps(metadata, indent=2) + '\n')
    print(json.dumps({'files': len(destinations), 'bytes': sum(p.stat().st_size for p in output.rglob('*') if p.is_file())}))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ['package', 'output', 'source', 'sources', 'version', 'system', 'revision']:
        parser.add_argument('--' + name, required=True)
    build(parser.parse_args())
