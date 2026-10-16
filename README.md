rooted-graphene
===

GrapheneOS over the air updates (OTAs) patched with Magisk allowing for AVB and locked bootloader *and* root access.  
Can be upgraded over the air using [Custota](https://github.com/chenxiaolong/Custota) and its own OTA server.  
Allows for switching between magisk and rootless via OTA upgrades.

> ⚠️ OS and root work in general. However, with upstream magisk zygisk does not (and [likely never will](https://github.com/topjohnwu/Magisk/pull/7606))
> work, leading to magisk being easily discovered by other apps and lots of banking apps not working.  
> As an alternative we offer [pixincreate's magisk](https://github.com/pixincreate/Magisk) that contains patches to make zygisk work. Before using it please note that this way you add another party to your supply chain that basically gains root acces to your device.  
 See [below](#using-other-rooting-mechanisms) for more details and the reason why kernelsu cannot be integrated easily with this project.

## Install

> ⚠️ Flashing carries risk. Keep **OEM unlocking enabled**, never switch slots if a flash fails, and flash a rooted OTA whose version **exactly matches** the stock GrapheneOS already on the device. Read the full [caveats](#installation) first — you use this at your own risk.

1. **Install stock GrapheneOS**, bootloader unlocked, using **`fastboot` ≥ 35.0.1**. Write down the exact version. ([how](#install-grapheneos))
2. **Download the rooted OTA for your device and that exact version** from [Releases](https://github.com/david568303/rooted-graphene/releases).
3. **Flash it** the usual way: [Patch GrapheneOS with OTAs from this image](#patch-grapheneos-with-otas-from-this-image).
   Every release asset is the plain signed OTA zip (no installer, no wrapper archive). On mustang read the [install notes](#notes-on-installing-the-apatch-ota-on-mustang) first: a first install there needs all dynamic partitions flashed from `fastbootd`. Flavors:
   - **APatch** — kernel-level root. Built per device on demand (**Release single device**, published as a `<version>-apatch` pre-release); hardware-validated on Pixel 10 Pro XL (mustang) only. It injects nothing into the `system` image (no Custota, no OEMUnlockOnBoot): update it by sideloading, see [Updating with a locked bootloader](#updating-with-a-locked-bootloader). After the first boot install the APatch manager APK from the matching [APatch release](https://github.com/bmax121/APatch/releases). **Keep `OEM unlocking` enabled** yourself — nothing re-enables it on boot.
   - **Magisk (pixincreate)** — seamless [Custota](https://github.com/chenxiaolong/Custota) auto-updates.
4. **(Optional) re-lock** the bootloader — only after confirming the device boots cleanly.

If a device won't boot, capturing the kernel log of the failed boot (`adb shell su -c 'cat /sys/fs/pstore/console-ramoops-0'` after booting any working image) is the single most useful thing to attach to an issue.

## Supported devices

See [rooted-graphene/ota | .github/workflows/release-multiple.yaml](https://github.com/rooted-graphene/ota/blob/main/.github/workflows/release-multiple.yaml).

I plan to support as many devices as the GitHub Action limit allows for as long as this project is useful to me.

If you would like to see more devices, add them via PR to the file mentioned above.  
Alternatively, it's easy to [set up your own builds](#setting-up-your-own-ota-builds), which also makes you the owner of the signing keys.

If this project is useful to you, please consider **[donating to GrapheneOS](https://grapheneos.org/donate)**.  
Please note that rooted-graphene is not an official GrapheneOS project.  
As they do most of the heavy lifting, I think they deserve every support they can get.

## Initial installation of OS

### Hints 
* Make sure the versions of the unpatched version initially installed and the one taken from this repo match.
* You might want to start with the version before the latest to try if OTA is working before initializing your device.
* Don't mix up **factory image** and OTA
* The following steps are basically the ones described at [avbroot](https://github.com/chenxiaolong/avbroot#initial-setup)
  using the `avb_pkmd.bin` from [this repo](https://github.com/rooted-graphene/ota/).

### Installation

⚠️ Please be aware that there is always some risk involved when flashing your device.  
Especially since the first `Device is corrupt. It can't be trusted` messages started appearing in [2025032500](https://github.com/schnatterer/rooted-graphene/issues/89).  
In relation to this error,
we heard [multiple](https://github.com/schnatterer/rooted-graphene/issues/96#issuecomment-3123443894) [reports](https://github.com/schnatterer/rooted-graphene/issues/96#issuecomment-3358048965) about hard bricks.  
The steps listed below should work around this issue, though.

Still, if flashing fails, [**don't switch the slot**](https://github.com/schnatterer/rooted-graphene/issues/96#issuecomment-3128121844).  
Read through the comments on [this issue](https://github.com/schnatterer/rooted-graphene/issues/96) or reach out for help.  
In case your device should refuse to boot, [this project](https://github.com/JoshuaDoes/tensor-usbdl/) might be helpful. 

Be careful!
I only provide this software.
You are using it at your own risk.

#### Install GrapheneOS

##### Web Installer

Using the web installer is easier, but will always install the latest version. 
So it's not possible to verify if OTA upgrades work right away.

Use the [web installer](https://grapheneos.org/install/web) to install GrapheneOS:
* Write down the installed version, e.g. `Downloaded caiman-install-2024123000.zip release`.
* Stop at `Locking the bootloader` and close the browser. 
  We'll lock the bootloader later!

##### Manual install

Alternative method to Web installer.

Download [**factory image**](https://grapheneos.org/releases) and follow the [official instructions](https://grapheneos.org/install/cli)  to install GrapheneOS.

**When downloading the "Install zip", change the last digit in the URL from `0` to `1`!**

This way you get the [security-preview version](#173-sept-27-2025) right away and won't have to switch after installation.

e.g. from `https://releases.grapheneos.org/tegu-install-2025122500.zip`  
to `https://releases.grapheneos.org/tegu-install-2025122501.zip`

TLDR:

* Enable OEM unlocking
* Obtain latest `fastboot` (version >= 35.0.1, as earlier ones have issues with flashing dynamic partitions. GrapheneOS's [flash-all.sh](https://github.com/GrapheneOS/device_common/blob/1f5ba2671e4b04e3bd8899b3df2c5e30a894b35c/generate-factory-images-common.sh#L98) also enforces this)
* Unlock Bootloader:
  Enable usb debugging and execute `adb reboot bootloader`, or
  > The easiest approach is to reboot the device and begin holding the volume down button until it boots up into the bootloader interface.
   ```shell
   fastboot flashing unlock
   ```
* flash factory image

  ```shell
  bsdtar xvf DEVICE_NAME-factory-VERSION.zip # tar on windows and mac
  ./flash-all.sh # or .bat on windows
  ````
* Stop after that and reboot (leave bootloader unlocked)

#### Patch GrapheneOS with OTAs from this image

Once GrapheneOS is installed

* Download the [OTA from releases](https://github.com/rooted-graphene/ota/releases) with **the same version** (except `00` at the end is `01`, see [security-preview](#173-sept-27-2025)) that you just installed. 
* Obtain latest `fastboot`
* Install [avbroot](https://github.com/chenxiaolong/avbroot)
* Extract the partition images from the patched OTA that are different from the original.
    ```bash
    avbroot ota extract \
        --input /path/to/ota.zip.patched \
        --directory extracted \
        --fastboot
    ```
* Set this environment variable to match the extracted folder:

  For Linux/macOS:
  ```bash
  export ANDROID_PRODUCT_OUT=extracted
  ```

  For Windows (powershell):
  ```powershell
  $env:ANDROID_PRODUCT_OUT = "extracted"
  ```
  or (bat):
  ```bat
  set ANDROID_PRODUCT_OUT=extracted
  ```

* Flash the partitions using the command:
  ```bash
  fastboot flashall --skip-reboot
  ```
* Set up the custom AVB public key in the bootloader.
  (If you built your own OTA, use your `avb_pkmd.bin`.)
    ```bash
    fastboot reboot-bootloader
    fastboot erase avb_custom_key
    curl -s https://raw.githubusercontent.com/rooted-graphene/ota/refs/heads/main/avb_pkmd.bin > avb_pkmd.bin
    fastboot flash avb_custom_key avb_pkmd.bin
    ```
* Sideload the OTA  
  (to avoid `Device is corrupt. It can't be trusted` error)
   1. Run `fastboot reboot recovery` to get into recovery mode
   2. You should see an android icon lying down with the text "No command".  
      Hold the power button and press the volume up button a single time to get into the recovery GUI
   3. Use volume buttons to navigate to "Apply update from ADB" and select it with the power button
   4. Like the recovery prompt says, use  
      `adb sideload <path to ota zip>`  
       to sideload the OTA
   5. After sideloading, select reboot to bootloader
* If you installed using the web installer (or installed manually without security-preview) start the device and switch to the security-preview version during the startup wizard.  
  Then return to the bootloader (e.g. by using the volume button).  
  See [anouncement](#173-sept-27-2025) and [#202](https://github.com/schnatterer/rooted-graphene/issues/202#issuecomment-3620623595) for details.  
* Lock the bootloader using the following command.
  This will trigger a data wipe again.
    ```bash
    fastboot flashing lock
    ```
* Confirm by pressing volume down and then power. Then reboot.
* Remember: **Do not uncheck `OEM unlocking`!** (to avoid [hard-bricking](https://github.com/chenxiaolong/avbroot/blob/v3.12.0/README.md#warnings-and-caveats))  
  That is, in Graphene's startup wizard, leave this box unticked 👇️  
  <img src="https://github.com/schnatterer/rooted-graphene/assets/1824962/6ef90b46-2070-4d08-80d4-5f4a0e749cbe" width="216" height="480" alt="Screenshot of GrapheneOS recommending to lock">  
  Note: The OTA contains [OEMUnlockOnBoot](https://github.com/chenxiaolong/OEMUnlockOnBoot), so OEM locking should be impossible.  
  Still, better safe than sorry, keep it unlocked.

#### Updating with a locked bootloader

A device that already runs a build from this repo trusts this repo's OTA signing key, so a newer OTA installs from recovery
with the bootloader **staying locked** — no unlock, no data wipe, same AVB key:

1. Download the plain OTA zip for your device from [Releases](https://github.com/david568303/rooted-graphene/releases).
   Its version must be newer than what is installed (Android refuses downgrades) and its codename must match the device.
2. `adb reboot recovery`. At the "No command" screen hold power and press volume up once.
3. Pick **Apply update from ADB** and run `adb sideload <ota>.zip` from the computer.
4. Reboot from the recovery menu. Root and app data are kept.

If the sideload fails (on mustang `kPostInstallMountError` has been seen), the OTA cannot be applied while locked. Then
reinstall with the full procedure above: `fastboot flashing unlock` (wipes the device), install stock GrapheneOS of the
same version as the OTA, flash the OTA as described, register `avb_pkmd.bin`, confirm the device boots, and only then
`fastboot flashing lock` (wipes again).

#### Set up OTA updates

* [Disable System Updater app](https://github.com/chenxiaolong/avbroot#ota-updates) (or block its network access) from Settings -> Apps -> See all apps -> (three-dot menu) -> Show system -> (find "System Updater" app).
* Open Custota app and set the OTA server URL to point to this OTA server: https://rooted-graphene.github.io/ota/pixincreate

Alternatively you could do updates manually via `adb sideload`:
* reboot the device and begin holding the volume down button until it boots up into the bootloader interface
* using volume buttons, toggle to recovery. Confirm by pressing power button
* If the screen is stuck at a `No command` message, press the volume up button once while holding down the power button.
* using volume buttons, toggle to `Apply update from ADB`. Confirm by pressing power button
* `adb sideload xyz.zip`
* See also [here](https://github.com/chenxiaolong/avbroot#updates).

## Switching between root and rootless

To remove root, you can change to the "rootless" flavor.

To do so, set the following URL in custota: https://rooted-graphene.github.io/ota/rootless/
And then upgrade.  
(if custota should tell you that you're on the latest version, you can force an upgrade by long pressing `Version` and 
then selecting `Allow reinstall`).

If you want to gain root again, just switch back to this URL in custota: https://rooted-graphene.github.io/ota/pixincreate/
And then upgrade.

## Magisk preinit strings

See [release-multiple.yaml](https://github.com/rooted-graphene/ota/blob/main/.github/workflows/release-multiple.yaml) for examples.

How to extract:

* Get boot.img either from factory image or from OTA via
  ```shell
     avbroot ota extract \
     --input /path/to/ota.zip \
     --directory . \
     --boot-only
  ```
* Install magisk, patch boot.img, look for this string in the output:  
  `Pre-init storage partition device ID: <name>`
* Alternatively, extract from the patched boot.img: 
  ```shell
  avbroot boot magisk-info \
  --image magisk_patched-*.img
  ```
* See also: https://github.com/chenxiaolong/avbroot/blob/master/README.md#magisk-preinit-device

## Setting up your own OTA builds

* Create your own keys `bash -c 'source rooted-ota.sh && generateKeys'` and store them in a dry and safe place.
* Fork the [ota repo](https://github.com/rooted-graphene/ota) and add the following Repository secrets (`https://github.com/$YOU/$YOUR_REPO/settings/secrets/actions`)
  * CERT_OTA_BASE64 (`base64 -w0 < ota.crt`)
  * KEY_AVB_BASE64 (`base64 -w0 < avb.key`)
  * KEY_OTA_BASE64 (`base64 -w0 < ota.key`)
  * PASSPHRASE_AVB (The passphrase for `avb.key`)
  * PASSPHRASE_OTA (The passphrase for `ota.key`)
* Uncomment or add your device(s) in `.github/workflows/release-multiple.yaml`
  See [Magisk preinit string](#magisk-preinit-strings).

This sets up a cron job that builds the latest version of GrapheneOS, nightly.

This way, you won't have too many maintenance efforts but own your own signing key!  
You can also add a 3rd-party-magisk package if you're willing to trust the authors
(see [Using other rooting mechanisms](#using-other-rooting-mechanisms)).

Alternatively, search the forks if someone maintains the device of your choice.    
Be aware that you would also have to trust them in addition to [me](https://github.com/schnatterer), [chenxiaolong](https://github.com/chenxiaolong) (the author of avbroot and Custota),
the authors of magisk, the authors of GrapheneOS, and the authors of the android open source project.

## Script

You can use the `rooted-ota.sh` script in this repo to create your own OTAs and run your own OTA server.

### Only create patched OTAs

```shell
# Generate keys
bash -c 'source rooted-ota.sh && generateKeys'

# Enter passphrases interactively
DEVICE_ID=oriole MAGISK_PREINIT_DEVICE='metadata' bash -c '. rooted-ota.sh && createRootedOta'  
 
# Enter passphrases via env (e.g. on CI)
  export PASSPHRASE_AVB=1
  export PASSPHRASE_OTA=1 
DEVICE_ID=oriole MAGISK_PREINIT_DEVICE='metadata' bash -c '. rooted-ota.sh && createRootedOta' 
```

For IDs see [grapheneos.org/releases](https://grapheneos.org/releases). For Magisk preinit see,e.g. [here](#magisk-preinit-strings).

### Upload patched OTAs as GH release and provide OTA server via GH pages

See GitHub actions for automating this:
* [release single device](.github/workflows/release-single.yaml)
* [release multiple devices](https://github.com/rooted-graphene/ota/blob/main/.github/workflows/release-multiple.yaml) regularly (using cron)

```shell
GITHUB_TOKEN=gh... \
GITHUB_REPO=schnatterer/rooted-graphene \
DEVICE_ID=oriole \
MAGISK_PREINIT_DEVICE=metadata \
bash -c '. rooted-ota.sh && createAndReleaseRootedOta'
```

### Using other rooting mechanisms

As [magisk does not seem a perfect match for GrapheneOS](https://github.com/topjohnwu/Magisk/pull/7606), you might be looking for alternatives.

I had a first go at [patching kernelsu](https://github.com/schnatterer/rooted-graphene/commit/201b6dc939ab3a202694fa892de6db2840e5c3d6) which booted but did not provide root.
Patching kernelsu is much more complex that patching magisk.
It might even be impossible to run GrapheneOS with it, without building GrapheneOS from scratch.
Also, some parts of kernelsu seem to be closed source, which feels suspicious and inappropriate for a tool with so much influence on your device.

Another alternative might be to use a version of magisk (like [the one maintained by pixincreate](https://github.com/pixincreate/Magisk)) that contains patches to make zygisk work.  
This still has some limitations, like [certain modules checking for magisk's signature won't work](https://github.com/schnatterer/rooted-graphene/commit/da0cd817c2665798df46df1aeb7caef9d98b79d0#r141746606).

This variant can be built as an additional `pixincreate` flavor, next to the `rootless` one.  
It is disabled by default, so it is never silently forced on existing users. Enable it by setting `SKIP_PIXINCREATE=false`
(or the `skip-pixincreate` input in `release-single.yaml`). It requires `MAGISK_PREINIT_DEVICE` to be set and uses `PIXINCREATE_VERSION`.
`PIXINCREATE_VERSION=latest` resolves the newest stable GitHub release once per build. The release asset and its GitHub-provided SHA-256 digest
are both verified before patching. `PIXINCREATE_APK_NAME` can override the release asset name when a release uses a nonstandard name.

The resulting OTAs are published as a separate flavor, so in Custota you would point to the `pixincreate` path of your OTA server, e.g.
`https://rooted-graphene.github.io/ota/pixincreate`. As with the other flavors, you can switch between them via OTA updates.

> ⚠️ By using this flavor you also have to trust the authors of that fork, in addition to everyone listed above.
Another option [might be](https://github.com/schnatterer/rooted-graphene/pull/73#issuecomment-2666870886) Kitsune magisk.

#### APatch flavor

The script can also build a separate `apatch` flavor by setting `SKIP_APATCH=false` (or disabling `skip-apatch` in the
single-device workflow). `APATCH_VERSION=latest` resolves the latest stable [APatch](https://github.com/bmax121/APatch)
release. KernelPatch is independently pinned by `KERNELPATCH_VERSION` because APatch 11224's older pinned KernelPatch
0.13.3 does not boot on `mustang`. KernelPatch 0.13.9 boots on `mustang` both nonpersistently (`fastboot boot`) and as
a persistent install, once the full OTA is flashed as described under
[Notes on installing the APatch OTA on mustang](#notes-on-installing-the-apatch-ota-on-mustang); 0.13.3 does not boot at all. Set
`KERNELPATCH_VERSION=apatch` to use the version pinned by APatch itself, or `latest` to resolve the latest stable
[KernelPatch](https://github.com/bmax121/KernelPatch) release. The matching `kpimg-android` and `kptools-linux` artifacts
are downloaded from the official KernelPatch release, and every artifact is checked against GitHub's published SHA-256
digest.

The original GrapheneOS `boot.img` is extracted from the OTA, patched with KernelPatch, and supplied to avbroot as a
prepatched image. The build fails if `CONFIG_KALLSYMS=y` is missing or if avbroot rejects the prepatched image as
incompatible. It also fails when KernelPatch selects the ABI-ambiguous `memblock_alloc_try_nid` physical-allocation
fallback. The unresolved arm64 relocation diagnostic is retained as a warning: both KernelPatch versions used its
relative-base kallsyms fallback on `mustang`, but 0.13.9 booted successfully while 0.13.3 did not. Before upload, the final
signed OTA is re-extracted and KernelPatch must report `patched=true` for its boot kernel. Current APatch releases use
signature authorization for the official manager, so the automated build does not create, store, or expose a reusable
SuperKey.

APatch OTAs are built on demand, one device at a time, with the **Release single device** workflow (`skip-apatch` off,
`kernelpatch-commit` set to the pinned commit below). Publishing needs `allow-apatch-release`; use `skip-release` to
build without publishing. Nothing builds APatch automatically and no APatch OTA is ever added to a Custota feed
(`skip-ota-server-upload`).

Persistent APatch installs now boot on `mustang` with the fork's KernelPatch 0.13.9 (the `fix/arm64-mte-image-size` branch
below); 0.13.3 still does not boot at all. The earlier "persistent bootloop" was **not** a KernelPatch fault — it was an
install-procedure problem flashing the full OTA, resolved by writing the dynamic partitions through `fastbootd`
(see [Notes on installing the APatch OTA on mustang](#notes-on-installing-the-apatch-ota-on-mustang)).

For isolated testing, `KERNELPATCH_COMMIT=280d32d967feb7ddc0fd1848aa1d1388807945d5` builds both `kpimg` and `kptools`
from the [`fix/arm64-mte-image-size`](https://github.com/david568303/KernelPatch/tree/fix/arm64-mte-image-size) branch of the
KernelPatch fork: upstream `main` (`ef52c62`) plus two boot fixes described below.
The compiler archive, source commit, and APatch manager are all pinned or digest-verified.

KernelPatch copies its start image to just past the kernel's declared arm64 `image_size`, which the boot protocol does
not reserve, so a bootloader may have put the ramdisk or DTB there. In QEMU with the mustang kernel and the initramfs
placed directly after `image_size`, unfixed KernelPatch corrupted the initramfs and panicked, while the fix (which grows
`image_size` over that region) booted. Whether the Pixel bootloader places data there is not yet confirmed on hardware.

The hardware test of that fix still bootlooped with `Early Kernel PANIC`. The cause is GrapheneOS's kernel memory tagging
(MTE with `kasan.fault=panic`): KernelPatch's cred offset scan read past the end of a 176-byte slab object, which MTE
turns into a fatal fault. QEMU with `mte=on` reproduced the panic; with the second fix the kernel boots there, including
Android's first- and second-stage init from the real GrapheneOS ramdisks, with no KASAN reports.

With both fixes the patched kernel boots on mustang. The APatch manager may still be refused root: official APatch
releases are signed v1+v2+v3 and how this KernelPatch authorizes a multi-scheme manager signature is being investigated.

To test it without the full avbroot flow, run the **APatch boot image test** workflow. It produces a workflow artifact
(nothing is released) with the patched `boot.img`, the matching stock `boot.img`, and the `kptools` log. On a device
running stock GrapheneOS of exactly that `ota-version`, with the bootloader unlocked:

```shell
fastboot flash boot mustang-<version>-apatch-boot-kp<...>.img   # test
fastboot flash boot mustang-<version>-stock-boot.img            # revert
```

If it does not boot, revert, boot normally, and capture `adb bugreport`: its last kmsg (`console-ramoops`) section
holds the kernel log of the failed boot.

Once the boot image is confirmed on hardware, the APatch OTA is built by the **Release single device**
workflow (with `skip-release` to build without publishing): the same KernelPatch-patched `boot.img`
fed to avbroot as a prepatched image, signed with the repo keys, with `patched=true` re-verified. The OTA is also checked
to leave the `system` filesystem identical to stock apart from avbroot's `otacerts.zip` replacement.

##### Notes on installing the APatch OTA on mustang

The OTA is installed the standard way (see [Install](#install)). These mustang-specific points explain boot loops seen
when the procedure deviates:

- **Flash *all* the dynamic partitions through `fastbootd`, not just what `flashall` covers.** `system`, `product`,
  `vendor`, `system_ext`, `system_dlkm` and `vendor_dlkm` live inside `super` and can only be written from userspace
  fastboot (`fastbootd`). `fastboot flashall` enters `fastbootd` and writes `boot`/`init_boot`/`vbmeta`/`vendor_boot`
  **and `system` only** — it does **not** write `product`/`vendor`/`system_ext`/`system_dlkm`/`vendor_dlkm`. Those are
  verity-protected, so if their on-disk copies don't match the signed vbmeta (A/B slot skew, or any version
  difference) dm-verity fails and the device bootloops. Extract them with `avbroot ota extract --all` (or `-p <part>`)
  and flash each one in `fastbootd` after `flashall`. Flashing logical partitions from the *bootloader* instead fails
  with `resize-logical-partition ... FAILED`. Use an up-to-date `fastboot`; if a stale copy earlier in `PATH` shadows
  it, `fastboot reboot fastbootd` reports `unknown reboot target fastbootd`.
- **The OTA version must equal the stock version on the device.** The OTA's `vendor_boot`/`boot` is what boots
  `fastbootd`, so if the OTA and the installed firmware differ, `fastboot flashall`'s reboot into `fastbootd` hangs at
  `< waiting for any device >`. Flash the OTA that matches your installed GrapheneOS version (or update stock first).
- **Do not `adb sideload` the OTA as the first install on mustang.** Sideload fails here with
  `kPostInstallMountError (63)` / "Failed to mount /metadata". Full-partition `flashall` (above) is the first-install
  method; sideload is for later updates of a device that already runs a build from this repo
  ([locked-bootloader update](#updating-with-a-locked-bootloader)).

If `system` does not match the signed vbmeta, dm-verity cannot build its table and init aborts — which on screen looks
like a generic boot loop. The kernel log of the failed boot (`/sys/fs/pstore/console-ramoops-0`, readable over `adb`
after booting any working image) shows the real cause:

```
init: DM_TABLE_LOAD failed: name=system-verity, ... : Argument list too long
init: Failed to mount /system
Kernel panic - not syncing: Attempted to kill init! exitcode=0x00007f00
```

To prove the images themselves are fine and isolate a mount/verity problem from a bad image, flash the vbmeta with
verification off (`fastboot --disable-verity --disable-verification flash vbmeta vbmeta.img`): the same partitions then
boot. Re-flash the signed `vbmeta.img` (no flags) once the dynamic partitions are written correctly.

Install the official signed APatch manager APK from the matching [APatch release](https://github.com/bmax121/APatch/releases)
by hand after boot. Because KernelPatch is patched in signature-authorized manager mode (no SuperKey), the manager is
trusted by its APK signature, so root activates once the app is installed, without a SuperKey entry.

Preinstalling the manager into the system image (as a system app, via the
[`patch-modules/apatch_manager.py`](patch-modules/apatch_manager.py) [`my-avbroot-setup`](https://github.com/chenxiaolong/my-avbroot-setup)
module, `APATCH_PREINSTALL_MANAGER=true`) is **off by default**: on `mustang` the resulting OTA bootloops (the same OTA
boots without the injection), so injecting the app is left as an opt-in to investigate, not a shipping default.

APatch itself does not include Zygisk. If Zygisk is required, install an APatch-compatible Zygisk implementation as an
APatch module only after the basic APatch boot and root flow has been verified.

APatch test builds must remain outside production feeds. Do not lock the bootloader for an APatch test. Keep a known-good
signed OTA available and verify persistent boot, recovery, the APatch manager, root access, and required modules first.

This fork publishes its pixincreate feed at:

`https://david568303.github.io/rooted-graphene/pixincreate`

Use that URL in Custota. The matching initial-install AVB public key is available at
[`avb_pkmd.bin`](https://david568303.github.io/rooted-graphene/avb_pkmd.bin). All device builds on this server use the same
signing identity, so always verify that an OTA is for the correct device codename before manually sideloading it.

The `Automatic pixincreate OTAs` workflow checks every two hours and supports every device currently published by GrapheneOS:

| Device | Codename | Magisk pre-init device |
| --- | --- | --- |
| Pixel 10a | `stallion` | `sda10` |
| Pixel 10 Pro Fold | `rango` | `sda10` |
| Pixel 10 Pro XL | `mustang` | `sda10` |
| Pixel 10 Pro | `blazer` | `sda10` |
| Pixel 10 | `frankel` | `sda10` |
| Pixel 9a | `tegu` | `sda10` |
| Pixel 9 Pro Fold | `comet` | `sda10` |
| Pixel 9 Pro XL | `komodo` | `sda10` |
| Pixel 9 Pro | `caiman` | `sda10` |
| Pixel 9 | `tokay` | `sda10` |
| Pixel 8a | `akita` | `sda10` |
| Pixel 8 Pro | `husky` | `sda10` |
| Pixel 8 | `shiba` | `sda10` |
| Pixel Fold | `felix` | `sda8` |
| Pixel Tablet | `tangorpro` | `sda5` |
| Pixel 7a | `lynx` | `sda8` |
| Pixel 7 Pro | `cheetah` | `sda8` |
| Pixel 7 | `panther` | `sda8` |
| Pixel 6a | `bluejay` | `sda8` |
| Pixel 6 Pro | `raven` | `metadata` |
| Pixel 6 | `oriole` | `metadata` |

The workflow skips device/flavor assets that already exist for the current GrapheneOS security-preview release. Matrix jobs are
allowed to fail independently so one temporarily unavailable device feed does not cancel updates for every other device.

In general, using [magisk and especially zygisk with Graphene seems to have the risk of breaking things with every new release](https://github.com/chenxiaolong/avbroot/issues/213#issuecomment-1986637884).  
It's good to have the rootless version as a fallback!

## Development
```bash
# DEBUG some parts of the script interactively
DEBUG=1 bash --init-file rooted-ota.sh
# Test loading secrets from env
PASSPHRASE_AVB=1 PASSPHRASE_OTA=1 bash -c '. rooted-ota.sh && key2base64 && KEY_AVB=doesnotexist createAndReleaseRootedOta'        

# Avoid having to download OTA all over again: SKIP_CLEANUP=true or:
mkdir -p .tmp && ln -s $PWD/shiba-ota_update-2023121200.zip .tmp/shiba-ota_update-2023121200.zip

# Test only patching
  export PASSPHRASE_AVB=x PASSPHRASE_OTA=y
SKIP_CLEANUP=true DEVICE_ID=oriole MAGISK_PREINIT_DEVICE='metadata' bash -c '. rooted-ota.sh && createRootedOta'

# Test only releasing
  GITHUB_TOKEN=gh... \
 DEBUG=true \
GITHUB_REPO=schnatterer/rooted-graphene \
OTA_VERSION=2025021100 \
RELEASE_ID='' \
  bash -c '. rooted-ota.sh && releaseOta'
# Test only GH pages deployment
GITHUB_REPO=schnatterer/rooted-graphene \
DEVICE_ID=oriole \
MAGISK_PREINIT_DEVICE=metadata \
  bash -c '. rooted-ota.sh && findLatestVersion && checkBuildNecessary && createOtaServerData && uploadOtaServerData'


# e2e test
  GITHUB_TOKEN=gh... \
GITHUB_REPO=schnatterer/rooted-graphene \
DEVICE_ID=oriole \
MAGISK_PREINIT_DEVICE=metadata \
SKIP_CLEANUP=true \
DEBUG=1 \
  bash -c '. rooted-ota.sh && createAndReleaseRootedOta'
```

## References, Inspiration
https://github.com/MuratovAS/grapheneos-magisk/blob/main/docker/Dockerfile

https://xdaforums.com/t/guide-to-lock-bootloader-while-using-rooted-otaos-magisk-root.4510295/
