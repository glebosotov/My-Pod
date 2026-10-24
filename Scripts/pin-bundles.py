#!/usr/bin/env python3
"""Validate both CI artifacts and pin their release hashes together."""
import argparse
import base64
import hashlib
import json
import re
import subprocess
from pathlib import Path
import tarfile


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').digest()


def asset(path, version, *, unpack=False):
    result = {'file': path.name, 'hash': 'sha256-' + base64.b64encode(digest(path)).decode(),
            'bytes': path.stat().st_size,
            'url': f'https://github.com/glebosotov/My-Pod/releases/download/v{version}/{path.name}'}
    if unpack:
        info = json.loads(subprocess.check_output(
            ['nix', 'store', 'prefetch-file', '--json', '--name', 'source', '--unpack', path.resolve().as_uri()], text=True))
        result['unpackedHash'] = info['hash']
    return result


def pin(root, revision, output):
    if not re.fullmatch(r'[0-9a-f]{40}', revision):
        raise ValueError('Expected the full CI source commit')
    bundles = {}
    metadata = []
    versions = set()
    for system in ['aarch64-darwin', 'x86_64-darwin']:
        directory = root / ('mypod-' + system)
        if (directory / 'SOURCE_REVISION').read_text().strip() != revision:
            raise ValueError(f'{system}: wrong source revision')
        sums = {}
        for line in (directory / 'SHA256SUMS').read_text().splitlines():
            expected, name = line.split()
            if Path(name).name != name or digest(directory / name).hex() != expected:
                raise ValueError(f'Invalid checksum: {name}')
            sums[name] = expected
        archives = list(directory.glob('*-' + system + '.tar.gz'))
        if len(archives) != 1:
            raise ValueError(f'{system}: expected one binary archive')
        archive = archives[0]
        if archive.name not in sums:
            raise ValueError('Missing binary checksum')
        with tarfile.open(archive) as tar:
            members = tar.getmembers()
            if any(Path(m.name).is_absolute() or '..' in Path(m.name).parts
                   or not (m.isfile() or m.isdir()) for m in members):
                raise ValueError('Unsafe binary archive members')
            manifests = [m for m in members if m.name.endswith('/bundle.json')]
            if len(manifests) != 1:
                raise ValueError('Expected exactly one bundle manifest')
            info = json.load(tar.extractfile(manifests[0]))
            if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?', info['version']):
                raise ValueError('Invalid release version')
            prefix = f'mypod-{info["version"]}-{system}'
            if any(Path(m.name).parts[0] != prefix for m in members):
                raise ValueError('Unexpected archive root')
            if manifests[0].name != prefix + '/bundle.json' or archive.name != prefix + '.tar.gz':
                raise ValueError('Archive/version mismatch')
        if info['sourceRevision'] != revision or info['system'] != system:
            raise ValueError('Bundle provenance mismatch')
        versions.add(info['version'])
        metadata.append(info)
        bundles[system] = asset(archive, info["version"], unpack=True)
    if len(versions) != 1:
        raise ValueError('Architectures have different versions')
    version = versions.pop()
    sources = root / 'mypod-aarch64-darwin' / f'mypod-{version}-sources.tar.gz'
    if any(m['correspondingSources'] != sources.name for m in metadata):
        raise ValueError('Wrong corresponding-source archive')
    with tarfile.open(sources) as tar:
        names = {m.name for m in tar}
    prefix = f'mypod-{version}-sources'
    if prefix + '/mypod/core/libgpod/COPYING' not in names:
        raise ValueError('Missing vendored libgpod source/license')
    for info in metadata:
        for library in info['libraries']:
            if prefix + '/third-party/' + library['name'] + '-' + library['version'] not in names:
                raise ValueError('Missing corresponding source: ' + library['name'])
    result = {'version': version, 'sourceRevision': revision, 'bundles': bundles, 'sources': asset(sources, version)}
    output.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('artifacts', type=Path)
    parser.add_argument('--revision', required=True)
    parser.add_argument('--output', type=Path, default=Path('nix/releases.json'))
    args = parser.parse_args()
    pin(args.artifacts, args.revision, args.output)
