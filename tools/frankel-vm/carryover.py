#!/usr/bin/env python3
"""Copy the data partitions of one frankel VM disk into another, to emulate an update:
the new build boots on the /data, /metadata (Magisk preinit), /persist and misc the old
build left behind. Both disks must come from mkdisk.sh (same GPT layout). Flatten a
boot.sh qcow2 overlay first: qemu-img convert -O raw run.qcow2 after.img

usage: carryover.py <from.img> <to.img> [names...]   (default: misc persist userdata metadata)
"""
import struct
import subprocess
import sys

SS = 4096
CHUNK = 1 << 20
src, dst = sys.argv[1], sys.argv[2]
names = sys.argv[3:] or ['misc', 'persist', 'userdata', 'metadata']

def table(path):
    with open(path, 'rb') as f:
        f.seek(2 * SS)
        e = f.read(128 * 128)
    parts = {}
    for i in range(128):
        ent = e[i * 128:(i + 1) * 128]
        first, last = struct.unpack('<QQ', ent[32:48])
        if first:
            parts[ent[56:128].decode('utf-16-le').rstrip('\0')] = (first, last - first + 1)
    return parts

ts, td = table(src), table(dst)
for n in names:
    assert ts[n] == td[n], f'{n}: layouts differ {ts[n]} vs {td[n]}'
    first, count = ts[n]
    off, length = first * SS, count * SS
    # zero the target range (keeps the image sparse), then copy only non-zero chunks
    subprocess.run(['fallocate', '--punch-hole', '--keep-size', '--offset', str(off),
                    '--length', str(length), dst], check=True)
    written = 0
    with open(src, 'rb') as fi, open(dst, 'r+b') as fo:
        for pos in range(off, off + length, CHUNK):
            fi.seek(pos)
            buf = fi.read(min(CHUNK, off + length - pos))
            if buf.count(0) != len(buf):
                fo.seek(pos)
                fo.write(buf)
                written += len(buf)
    print(f'copied {n}: {length >> 20} MiB partition, {written >> 20} MiB non-zero')
