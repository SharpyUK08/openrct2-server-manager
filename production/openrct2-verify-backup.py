#!/usr/bin/env python3
"""Read-only archive manifest/checksum and traversal validation."""
import hashlib
import json
import re
import sys
import tarfile
from pathlib import PurePosixPath

if len(sys.argv) != 2:
    raise SystemExit('Usage: openrct2-verify-backup ARCHIVE.tar.gz')
path = sys.argv[1]
if not re.search(r'openrct2-[0-9]{8}T[0-9]{6}Z\.tar\.gz\Z', path.rsplit('/', 1)[-1]):
    raise SystemExit('Refusing an unexpected archive filename.')
with tarfile.open(path, 'r:gz') as archive:
    members = archive.getmembers()
    for member in members:
        name = member.name.removeprefix('./')
        parts = PurePosixPath(name).parts
        if (not (member.isfile() or member.isdir()) or member.issym() or member.islnk() or
                name.startswith('/') or '..' in parts):
            raise SystemExit(f'Unsafe archive member: {member.name}')
    manifest_member = next((item for item in members if item.name.removeprefix('./') == 'manifest.json'), None)
    if manifest_member is None or manifest_member.size > 10 * 1024 * 1024:
        raise SystemExit('Missing or oversized manifest.json.')
    manifest = json.load(archive.extractfile(manifest_member))
    if manifest.get('schema') != 1 or not isinstance(manifest.get('files'), list):
        raise SystemExit('Unsupported manifest schema.')
    indexed = {item.name.removeprefix('./'): item for item in members if item.isfile()}
    records = manifest['files']
    if len(records) != len({record.get('path') for record in records}):
        raise SystemExit('Manifest contains duplicate paths.')
    if set(indexed) - {'manifest.json'} != {record.get('path') for record in records}:
        raise SystemExit('Archive and manifest file lists differ.')
    for record in records:
        name = record.get('path'); member = indexed.get(name)
        if member is None or member.size != record.get('size'):
            raise SystemExit(f'Missing or wrong-sized member: {name}')
        digest = hashlib.sha256()
        stream = archive.extractfile(member)
        for chunk in iter(lambda: stream.read(1024 * 1024), b''): digest.update(chunk)
        if digest.hexdigest() != record.get('sha256'):
            raise SystemExit(f'Checksum mismatch: {name}')
print(f'Archive verified: {path} ({len(manifest["files"])} files)')
