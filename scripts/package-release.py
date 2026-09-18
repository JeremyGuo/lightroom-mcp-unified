#!/usr/bin/env python3
"""Package the already-validated MCPB stage; never include auth/config directories."""
import hashlib
import json
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile

root = Path(__file__).resolve().parents[1]
version = json.loads((root / 'server/package.json').read_text())['version']
build = root / 'build'
stage = build / 'mcpb-stage'
if not (stage / 'server/dist/index.js').is_file():
    raise SystemExit('Run node scripts/build-mcpb.mjs first')


def add_tree(archive, source, prefix):
    for item in sorted(source.rglob('*')):
        if item.is_file():
            archive.write(item, str(Path(prefix) / item.relative_to(source)))


runtime = build / f'lightroom-mcp-unified-{version}.zip'
with ZipFile(runtime, 'w', ZIP_DEFLATED) as archive:
    add_tree(archive, stage, f'lightroom-mcp-unified-{version}')

plugin = build / f'LightroomMCPUnified-{version}.lrplugin.zip'
with ZipFile(plugin, 'w', ZIP_DEFLATED) as archive:
    add_tree(archive, root / 'plugin/LightroomMCPUnified.lrplugin', 'LightroomMCPUnified.lrplugin')
    for name in ['LICENSE', 'NOTICE.md']:
        archive.write(root / name, name)

assets = [runtime, plugin, build / 'lightroom-mcp-unified.mcpb']
checksums = ''.join(f'{hashlib.sha256(item.read_bytes()).hexdigest()}  {item.name}\n' for item in assets)
(build / 'SHA256SUMS').write_text(checksums)
print(checksums, end='')
