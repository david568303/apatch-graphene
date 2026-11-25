#!/usr/bin/env python3
"""Append a Linux bootconfig block to an initrd, like the Pixel bootloader does.

usage: bootconfig.py <initrd-in> <bootconfig-text-file> <initrd-out>
"""
import struct
import sys

initrd = open(sys.argv[1], 'rb').read()
text = open(sys.argv[2], 'rb').read().strip() + b'\n'
data = text + b'\0'
while len(data) % 4:
    data += b'\0'
csum = sum(data) & 0xffffffff
out = initrd + data + struct.pack('<II', len(data), csum) + b'#BOOTCONFIG\n'
open(sys.argv[3], 'wb').write(out)
print(f'bootconfig: {len(text)} bytes, {text.count(b"=")} keys')
