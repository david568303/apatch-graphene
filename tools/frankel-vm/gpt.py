#!/usr/bin/env python3
"""Write a GPT with a given logical sector size (4096 for UFS) to an image file.

usage: gpt.py <image> <sector-size> name:start_lba:num_lba [...]
"""
import os
import struct
import sys
import uuid
import zlib

img, ss = sys.argv[1], int(sys.argv[2])
parts = [(n, int(a), int(b)) for n, a, b in (p.split(':') for p in sys.argv[3:])]
total = os.path.getsize(img) // ss
NENT, ESZ = 128, 128
ent_lbas = NENT * ESZ // ss
LINUX = uuid.UUID('0fc63daf-8483-4772-8e79-3d69d8477de4')

ents = b''
for name, start, n in parts:
    ents += struct.pack('<16s16sQQQ72s', LINUX.bytes_le, uuid.uuid4().bytes_le, start, start + n - 1, 0,
                        name.encode('utf-16-le').ljust(72, b'\0'))
ents = ents.ljust(NENT * ESZ, b'\0')
ecrc = zlib.crc32(ents)
disk_guid = uuid.uuid4().bytes_le
first, last = 2 + ent_lbas, total - 2 - ent_lbas

def header(cur, backup, ent_lba):
    h = struct.pack('<8sIIIIQQQQ16sQIII', b'EFI PART', 0x10000, 92, 0, 0, cur, backup, first, last,
                    disk_guid, ent_lba, NENT, ESZ, ecrc)
    h = h[:16] + struct.pack('<I', zlib.crc32(h)) + h[20:]
    return h.ljust(ss, b'\0')

mbr = bytearray(ss)
mbr[446:462] = struct.pack('<BBBBBBBBII', 0, 0, 2, 0, 0xEE, 0xff, 0xff, 0xff, 1, min(total - 1, 0xffffffff))
mbr[510:512] = b'\x55\xaa'
with open(img, 'r+b') as f:
    f.seek(0); f.write(bytes(mbr))
    f.seek(ss); f.write(header(1, total - 1, 2))
    f.seek(2 * ss); f.write(ents)
    f.seek((total - 1 - ent_lbas) * ss); f.write(ents)
    f.seek((total - 1) * ss); f.write(header(total - 1, 1, total - 1 - ent_lbas))
for i, (name, start, n) in enumerate(parts, 1):
    print(f'  {i:2d} {name:22s} lba {start:>8d} +{n}')
