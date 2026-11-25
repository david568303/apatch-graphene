#!/usr/bin/env python3
"""Make a frankel vendor.img mountable in QEMU without Trusty: rewrite
/etc/fstab.laguna in place (same byte length, so shared_blocks ext4 stays intact)
to point at the QEMU PCIe host and to mount an unencrypted /data (DATA_FS=ext4|f2fs).
Also writes a vbmeta copy with the HASHTREE_DISABLED flag (allowed on an unlocked
device), since the edited vendor no longer matches its dm-verity tree.

usage: patchvendor.py <vendor.img> <vbmeta.img> <out-vendor.img> <out-vbmeta.img>
"""
import os
import re
import shutil
import struct
import subprocess
import sys

vendor, vbmeta, out_vendor, out_vbmeta = sys.argv[1:5]

stat = subprocess.run(['debugfs', '-R', 'stat /etc/fstab.laguna', vendor],
                      capture_output=True, text=True).stdout
size = int(re.search(r'Size: (\d+)', stat).group(1))
ranges = re.findall(r'\((\d+)(?:-(\d+))?\):(\d+)(?:-(\d+))?', stat.split('EXTENTS:')[1])
blocks = []
for lo, hi, plo, phi in ranges:
    n = int(hi or lo) - int(lo) + 1
    blocks += [int(plo) + i for i in range(n)]
old = subprocess.run(['debugfs', '-R', 'cat /etc/fstab.laguna', vendor],
                     capture_output=True).stdout
assert len(old) == size, (len(old), size)

lines = []
for line in old.decode().splitlines():
    if line.startswith('#') or not line.strip():
        continue
    line = re.sub(r'  +', ' ', line.replace('3c400000.ufs', '4010000000.pcie'))
    if ' /data ' in line:
        if (' f2fs ' in line) != (os.environ.get('DATA_FS', 'ext4') == 'f2fs'):
            continue
        fs = os.environ.get('DATA_FS', 'ext4')
        line = ('/dev/block/platform/4010000000.pcie/by-name/userdata /data ' + fs + ' '
                'noatime,nosuid,nodev latemount,wait,formattable')
    lines.append(line)
new = ('\n'.join(lines) + '\n').encode()
assert len(new) <= size, 'new fstab does not fit'
new += b'#' * (size - len(new) - 1) + b'\n'
print(new.decode())

shutil.copyfile(vendor, out_vendor)
with open(out_vendor, 'r+b') as f:
    for i, b in enumerate(blocks):
        chunk = new[i * 4096:(i + 1) * 4096]
        if not chunk:
            break
        f.seek(b * 4096)
        f.write(chunk)

shutil.copyfile(vbmeta, out_vbmeta)
with open(out_vbmeta, 'r+b') as f:
    assert f.read(4) == b'AVB0'
    f.seek(120)
    flags = struct.unpack('>I', f.read(4))[0]
    f.seek(120)
    f.write(struct.pack('>I', flags | 1))
print(f'vendor fstab rewritten ({size} bytes, blocks {blocks}); vbmeta flags {flags} -> {flags | 1}')
