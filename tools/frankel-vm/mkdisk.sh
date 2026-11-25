#!/bin/bash
# Build a disk shaped like frankel's UFS LUN 0: GPT with 4096-byte sectors (QEMU's
# ufs-lu uses 4 KiB blocks like the phone), slot-a images from the OTA, a liblp
# 'super' holding the dynamic partitions, f2fs persist/userdata, and f2fs metadata
# as partition 10 = sda10, which is what Magisk chooses as its preinit device here.
#
# usage: mkdisk.sh <work dir> <out.img>
#   env: SYSTEM_IMG, VENDOR_IMG, VBMETA_IMG  replacements (absolute paths)
#        PREINIT_DIR                         directory loaded into the metadata f2fs
set -euo pipefail
SET=$1; OUT=$2; SECTOR=4096
HERE=$(cd "$(dirname "$0")" && pwd)
vbmeta=vbmeta.img
if [[ -n ${VBMETA_IMG:-} ]]; then cp "$VBMETA_IMG" "$SET/vbmeta.vm.img"; vbmeta=vbmeta.vm.img; fi
python3 -I "$HERE/lpmake.py" "$SET/super.img" 8192 google_dynamic_partitions \
  system_a=${SYSTEM_IMG:-$SET/system.img} system_dlkm_a=$SET/system_dlkm.img \
  system_ext_a=$SET/system_ext.img product_a=$SET/product.img \
  vendor_a=${VENDOR_IMG:-$SET/vendor.img} vendor_dlkm_a=$SET/vendor_dlkm.img >/dev/null
parts=(boot_a:boot.img init_boot_a:init_boot.img vendor_boot_a:vendor_boot.img
       vendor_kernel_boot_a:vendor_kernel_boot.img vbmeta_a:$vbmeta
       super:super.img misc:@4 persist:@64 userdata:@4096 metadata:@64
       boot_b:@64 init_boot_b:@8 vendor_boot_b:@64 vendor_kernel_boot_b:@64 vbmeta_b:@1 devinfo:@1)
size_mb() { if [[ $1 == @* ]]; then echo "${1#@}"; else echo $(( ($(stat -c %s "$SET/$1") + 1048575) / 1048576 )); fi; }
total=2
for p in "${parts[@]}"; do total=$((total + $(size_mb "${p#*:}") + 1)); done
rm -f "$OUT"; truncate -s ${total}M "$OUT"
gptargs=(); startmb=1
for p in "${parts[@]}"; do
  name=${p%%:*}; src=${p#*:}; mb=$(size_mb "$src")
  gptargs+=("$name:$((startmb * 1048576 / SECTOR)):$((mb * 1048576 / SECTOR))")
  if [[ $src != @* ]]; then
    dd if="$SET/$src" of="$OUT" bs=1M seek=$startmb conv=notrunc,sparse status=none
  elif [[ $name == metadata || $name == persist || $name == userdata ]]; then
    f=$(mktemp -p "$SET" f2fs.XXXX); truncate -s ${mb}M "$f"; mkfs.f2fs -q -f -l "$name" "$f" >/dev/null
    if [[ $name == metadata && -n ${PREINIT_DIR:-} ]]; then sload.f2fs -f "$PREINIT_DIR" "$f" >/dev/null; fi
    dd if="$f" of="$OUT" bs=1M seek=$startmb conv=notrunc,sparse status=none; rm -f "$f"
  fi
  startmb=$((startmb + mb + 1))
done
rm -f "$SET/super.img"
python3 -I "$HERE/gpt.py" "$OUT" "$SECTOR" "${gptargs[@]}"
