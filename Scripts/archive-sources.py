#!/usr/bin/env python3
"""Collect corresponding first/third-party source, patches and Nix build recipes."""
import argparse
import json
from pathlib import Path
import shutil

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--source', required=True)
p.add_argument('--manifest', required=True)
p.add_argument('--output', required=True)
a = p.parse_args()
root = Path(a.output)
root.mkdir(parents=True)
shutil.copytree(a.source, root / 'mypod', symlinks=True)
entries = json.loads(Path(a.manifest).read_text())
for entry in entries:
    target = root / 'third-party' / (entry['name'] + '-' + entry['version'])
    target.mkdir(parents=True)
    source = Path(entry['src'])
    if source.is_dir():
        shutil.copytree(source, target / 'source', symlinks=True)
    else:
        shutil.copyfile(source, target / source.name)
    patches = target / 'patches'
    patches.mkdir()
    for patch in entry['patches']:
        shutil.copyfile(patch, patches / Path(patch).name)
    shutil.copytree(entry['recipe'], target / 'nix-recipe', symlinks=True)
    (target / 'metadata.json').write_text(json.dumps({k: entry[k] for k in ['name', 'version', 'licenses', 'homepage']}, indent=2) + '\n')
