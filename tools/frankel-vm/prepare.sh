#!/bin/bash
# Unpack one published frankel OTA into the layout the other scripts expect.
# usage: prepare.sh <ota.zip> <work dir>        env: AVBROOT=path/to/avbroot
set -euo pipefail
OTA=$(realpath "$1"); OUT=$2; AVBROOT=${AVBROOT:-avbroot}
mkdir -p "$OUT" && cd "$OUT"
"$AVBROOT" ota extract -i "$OTA" -d . \
  -p boot -p init_boot -p vendor_boot -p vendor_kernel_boot -p vbmeta \
  -p system -p system_ext -p product -p vendor -p vendor_dlkm -p system_dlkm
for p in boot init_boot vendor_boot vendor_kernel_boot; do
  mkdir -p "u_$p" && (cd "u_$p" && "$AVBROOT" boot unpack -i "../$p.img" >/dev/null)
done
lz4 -dc u_boot/kernel.img > Image
lz4 -dc u_init_boot/ramdisk.img.0 > init_boot.cpio
lz4 -dc u_vendor_boot/ramdisk.img.0 > vb.cpio
lz4 -dc u_vendor_kernel_boot/ramdisk.img.0 > vkb.cpio
# vendor ramdisks unpacked (modules.dep/alias, first-stage fstab) and system_dlkm (virtio modules)
mkdir -p vbx sdlkm
(cd vbx && cpio -idm --quiet < ../vb.cpio && cpio -idm --quiet < ../vkb.cpio)
debugfs -R "rdump / sdlkm" system_dlkm.img >/dev/null 2>&1
strings Image | grep -m1 'Linux version'
