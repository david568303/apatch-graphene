# frankel (Pixel 10) in QEMU

Boots a published frankel OTA (kernel, modules, ramdisks, system/vendor) on QEMU `virt` so a
rooting method can be tested on the exact GrapheneOS kernel without a phone. Built to
investigate [schnatterer/rooted-graphene#368](https://github.com/schnatterer/rooted-graphene/issues/368)
(pixincreate build of 2026110801 falls back to 2026110201 after three boots).

## What the VM reproduces

| Phone | VM |
| --- | --- |
| GrapheneOS kernel, MTE + `kasan.fault=panic`, vendor_boot cmdline/bootconfig | same Image, cmdline and bootconfig, `virt,mte=on`, Neoverse-N2 CPU |
| initrd = vendor_kernel_boot + vendor_boot + init_boot ramdisks | same three ramdisks, plus an overlay fstab with the PCIe host instead of `3c400000.ufs` |
| UFS LUN 0, 4 KiB sectors, `sdaN` | QEMU `ufs`/`ufs-lu`, GPT written with 4 KiB sectors |
| dynamic partitions in `super` (liblp) | real liblp `super` (`lpmake.py`) |
| f2fs `/metadata` = `sda10` (Magisk's preinit device), f2fs persist and `/data` | same |

Not reproduced: Trusty/KeyMint, GSA, modem, display, and the first boot from Virtual A/B
snapshots (snapuserd). To get past `post-fs-data` without KeyMint, the VM run unencrypts
`/data` in the vendor fstab and comments out the KeyMint/odsign waits in `init.rc`. Both edits
are made in place, and the vbmeta copy sets the hashtree-disabled flag. A
`magisk/sepolicy.rule` on the preinit partition makes the boot HAL permissive, because the
partition labels in `vendor_file_contexts` are keyed on `3c400000.ufs`.

## Use

Needs avbroot, lz4, cpio, debugfs, f2fs-tools, python3 and **QEMU >= 10**. QEMU 8.2 reads
`LDAPUR Wt, [Xn, #-24]` from `Xn + 488`: `ldapur-test.c` shows it under qemu-user. Android
17 uses that instruction for every SharedBuffer refcount, so on 8.2 random services
segfault and the boot looks broken on any kernel.

```bash
./prepare.sh frankel-2026110801-ca2df93-pixincreate-v31.0-3.zip work/bad
DATA_FS=f2fs ./patchvendor.py work/bad/vendor.img work/bad/vbmeta.img work/bad/vendor.vm.img work/bad/vbmeta.vm.img
./patchfile.py work/bad/system.img work/bad/system.vm.img \
  '/system/etc/init/keystore2.rc::    critical window=0' \
  '/system/etc/init/hw/init.rc::    exec - system system -- /system/bin/vdc keymaster earlyBootEnded' \
  '/system/etc/init/hw/init.rc::    wait_for_prop keystore.module_hash.sent true' \
  '/system/etc/init/hw/init.rc::    wait_for_prop odsign.key.done 1' \
  '/system/etc/init/hw/init.rc::    wait_for_prop odsign.verification.done 1'
./mkinitrd.sh work/bad magisk work/bad.initrd          # 'stock' restores Magisk's backed-up /init
PREINIT_DIR=preinit-root SYSTEM_IMG=$PWD/work/bad/system.vm.img \
  VENDOR_IMG=$PWD/work/bad/vendor.vm.img VBMETA_IMG=$PWD/work/bad/vbmeta.vm.img \
  ./mkdisk.sh work/bad work/bad-disk.img
QEMU=/opt/qemu-10/bin/qemu-system-aarch64 ./boot.sh work/bad work/bad.initrd work/bad-disk.img bad.log 2400
```

Without the `patchvendor.py`/`patchfile.py` steps the boot stops in `late-fs`, waiting for
KeyMint to unlock `/data`. That is still enough for anything up to `post-fs-data`.

To boot a new build on the state an old one left behind, as an update does:

```bash
qemu-img convert -O raw old-run.qcow2 old-after.img      # overlay written by boot.sh
cp --sparse=always work/bad-disk.img work/bad-upgrade.img
./carryover.py old-after.img work/bad-upgrade.img         # misc, persist, userdata, metadata
```

Magisk resolves its preinit directory on `/metadata` to `watchdog/magisk` once Android has
created `/metadata/watchdog`, and to `magisk` before that. So `preinit-root` carries the VM's
boot-HAL rule in both places. `preinit-fix.c` is a static PID 1 that mounts one f2fs
partition read-write (the kernel replays any fsync log), writes a file into it, and
unmounts cleanly. Use it to add the rule to a carried-over disk without userspace f2fs tools,
which refuse unclean images.

`poltest.c` is a static PID 1 that loads SELinux policies into a kernel and reports the
result. `ikconfig.py` extracts a kernel's embedded config.

## Findings for #368 (2026-11-25)

- frankel went from 2026110201 straight to 2026110801. Both are 6.18.38: the good build is
  `android17-5-g8299417b96c4`, the bad one `android17-6-gccd2e7642fa3`. It is a GKI LTS
  revision bump, not 6.6 → 6.18.
- Within the published pixincreate OTAs, only the kernel and its modules change. The
  init_boot ramdisk (magiskinit, the Magisk payload, the backed-up init) is identical except for
  `build.prop`. The SELinux policy, `init` and `libselinux` are byte-identical. The vbmeta
  layout is the same apart from fingerprints.
- Kernel source delta (GrapheneOS `kernel_common-6.18` tags 2026110200..2026110800): arm64
  entry code (`current` in `TPIDRRO_EL0`, per-task stack protector), mm reclaim/memcg, a
  large f2fs metadata-cache backport, drivers and binder. There are no changes in
  `security/selinux`, `mm/memfd.c`, `fs/exec.c`, `kernel/ptrace.c`, `fs/namespace.c` or
  `fs/proc`. The `TPIDRRO_EL0` change is what broke APatch: KernelPatch patches the kernel
  image. Magisk does not touch the kernel.
- In the VM the 2026110801 pixincreate build gets through every Magisk stage with no
  kernel warning: magiskinit first and second stage, preinit on f2fs `sda10`, the patched
  policy load (LD_PRELOAD), `magisk --post-fs-data`, `zygote-start`, and the zygote-restart
  hook. It runs until system_server dies for lack of phone HALs, at the same point
  (~215 s) and in the same way as 2026110201 in the same VM. Not covered: Zygisk (off on a
  fresh `/data`), the user's modules, and the first boot from VAB snapshots.
- The package passes `avbroot ota verify` against the 2026110201 OTA certificate and the
  published `avb_pkmd.bin`; OTA and AVB keys are the same as 2026110201. Its payload's
  snapshot settings match too: VABC lz4, the same COW version and compression factor,
  `disable_ublk`.
- Tooling bumps in that build don't change the output: avbroot 3.38/3.39 (CLI parser, boot
  v0-v2 `id`), afsr 2.1.0 (CLI parser, same e2fsprogs), my-avbroot-setup (Python lockfile).
- The kernel has no changes in `drivers/md`, io_uring or the block layer (virtio_blk aside),
  so the snapshot boot path is unchanged.
- In frameworks_base (2026110200..2026110800) the zygote JNI signatures pixincreate's Zygisk
  hooks are identical. The only exec-spawning change sets NO_NEW_PRIVS and the shared app GID
  for WebView/app-zygote replacements, and leaves the replay contract Zygisk checks
  (`fds_to_close == {-1,-1}`, flag bit 3) as it was.
- GrapheneOS reports of unrooted Pixel 10 bootloops in this period ("Cannot load Android
  system" after a battery drain, os-issue-tracker #9131/#9196) are attributed to upstream f2fs
  bugs. 2026110801 is the first frankel kernel with the large f2fs metadata-cache backport.
- `carryover.py` emulates the update's data side: boot the old build, flatten its overlay,
  copy misc/persist/userdata/metadata into the new build's disk, and boot that.
- Update emulation: 2026110201 booted on a fresh disk (Magisk post-fs-data, zygote), then
  2026110801 booted on its misc/persist/userdata/metadata. The new kernel replayed the old
  kernel's f2fs logs on `/metadata` and `/data` (including `magisk.db`) without errors. magiskd
  ran post-fs-data on the existing state, and boot reached zygote, which the VM's missing
  display HAL then restarts. That matches the fresh-disk runs of both builds.
