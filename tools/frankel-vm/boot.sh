#!/bin/bash
# Boot a prepared frankel build in QEMU: virt + MTE (the kernel runs KASAN HW tags with
# kasan.fault=panic, like the phone), a Neoverse-N2 CPU (Armv9.0: MTE, BTI, PAC,
# LRCPC2), and the disk behind an emulated UFS controller so partitions are sdaN.
# Writes go to a throwaway qcow2 overlay next to the log.
#
# QEMU 8.2 decodes LDAPUR's signed offset as unsigned (see ldapur-test.c) and Android 17
# userspace uses LDAPUR [x, #-24] for refcounts everywhere: use QEMU >= 10.
#
# usage: boot.sh <work dir> <initrd> <disk.img> <log> [timeout s] [extra kernel cmdline]
#   env: QEMU=path/to/qemu-system-aarch64
set -uo pipefail
SET=$1; INITRD=$2; DISK=$3; LOG=$4; T=${5:-900}; XC=${6:-}
QEMU=${QEMU:-qemu-system-aarch64}
OVL=${LOG%.log}.qcow2
rm -f "$OVL"; qemu-img create -q -f qcow2 -b "$(realpath "$DISK")" -F raw "$OVL"
VCMD=$(sed -n 's/^cmdline = "\(.*\)"$/\1/p' "$SET/u_vendor_boot/boot.toml" | tail -1)
timeout "$T" "$QEMU" \
  -machine virt,gic-version=3,mte=on -cpu neoverse-n2,pauth-impdef=on -smp 4 -m 4096 \
  -nographic -no-reboot \
  -kernel "$SET/Image" -initrd "$INITRD" \
  -append "$VCMD console=ttyAMA0 earlycon loglevel=7 printk.devkmsg=on print-fatal-signals=1 $XC" \
  -drive if=none,id=d0,file="$OVL",format=qcow2,cache=unsafe \
  -device ufs,serial=frankel0,id=ufs0 -device ufs-lu,drive=d0,lun=0 \
  > "$LOG" 2>&1
echo "exit=$? log=$LOG lines=$(wc -l < "$LOG")"
