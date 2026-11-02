#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Fail unless a stock GrapheneOS Updater APK is the one this patch expects.

This is a build-time integrity gate (see updater-patch/README.md). It refuses to
let the build proceed if the APK the patch would be applied to is not the shape
the patch was written against, so a changed upstream Updater fails the build
instead of producing a broken patched app. It checks structure only; the signer
certificate is pinned separately by build.sh via apksigner.

Usage: check_updater_target.py <Updater.apk>

Exits non-zero with a message on any mismatch.
"""
import sys
import zipfile

PACKAGE = "app.seamlessupdate.client"
# Classes the patch recompiles and swaps in; they must exist in the stock dex.
REQUIRED_CLASSES = (
    "Lapp/seamlessupdate/client/Service;",
    "Lapp/seamlessupdate/client/Settings;",
)
# Resources the behavior + labels changes rely on.
REQUIRED_RES_STRINGS = ("channel_stable", "channel_beta", "channel_alpha")


def fail(msg):
    sys.exit("check_updater_target: " + msg)


def main(apk):
    try:
        with zipfile.ZipFile(apk) as z:
            names = set(z.namelist())
            if "AndroidManifest.xml" not in names:
                fail("no AndroidManifest.xml")
            if "resources.arsc" not in names:
                fail("no resources.arsc")
            dexes = sorted(n for n in names if n.startswith("classes") and n.endswith(".dex"))
            if not dexes:
                fail("no classes*.dex")

            manifest = z.read("AndroidManifest.xml")
            # Binary manifest stores strings as UTF-16LE; a byte search is enough
            # to confirm the package the SELinux domain and privapp allowlist key
            # on has not changed.
            if PACKAGE.encode("utf-16-le") not in manifest:
                fail("package %s not found in manifest" % PACKAGE)

            dex_blob = b"".join(z.read(d) for d in dexes)
            for cls in REQUIRED_CLASSES:
                if cls.encode("utf-8") not in dex_blob:
                    fail("required class missing from dex: " + cls)

            arsc = z.read("resources.arsc")
            for name in REQUIRED_RES_STRINGS:
                if name.encode("utf-8") not in arsc:
                    fail("required resource string missing: " + name)
    except zipfile.BadZipFile:
        fail("not a valid APK/zip: " + apk)
    except KeyError as e:
        fail("missing entry: " + str(e))

    print("check_updater_target: OK (%s, classes + resources present)" % PACKAGE)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        fail("usage: check_updater_target.py <Updater.apk>")
    main(sys.argv[1])
