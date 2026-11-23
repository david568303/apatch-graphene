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
  * Download `flash-ota.sh` (Linux/macOS) or `flash-ota.bat` (Windows) from the same release and place it next to the OTA zip, then run it — it flashes every partition and offers to lock the bootloader once GrapheneOS boots.




### Play Integrity (strong integrity)

Setting `INTEGRITY_PATCH=true` bakes a rootless Play Integrity hook into the
system image of the OTA. There is no Magisk, no APatch, no module, no init
service and no SELinux policy: the hook rides in `framework.jar` (a single call
spliced into `AndroidKeyStoreSpi`), the stale preopted boot image is deleted so
the device's own `odrefresh` rebuilds it from the patched boot classpath with
the OTA's `dex2oat` on first boot (the first boot is therefore slower), and
everything lands through the same avbroot module mechanism this repo already
uses. `verifyAPatchPartitions` proves the system partition is stock apart from
exactly `framework.jar`, the removed boot image artifacts and a new
`/system/etc/playintegrity` directory. A relocked bootloader on the local AVB
key is what makes the attestation claims (`verifiedBootState=VERIFIED`,
`deviceLocked=true`) coherent.

> [!CAUTION]
> Play Integrity spoofing is revocable by Google and **expected to break**. A
> keybox can be banned at any time; treat it as disposable and keep the rest of
> the build working without it.

#### The per-build keybox

The keybox never lives in this repo. Point `INTEGRITY_KEYBOX` at a standard
`AndroidAttestation` keybox XML (RSA + ECDSA) for the build:

```shell
INTEGRITY_PATCH=true INTEGRITY_KEYBOX=/path/to/keybox.xml \
  DEVICE_ID=mustang ./rooted-ota.sh
```

It is baked read-only to `/system/etc/playintegrity/keybox.xml` (world-readable
by design — the private keys in a keybox are not a secret the OS keeps). For
testing, a keybox pushed over adb to `/data/local/tmp/playintegrity/keybox.xml`
takes precedence over the baked one (and the cache), so you can swap keyboxes
without reflashing; it is read only where the caller's SELinux domain can reach
`/data/local/tmp`, and the hook falls back to the baked keybox otherwise. Two
small files are generated next to the baked keybox:

* `config.json` — which caller packages get a spoofed chain
  (`INTEGRITY_PACKAGES`, default `com.google.android.gms`), plus the optional
  fetch/pin material below.
* `root_of_trust.json` — the `verifiedBootKey` / `verifiedBootHash` the leaf
  attests to (`INTEGRITY_VERIFIED_BOOT_KEY` / `INTEGRITY_VERIFIED_BOOT_HASH`,
  hex or base64, default 32 zero bytes); `deviceLocked` and `verifiedBootState`
  are fixed to the strong state.

On device the hook re-reads these by mtime, so dropping a new keybox or config
takes effect without a reboot.

#### Rotation and revocation

To rotate the keybox after shipping — e.g. once the baked one is burned — host
an Ed25519-signed bundle and bake its coordinates in:

* `INTEGRITY_KEYBOX_URL` — where the hook fetches the bundle
  (`{"keybox":"<base64 xml>","sig":"<base64 Ed25519 over the xml>"}`).
* `INTEGRITY_KEYBOX_SIGN_KEY` — the base64 public half that must sign it.

The fetch is a background, one-at-a-time daemon that never runs on the
attestation path, caches into the hosting app's own data dir, and **never
regresses**: a fetched keybox is adopted only if its signature verifies and the
keybox then validates — it parses, carries both RSA and ECDSA, each chain is
internally consistent and (when roots are pinned via `googleRoots` in
`config.json`) terminates at a pinned Google root, nothing is expired, and no
certificate serial appears on the revocation list (`revokedSerials` in
`config.json`, plus any cached list). A rejected fetch keeps the current box, so
a banned or malformed keybox can never downgrade a working one.

### Credits
[schatterer](https://github.com/schnatterer)
And the rest of contributors of [rooted-graphene](https://github.com/schnatterer/rooted-graphene)
Keybox chain generation ported from [UN1CA](https://github.com/salvogiangri/UN1CA) (GPL-3.0).
