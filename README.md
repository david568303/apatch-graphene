Graphene-Apatch
===
Fork of: [rooted-graphene](https://github.com/schnatterer/rooted-graphene)


GrapheneOS over the air updates (OTAs) patched with KernelPatch allowing for AVB and locked bootloader *and* root access.  

## Installation

> [!CAUTION]
> Flashing carries risk. Keep **OEM unlocking enabled**, never switch slots if a flash fails, and flash a rooted OTA whose version **exactly matches** the stock GrapheneOS already on the device. Read the full [caveats](#installation) first — you use this at your own risk.

> [!NOTE]
> If a device won't boot, capturing the kernel log of the failed boot (`adb shell su -c 'cat /sys/fs/pstore/console-ramoops-0'` after booting any working image) is the single most useful thing to attach to an issue.

### Install GrapheneOS

1. **Option 1 — Web Installer**

   Use the [web installer](https://grapheneos.org/install/web) to install GrapheneOS:
   * Write down the installed version, e.g. `Downloaded caiman-install-2024123000.zip release`.
   * Stop at `Locking the bootloader` and close the browser. 
   We'll lock the bootloader later!

2. **Option 2 — Manual install**

   Download your [**factory image**](https://grapheneos.org/releases) and follow the [official instructions](https://grapheneos.org/install/cli)  to install GrapheneOS.

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

### Patch GrapheneOS with OTAs from this image

  Once GrapheneOS is installed

  * Download the [OTA from releases](https://github.com/rooted-graphene/ota/releases) with **the same version** (except `00` at the end is `01`, see [security-preview](#173-sept-27-2025)) that you just installed. 
  * Obtain latest `fastboot`
  * Install [avbroot](https://github.com/chenxiaolong/avbroot)



If `system` does not match the signed vbmeta, dm-verity cannot build its table and init aborts — which on screen looks
like a generic boot loop. The kernel log of the failed boot (`/sys/fs/pstore/console-ramoops-0`, readable over `adb`
after booting any working image) shows the real cause:

### Credits
[schatterer](https://github.com/schnatterer)
And the rest of contributors of [rooted-graphene](https://github.com/schnatterer/rooted-graphene)
