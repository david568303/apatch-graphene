#!/bin/bash
# Build the initrd a frankel bootloader hands the kernel:
#   vendor_kernel_boot ramdisk + vendor_boot ramdisk + init_boot ramdisk + bootconfig,
# plus a small overlay so first-stage init finds its partitions on QEMU's PCIe host.
#
# usage: mkinitrd.sh <work dir> <magisk|stock> <out initrd>
#   magisk: the init_boot ramdisk exactly as published (e.g. pixincreate-patched)
#   stock:  the same ramdisk with Magisk's backed-up original /init restored
set -euo pipefail
SET=$1; VARIANT=$2; OUT=$3
HERE=$(cd "$(dirname "$0")" && pwd)
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT

if [[ $VARIANT == stock ]]; then
  mkdir "$W/ib" && (cd "$W/ib" && cpio -idm --quiet < "$SET/init_boot.cpio")
  xz -dc "$W/ib/.backup/init.xz" > "$W/ib/init"; chmod 750 "$W/ib/init"
  rm -rf "$W/ib/.backup" "$W/ib/overlay.d"
  (cd "$W/ib" && find . | LC_ALL=C sort | cpio -o -H newc --quiet -R 0:0) > "$W/ib.cpio"
else
  cp "$SET/init_boot.cpio" "$W/ib.cpio"
fi

# Overlay: virtio modules (handy for extra disks) and the first-stage fstab with the
# UFS host path 3c400000.ufs replaced by QEMU's PCIe host 4010000000.pcie.
mkdir -p "$W/ov/lib/modules" "$W/ov/first_stage_ramdisk/system/etc"
for m in virtio_pci_legacy_dev virtio_pci_modern_dev virtio_pci virtio_blk; do
  cp "$SET/sdlkm/lib/modules/$m.ko" "$W/ov/lib/modules/"
done
{
  cat "$SET/vbx/lib/modules/modules.dep"
  echo "/lib/modules/virtio_pci_legacy_dev.ko:"
  echo "/lib/modules/virtio_pci_modern_dev.ko:"
  echo "/lib/modules/virtio_pci.ko: /lib/modules/virtio_pci_legacy_dev.ko /lib/modules/virtio_pci_modern_dev.ko"
  echo "/lib/modules/virtio_blk.ko:"
} > "$W/ov/lib/modules/modules.dep"
printf '%s\n' virtio_pci_legacy_dev.ko virtio_pci_modern_dev.ko virtio_pci.ko virtio_blk.ko \
  > "$W/ov/lib/modules/modules.load"
: > "$W/ov/lib/modules/modules.softdep"
cp "$SET/vbx/lib/modules/modules.alias" "$W/ov/lib/modules/"
sed -e 's/3c400000\.ufs/4010000000.pcie/g' -e '/c400000.dwc3/d' \
  "$SET/vbx/first_stage_ramdisk/system/etc/fstab.laguna" > "$W/ov/first_stage_ramdisk/system/etc/fstab.laguna"
(cd "$W/ov" && find . | LC_ALL=C sort | cpio -o -H newc --quiet -R 0:0) > "$W/ov.cpio"

cat "$SET/vkb.cpio" "$SET/vb.cpio" "$W/ib.cpio" "$W/ov.cpio" > "$W/initrd"
{
  grep -v '^androidboot.boot_devices' "$SET/u_vendor_boot/bootconfig.txt"
  cat <<'EOF'
androidboot.boot_devices=4010000000.pcie
androidboot.slot_suffix=_a
androidboot.force_normal_boot=1
androidboot.verifiedbootstate=orange
androidboot.vbmeta.device_state=unlocked
androidboot.hardware=frankel
androidboot.hardware.platform=laguna
androidboot.fstab_suffix=laguna
androidboot.serialno=QEMUFRANKEL0
androidboot.bootreason=reboot
EOF
} > "$W/bootconfig.txt"
python3 -I "$HERE/bootconfig.py" "$W/initrd" "$W/bootconfig.txt" "$OUT"
