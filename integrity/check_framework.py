#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Verify that a framework.jar carries the Play Integrity hook.

Passes on the patched jar, fails on the stock one, so buildIntegrityHook can
assert the surgery took and verifyAPatchPartitions can prove the packed jar in
the final OTA is the patched one, not the stock jar slipping through.

The check is a raw dex scan (no baksmali needed): the hook class must be present
in some dex, and the dex that defines AndroidKeyStoreSpi must reference it -- a
stock jar has neither. The type descriptors are interned in each referencing
dex's string pool, so a substring scan is sufficient and robust.

Usage: check_framework.py <framework.jar>
"""
import sys
import zipfile

HOOK = b'Lio/github/david568303/pi/Hooks;'
SPI = b'Landroid/security/keystore2/AndroidKeyStoreSpi;'
CHAIN = b'chain'


def main(jar):
    try:
        with zipfile.ZipFile(jar) as z:
            dexes = {n: z.read(n) for n in z.namelist()
                     if n.endswith('.dex')}
    except (OSError, zipfile.BadZipFile) as e:
        sys.exit(f'cannot read {jar}: {e}')

    if not dexes:
        sys.exit(f'no classes*.dex in {jar}')

    spi_dexes = [n for n, d in dexes.items() if SPI in d]
    if not spi_dexes:
        sys.exit('AndroidKeyStoreSpi not found in any dex of ' + jar)

    if not any(HOOK in d for d in dexes.values()):
        sys.exit(f'hook class not present: {jar} is the stock (unpatched) jar')

    wired = [n for n in spi_dexes if HOOK in dexes[n] and CHAIN in dexes[n]]
    if not wired:
        sys.exit('AndroidKeyStoreSpi dex does not reference Hooks.chain: '
                 'hook present but not wired into engineGetCertificateChain')

    print(f'framework.jar OK: hook present and wired into {wired[0]}')


if __name__ == '__main__':
    if len(sys.argv) != 2:
        sys.exit('usage: check_framework.py <framework.jar>')
    main(sys.argv[1])
