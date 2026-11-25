#!/usr/bin/env python3
"""Minimal liblp 'super' image writer (metadata v10.0), enough for first-stage init.

usage: lpmake.py <out> <size-MiB> <group> name=path [name=path ...]
Partitions are put in <group>_a with their slot suffix as given (e.g. system_a);
an empty <group>_b is created too, like a Virtual A/B Pixel on slot a.
"""
import hashlib
import os
import struct
import sys

SECTOR = 512
GEOMETRY_SIZE = 4096
RESERVED = 4096
METADATA_MAX = 65536
SLOTS = 3
FIRST_LOGICAL_SECTOR = 2048  # 1 MiB
ALIGN = 1024 * 1024

out, size_mb, group = sys.argv[1], int(sys.argv[2]), sys.argv[3]
parts = [a.split('=', 1) for a in sys.argv[4:]]
super_size = size_mb * 1024 * 1024

def name36(s):
    b = s.encode()
    assert len(b) < 36
    return b + b'\0' * (36 - len(b))

groups = [('default', 0, 0), (group + '_a', 0, 0), (group + '_b', 0, 0)]
pentries, extents = [], []
cursor = FIRST_LOGICAL_SECTOR * SECTOR
layout = []
for name, path in parts:
    size = os.path.getsize(path)
    assert size % SECTOR == 0, path
    cursor = (cursor + ALIGN - 1) // ALIGN * ALIGN
    extents.append(struct.pack('<QIQI', size // SECTOR, 0, cursor // SECTOR, 0))
    pentries.append(struct.pack('<36sIIII', name36(name), 1, len(extents) - 1, 1, 1))
    layout.append((name, path, cursor, size))
    cursor += size
assert cursor <= super_size, 'super too small'

gtab = b''.join(struct.pack('<36sIQ', name36(n), f, m) for n, f, m in groups)
ptab = b''.join(pentries)
etab = b''.join(extents)
btab = struct.pack('<QIIQ36sI', FIRST_LOGICAL_SECTOR, ALIGN, 0, super_size, name36('super'), 0)
tables = ptab + etab + gtab + btab

def desc(offset, n, sz):
    return struct.pack('<III', offset, n, sz)

hdr_wo = struct.pack('<IHHI32sI32s', 0x414C5030, 10, 0, 128, b'\0' * 32, len(tables),
                     hashlib.sha256(tables).digest())
hdr_wo += desc(0, len(pentries), 52) + desc(len(ptab), len(extents), 24) + \
          desc(len(ptab) + len(etab), len(groups), 48) + desc(len(ptab) + len(etab) + len(gtab), 1, 64)
assert len(hdr_wo) == 128
hcsum = hashlib.sha256(hdr_wo).digest()
header = hdr_wo[:12] + hcsum + hdr_wo[44:]
metadata = header + tables
assert len(metadata) <= METADATA_MAX

geo_wo = struct.pack('<II32sIII', 0x616c4467, 52, b'\0' * 32, METADATA_MAX, SLOTS, 4096)
geo = geo_wo[:8] + hashlib.sha256(geo_wo).digest() + geo_wo[40:]
geo = geo + b'\0' * (GEOMETRY_SIZE - len(geo))

with open(out, 'wb') as f:
    f.truncate(super_size)
    f.seek(RESERVED); f.write(geo); f.write(geo)
    primary = RESERVED + 2 * GEOMETRY_SIZE
    backup = primary + METADATA_MAX * SLOTS
    for base in (primary, backup):
        for slot in range(SLOTS):
            f.seek(base + slot * METADATA_MAX); f.write(metadata)
    assert backup + METADATA_MAX * SLOTS <= FIRST_LOGICAL_SECTOR * SECTOR
    for name, path, off, size in layout:
        with open(path, 'rb') as src:
            f.seek(off)
            while True:
                chunk = src.read(16 << 20)
                if not chunk:
                    break
                if chunk.count(0) == len(chunk):
                    f.seek(len(chunk), 1)
                else:
                    f.write(chunk)
        print(f'  {name:16s} {size >> 20:5d} MiB @ {off >> 20} MiB')
