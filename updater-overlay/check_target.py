#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Fail unless an Updater APK can be overridden by updater-overlay.

An overlay silently does nothing if the target has no string/url resource, and
is refused if the target declares <overlayable>. Check both on the stock
Updater of the OTA being patched instead of assuming the layout never changes.

Usage: check_target.py <Updater.apk>
"""
import struct
import sys
import zipfile

RES_STRING_POOL = 0x0001
RES_TABLE_PACKAGE = 0x0200
RES_TABLE_OVERLAYABLE = 0x0204
UTF8_FLAG = 0x100
STOCK_URL = 'https://releases.grapheneos.org/'


def u8_len(d, o):
    n = d[o]
    return (((n & 0x7F) << 8) | d[o + 1], 2) if n & 0x80 else (n, 1)


def read_pool(d, off):
    _, hdr, _, count, _, flags, strings_start, _ = struct.unpack_from('<HHIIIIII', d, off)
    out = []
    for i in range(count):
        o = off + strings_start + struct.unpack_from('<I', d, off + hdr + 4 * i)[0]
        if flags & UTF8_FLAG:
            _, n = u8_len(d, o)
            length, m = u8_len(d, o + n)
            out.append(d[o + n + m:o + n + m + length].decode('utf-8'))
        else:
            length = struct.unpack_from('<H', d, o)[0]
            out.append(d[o + 2:o + 2 + 2 * length].decode('utf-16-le'))
    return out


def main(apk):
    with zipfile.ZipFile(apk) as z:
        d = z.read('resources.arsc')

    table_hdr = struct.unpack_from('<H', d, 2)[0]
    values = keys = None
    off = table_hdr
    while off < len(d):
        kind, hdr, size = struct.unpack_from('<HHI', d, off)
        if kind == RES_STRING_POOL:
            values = read_pool(d, off)
        elif kind == RES_TABLE_PACKAGE:
            key_off = struct.unpack_from('<I', d, off + 8 + 4 + 256 + 4 + 4)[0]
            keys = read_pool(d, off + key_off)
            inner = off + hdr
            while inner < off + size:
                ikind, _, isize = struct.unpack_from('<HHI', d, inner)
                if ikind == RES_TABLE_OVERLAYABLE:
                    sys.exit('Updater declares <overlayable>; the overlay would be refused')
                inner += isize
        off += size

    if not keys or 'url' not in keys:
        sys.exit('Updater has no "url" resource to override')
    if STOCK_URL not in (values or []):
        sys.exit(f'Updater url is not the stock {STOCK_URL}')
    print('Updater target OK: string/url present, no <overlayable>')


if __name__ == '__main__':
    main(sys.argv[1])
