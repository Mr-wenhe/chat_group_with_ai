#!/usr/bin/env python3
"""Bundle a checksum-pinned Node runtime; no runtime installation on user devices."""
import argparse
import hashlib
import io
import json
from pathlib import Path
import shutil
import tarfile
import urllib.request
import zipfile

VERSION = '24.14.1'
ARCHIVES = {
    'darwin-arm64': ('tar.gz', '25495ff85bd89e2d8a24d88566d7e2f827c6b0d3d872b2cebf75371f93fcb1fe'),
    'darwin-x64': ('tar.gz', '2526230ad7d922be82d4fdb1e7ee1e84303e133e3b4b0ec4c2897ab31de0253d'),
    'win-x64': ('zip', '6e50ce5498c0cebc20fd39ab3ff5df836ed2f8a31aa093cecad8497cff126d70'),
}
SOURCES = ('desktop_worker.ts', 'public_web_transport.ts', 'public_web_dns.ts', 'network_security.ts', 'types.ts', 'github_skill_upstream.ts')


def package(target, destination):
    extension, expected = ARCHIVES[target]
    name = f'node-v{VERSION}-{target}'
    repo = Path(__file__).resolve().parent.parent
    cache = repo / 'build' / 'web_worker_cache'
    cache.mkdir(parents=True, exist_ok=True)
    archive = cache / f'{name}.{extension}'
    if not archive.exists():
        with urllib.request.urlopen(f'https://nodejs.org/dist/v{VERSION}/{archive.name}', timeout=60) as response:
            payload = response.read(100 * 1024 * 1024 + 1)
        if hashlib.sha256(payload).hexdigest() != expected:
            raise ValueError('Node archive checksum mismatch')
        archive.write_bytes(payload)
    payload = archive.read_bytes()
    if hashlib.sha256(payload).hexdigest() != expected:
        raise ValueError('Cached Node archive checksum mismatch')
    destination.mkdir(parents=True, exist_ok=True)
    binary = 'node.exe' if target.startswith('win-') else 'node'
    if extension == 'zip':
        with zipfile.ZipFile(io.BytesIO(payload)) as source:
            node = source.read(f'{name}/node.exe')
            license_text = source.read(f'{name}/LICENSE')
    else:
        with tarfile.open(fileobj=io.BytesIO(payload), mode='r:gz') as source:
            node = source.extractfile(f'{name}/bin/node').read()
            license_text = source.extractfile(f'{name}/LICENSE').read()
    (destination / binary).write_bytes(node)
    (destination / binary).chmod(0o755)
    (destination / 'LICENSE.node').write_bytes(license_text)
    (destination / 'package.json').write_text(json.dumps({'private': True, 'type': 'module'}))
    (destination / 'src').mkdir(exist_ok=True)
    for filename in SOURCES:
        shutil.copyfile(repo / 'gateway' / 'src' / filename, destination / 'src' / filename)
    (destination / 'runtime.json').write_text(json.dumps({'version': VERSION, 'target': target, 'archiveSha256': expected}))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('target', choices=ARCHIVES)
    parser.add_argument('destination', type=Path)
    args = parser.parse_args()
    package(args.target, args.destination)
